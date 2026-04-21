import Foundation
import Combine

@MainActor
class ProcessMonitor: ObservableObject {
    @Published var allProcesses: [DevProcess] = []
    @Published var zombieProcesses: [DevProcess] = []
    @Published var suspectProcesses: [DevProcess] = []
    @Published var whitelistedProcesses: [DevProcess] = []
    @Published var lastScan: Date?
    @Published var totalCPU: Double = 0
    @Published var totalMemoryMB: Double = 0
    @Published var isScanning = false
    @Published var lastError: String?
    /// Latest system-pressure snapshot republished from the injected source.
    /// `nil` until the source emits its first value.
    @Published var pressure: SystemPressureSnapshot?
    /// Current overall emergency state (derived from pressure with hysteresis).
    @Published private(set) var emergencyState: EmergencyState = .normal
    /// Read-only audit trail of state transitions (most recent last; capped).
    @Published private(set) var stateTransitions: [StateTransition] = []

    /// Single transition record kept in ``stateTransitions``.
    struct StateTransition: Sendable, Equatable {
        let timestamp: Date
        let from: EmergencyState
        let to: EmergencyState
    }

    private static let maxStateTransitions = 50

    private var timer: Timer?
    private var config: WatchdogConfig?
    private var cancellables = Set<AnyCancellable>()
    private let terminator: any ProcessTerminator
    private let pressureSource: any SystemPressureSource
    private let notificationService = NotificationService()

    /// In-memory session log — bounded ring buffer of monitor actions.
    /// Exposed so `SessionLogView` (and any future UI) can observe it directly.
    let sessionLog = SessionLog()

    // Emergency-mode bookkeeping
    private var lastHighSeenAt: Date?
    /// When the current emergency period was entered (nil when not in emergency).
    private var emergencyEnteredAt: Date?
    /// Zombies killed during the currently-active emergency period (reset on exit).
    private var emergencyKillCount: Int = 0
    /// Memory (MB) reclaimed by kills during the currently-active emergency period.
    private var emergencyFreedMemoryMB: Double = 0
    /// Processes throttled during the currently-active emergency period.
    private var emergencyThrottledCount: Int = 0

    init(
        pressureSource: (any SystemPressureSource)? = nil,
        terminator: (any ProcessTerminator)? = nil
    ) {
        self.pressureSource = pressureSource ?? SystemPressureMonitor()
        self.terminator = terminator ?? ProcessKiller()
    }

    // Track processes pending auto-kill (PID -> first seen time + snapshotted grace period)
    private var pendingKills: [Int32: (firstSeen: Date, gracePeriod: TimeInterval)] = [:]
    // Track which zombie batches we already notified about (to avoid repeat alerts)
    private var notifiedZombiePIDs: Set<Int32> = []

    func start(config: WatchdogConfig) {
        self.config = config

        // Reschedule timer whenever scanInterval changes
        config.$scanInterval
            .removeDuplicates()
            .dropFirst() // Skip the initial value (we already schedule below)
            .sink { [weak self] _ in
                self?.scheduleTimer()
            }
            .store(in: &cancellables)

        // Subscribe to the pressure source and republish on MainActor.
        // `removeDuplicates` avoids no-op republishing when the source emits
        // a snapshot identical to the previous one.
        pressureSource.snapshotPublisher
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] snapshot in
                guard let self else { return }
                if self.pressure != snapshot {
                    self.pressure = snapshot
                }
                self.updateEmergencyState(from: snapshot)
            }
            .store(in: &cancellables)

        // Reschedule whenever the user toggles Emergency Mode itself —
        // otherwise an on-the-fly toggle keeps the old interval until the
        // next pressure change.
        config.$emergencyModeEnabled
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                self?.scheduleTimer()
            }
            .store(in: &cancellables)

        // Request notification permission
        Task {
            await notificationService.requestPermission()
        }

        // Start the pressure source (fire-and-forget; start() is idempotent).
        Task { [pressureSource] in
            await pressureSource.start()
        }

        scheduleTimer()

        // Initial scan
        Task { await scan() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        cancellables.removeAll()
        pendingKills.removeAll()
        notifiedZombiePIDs.removeAll()
        lastHighSeenAt = nil
        emergencyEnteredAt = nil
        emergencyKillCount = 0
        emergencyFreedMemoryMB = 0
        emergencyThrottledCount = 0
        emergencyState = .normal
        // pressureSource.stop() is async to allow main-actor-isolated impls;
        // fire-and-forget from the synchronous stop() entry point.
        Task { [pressureSource] in
            await pressureSource.stop()
        }
    }


    func scan() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }

        let excludedApps = config?.excludedApps ?? WatchdogConfig.defaultExcludedApps
        let inclusionPatterns = config?.inclusionPatterns ?? WatchdogConfig.defaultInclusionPatterns
        let processes = await Task.detached {
            PSParser.parseProcessList(excludedApps: excludedApps, inclusionPatterns: inclusionPatterns)
        }.value

        guard let config else { return }

        var zombies: [DevProcess] = []
        var suspects: [DevProcess] = []
        var whitelisted: [DevProcess] = []

        for process in processes {
            // STAGE 1: Whitelisted -> protect
            if config.isWhitelisted(process) {
                whitelisted.append(process)
                continue
            }

            // STAGE 2: Orphan + old enough -> ZOMBIE (auto-kill)
            if process.isOrphan && (process.runtime ?? 0) >= config.orphanTimeout {
                zombies.append(process)
                continue
            }

            // STAGE 3: Rule-based (for non-orphans and young orphans)
            if let rule = config.matchingRule(for: process) {
                // Hard kill limits (runtime/CPU%/RSS) exceeded → zombie
                if rule.shouldHardKill(process) {
                    zombies.append(process)
                } else if rule.isTriggered(by: process) {
                    suspects.append(process)
                } else if rule.action == .warn {
                    // Matches warn pattern but thresholds not yet exceeded — still show
                    suspects.append(process)
                }
                continue
            }

            // STAGE 4: General heuristic (no matching rule)
            let runtime = process.runtime ?? 0
            if config.catchAllMaxRuntime > 0 && runtime >= config.catchAllMaxRuntime {
                // Any dev process running longer than catch-all limit → zombie
                zombies.append(process)
            } else if process.isOrphan {
                // Orphan below orphanTimeout — still suspicious if running a while
                if runtime > 300 { suspects.append(process) }
            } else if process.cpuPercent > 80 {
                // Non-orphan with very high CPU — worth flagging
                suspects.append(process)
            }
            // Non-orphan, normal CPU, no rule match → skip (parent alive, likely intentional)
        }

        // Emergency triage: promote the three most resource-heavy suspects
        // (by CPU·RSS score) to zombies. Point of emergency mode is to be
        // aggressive — normally-protected warn-bucket processes get killed.
        if emergencyState == .emergency && !suspects.isEmpty {
            let promoted = suspects
                .sorted { emergencyScore($0) > emergencyScore($1) }
                .prefix(3)
            let promotedIDs = Set(promoted.map(\.id))
            zombies.append(contentsOf: promoted)
            suspects.removeAll { promotedIDs.contains($0.id) }
        }

        // Sort: most obvious kill candidates first
        // Zombies: longest runtime first (most obviously dead), then highest memory (most waste)
        zombies.sort {
            let r0 = $0.runtime ?? 0, r1 = $1.runtime ?? 0
            if r0 != r1 { return r0 > r1 }
            return $0.memoryMB > $1.memoryMB
        }
        // Suspects: highest CPU first (most impactful), then longest runtime
        suspects.sort {
            if $0.cpuPercent != $1.cpuPercent { return $0.cpuPercent > $1.cpuPercent }
            return ($0.runtime ?? 0) > ($1.runtime ?? 0)
        }

        if processes != self.allProcesses { self.allProcesses = processes }
        if zombies != self.zombieProcesses { self.zombieProcesses = zombies }
        if suspects != self.suspectProcesses { self.suspectProcesses = suspects }
        if whitelisted != self.whitelistedProcesses { self.whitelistedProcesses = whitelisted }

        let newTotalCPU = processes.reduce(0) { $0 + $1.cpuPercent }
        let newTotalMemoryMB = processes.reduce(0) { $0 + $1.memoryMB }
        if newTotalCPU != self.totalCPU { self.totalCPU = newTotalCPU }
        if newTotalMemoryMB != self.totalMemoryMB { self.totalMemoryMB = newTotalMemoryMB }
        self.lastScan = Date()

        // Handle auto-kill with grace period
        await handleAutoKill(zombies: zombies, config: config)
    }

    func killProcess(_ process: DevProcess) {
        let result = terminator.terminate(pid: process.pid)
        switch result {
        case .success, .alreadyDead:
            zombieProcesses.removeAll { $0.id == process.id }
            suspectProcesses.removeAll { $0.id == process.id }
            allProcesses.removeAll { $0.id == process.id }
            pendingKills.removeValue(forKey: process.pid)
            notifiedZombiePIDs.remove(process.pid)
            sessionLog.log(
                .kill,
                "Killed \(process.processName) (\(String(format: "%.0f", process.memoryMB)) MB)",
                pid: process.pid,
                processName: process.processName,
                killReason: KillReason(
                    ruleID: nil,
                    rulePattern: nil,
                    trigger: .manual,
                    thresholdValue: 0,
                    actualValue: process.runtime ?? 0,
                    unit: "s"
                )
            )
            if emergencyState == .emergency, result == .success {
                emergencyKillCount += 1
                emergencyFreedMemoryMB += process.memoryMB
            }
        case .permissionDenied:
            lastError = "Permission denied for PID \(process.pid)"
            sessionLog.log(
                .error,
                "Kill denied: \(process.processName)",
                pid: process.pid,
                processName: process.processName
            )
            Task {
                await notificationService.send(
                    title: "Kill failed",
                    body: "Permission denied for \(process.processName) (PID \(process.pid))."
                )
            }
        case .failed(let err):
            lastError = "Kill failed for PID \(process.pid) (errno: \(err))"
            sessionLog.log(
                .error,
                "Kill failed (errno \(err)): \(process.processName)",
                pid: process.pid,
                processName: process.processName
            )
        }
        // Clear error after 5 seconds
        if lastError != nil {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(5))
                self?.lastError = nil
            }
        }
    }

    /// Freeze a process (SIGSTOP + renice +20). Used as a graduated response
    /// before full termination — e.g. by Emergency Mode triage.
    func throttleProcess(_ process: DevProcess) {
        let result = terminator.throttle(pid: process.pid)
        switch result {
        case .success:
            // Optimistic state update for snappy UI feedback; next scan confirms.
            if let idx = allProcesses.firstIndex(where: { $0.id == process.id }) {
                let p = allProcesses[idx]
                allProcesses[idx] = DevProcess(
                    id: p.id,
                    user: p.user,
                    cpuPercent: p.cpuPercent,
                    memPercent: p.memPercent,
                    rss: p.rss,
                    command: p.command,
                    startTime: p.startTime,
                    parentPID: p.parentPID,
                    isOrphan: p.isOrphan,
                    state: .stopped
                )
            }
            sessionLog.log(
                .throttle,
                "Throttled \(process.processName) via SIGSTOP",
                pid: process.pid,
                processName: process.processName
            )
            if emergencyState == .emergency {
                emergencyThrottledCount += 1
            }
            Task {
                await notificationService.send(
                    title: "Process throttled",
                    body: "\(process.processName) (PID \(process.pid)) frozen via SIGSTOP."
                )
            }
        case .alreadyDead:
            allProcesses.removeAll { $0.id == process.id }
            zombieProcesses.removeAll { $0.id == process.id }
            suspectProcesses.removeAll { $0.id == process.id }
        case .permissionDenied:
            lastError = "Permission denied throttling PID \(process.pid)"
            sessionLog.log(
                .error,
                "Throttle denied: \(process.processName)",
                pid: process.pid,
                processName: process.processName
            )
            Task {
                await notificationService.send(
                    title: "Throttle failed",
                    body: "Permission denied for \(process.processName) (PID \(process.pid))."
                )
            }
        case .failed(let err):
            lastError = "Throttle failed for PID \(process.pid) (errno: \(err))"
            sessionLog.log(
                .error,
                "Throttle failed (errno \(err)): \(process.processName)",
                pid: process.pid,
                processName: process.processName
            )
        }
        if lastError != nil {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(5))
                self?.lastError = nil
            }
        }
    }

    /// Resume a previously throttled/stopped process (SIGCONT).
    func resumeProcess(_ process: DevProcess) {
        let result = terminator.resume(pid: process.pid)
        switch result {
        case .success:
            if let idx = allProcesses.firstIndex(where: { $0.id == process.id }) {
                let p = allProcesses[idx]
                allProcesses[idx] = DevProcess(
                    id: p.id,
                    user: p.user,
                    cpuPercent: p.cpuPercent,
                    memPercent: p.memPercent,
                    rss: p.rss,
                    command: p.command,
                    startTime: p.startTime,
                    parentPID: p.parentPID,
                    isOrphan: p.isOrphan,
                    state: .running
                )
            }
            sessionLog.log(
                .resume,
                "Resumed \(process.processName) via SIGCONT",
                pid: process.pid,
                processName: process.processName
            )
            Task {
                await notificationService.send(
                    title: "Process resumed",
                    body: "\(process.processName) (PID \(process.pid)) resumed via SIGCONT."
                )
            }
        case .alreadyDead:
            allProcesses.removeAll { $0.id == process.id }
            zombieProcesses.removeAll { $0.id == process.id }
            suspectProcesses.removeAll { $0.id == process.id }
        case .permissionDenied:
            lastError = "Permission denied resuming PID \(process.pid)"
            sessionLog.log(
                .error,
                "Resume denied: \(process.processName)",
                pid: process.pid,
                processName: process.processName
            )
            Task {
                await notificationService.send(
                    title: "Resume failed",
                    body: "Permission denied for \(process.processName) (PID \(process.pid))."
                )
            }
        case .failed(let err):
            lastError = "Resume failed for PID \(process.pid) (errno: \(err))"
            sessionLog.log(
                .error,
                "Resume failed (errno \(err)): \(process.processName)",
                pid: process.pid,
                processName: process.processName
            )
        }
        if lastError != nil {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(5))
                self?.lastError = nil
            }
        }
    }

    func killAllZombies() {
        let memoryMB = zombieProcesses.reduce(0.0) { $0 + $1.memoryMB }
        let count = zombieProcesses.count

        for process in zombieProcesses {
            _ = terminator.terminate(pid: process.pid)
            let reason = config.map { inferKillReason(for: process, config: $0) }
            sessionLog.log(
                .kill,
                "Batch-killed \(process.processName)",
                pid: process.pid,
                processName: process.processName,
                killReason: reason
            )
        }
        zombieProcesses.removeAll()
        pendingKills.removeAll()
        notifiedZombiePIDs.removeAll()

        if count > 0 {
            if emergencyState == .emergency {
                emergencyKillCount += count
                emergencyFreedMemoryMB += memoryMB
            }
            let decision = EmergencyNotificationBatcher.onKillDuringEmergency(
                emergencyState: emergencyState,
                isNewBatch: true
            )
            if !decision.suppressIndividualKills {
                Task {
                    await notificationService.sendBatchKillSummary(count: count, freedMemoryMB: memoryMB)
                }
            }
        }
    }

    func killAllSuspects() {
        let memoryMB = suspectProcesses.reduce(0.0) { $0 + $1.memoryMB }
        let count = suspectProcesses.count

        for process in suspectProcesses {
            _ = terminator.terminate(pid: process.pid)
            let reason = config.map { inferKillReason(for: process, config: $0, allowEmergencyPromotion: true) }
            sessionLog.log(
                .kill,
                "Batch-killed suspect \(process.processName)",
                pid: process.pid,
                processName: process.processName,
                killReason: reason
            )
        }
        suspectProcesses.removeAll()
        allProcesses.removeAll { p in !zombieProcesses.contains(where: { $0.id == p.id }) && !whitelistedProcesses.contains(where: { $0.id == p.id }) }

        if count > 0 {
            if emergencyState == .emergency {
                emergencyKillCount += count
                emergencyFreedMemoryMB += memoryMB
            }
            let decision = EmergencyNotificationBatcher.onKillDuringEmergency(
                emergencyState: emergencyState,
                isNewBatch: true
            )
            if !decision.suppressIndividualKills {
                Task {
                    await notificationService.sendBatchKillSummary(count: count, freedMemoryMB: memoryMB)
                }
            }
        }
    }

    // MARK: - Private

    /// Infer a ``KillReason`` for an auto-kill by replaying the same classification
    /// logic used in ``scan()`` — rule match → specific exceeded threshold →
    /// orphan-timeout → catch-all → emergency promotion.
    ///
    /// - Parameters:
    ///   - process: The process being killed.
    ///   - config: Active watchdog configuration.
    ///   - allowEmergencyPromotion: Pass `true` when killing suspects that were
    ///     promoted to zombie during an emergency scan (they may not satisfy normal
    ///     hard-kill thresholds on their own).
    private func inferKillReason(
        for process: DevProcess,
        config: WatchdogConfig,
        allowEmergencyPromotion: Bool = false
    ) -> KillReason {
        // 1. Rule-based hard-kill: pick the first exceeded threshold (runtime > CPU > RSS)
        if let rule = config.matchingRule(for: process), rule.shouldHardKill(process) {
            let runtimeExceeded = rule.maxRuntime > 0 && (process.runtime ?? 0) >= rule.maxRuntime
            let cpuExceeded = rule.maxCPUPercent > 0 && process.cpuPercent >= rule.maxCPUPercent
            let rssExceeded = rule.maxRSSMB > 0 && process.memoryMB >= rule.maxRSSMB
            if runtimeExceeded {
                return KillReason(
                    ruleID: rule.id,
                    rulePattern: rule.pattern,
                    trigger: .maxRuntime,
                    thresholdValue: rule.maxRuntime,
                    actualValue: process.runtime ?? 0,
                    unit: "s"
                )
            } else if cpuExceeded {
                return KillReason(
                    ruleID: rule.id,
                    rulePattern: rule.pattern,
                    trigger: .maxCPUPercent,
                    thresholdValue: rule.maxCPUPercent,
                    actualValue: process.cpuPercent,
                    unit: "%"
                )
            } else if rssExceeded {
                return KillReason(
                    ruleID: rule.id,
                    rulePattern: rule.pattern,
                    trigger: .maxRSSMB,
                    thresholdValue: rule.maxRSSMB,
                    actualValue: process.memoryMB,
                    unit: "MB"
                )
            }
        }
        // 2. Orphan timeout
        if process.isOrphan && (process.runtime ?? 0) >= config.orphanTimeout {
            return KillReason(
                ruleID: nil,
                rulePattern: nil,
                trigger: .orphanTimeout,
                thresholdValue: config.orphanTimeout,
                actualValue: process.runtime ?? 0,
                unit: "s"
            )
        }
        // 3. Catch-all max runtime
        if config.catchAllMaxRuntime > 0 && (process.runtime ?? 0) >= config.catchAllMaxRuntime {
            return KillReason(
                ruleID: nil,
                rulePattern: nil,
                trigger: .catchAllMaxRuntime,
                thresholdValue: config.catchAllMaxRuntime,
                actualValue: process.runtime ?? 0,
                unit: "s"
            )
        }
        // 4. Emergency promotion (suspects raised to zombies during emergency triage)
        if allowEmergencyPromotion || emergencyState == .emergency {
            return KillReason(
                ruleID: nil,
                rulePattern: nil,
                trigger: .emergencyPromotion,
                thresholdValue: 0,
                actualValue: emergencyScore(process),
                unit: "%·MB"
            )
        }
        // 5. Conservative fallback: report runtime against zero threshold
        return KillReason(
            ruleID: nil,
            rulePattern: nil,
            trigger: .catchAllMaxRuntime,
            thresholdValue: 0,
            actualValue: process.runtime ?? 0,
            unit: "s"
        )
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let interval = effectiveScanInterval
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.scan()
            }
        }
    }

    /// Effective scan cadence. Tightens automatically while in elevated /
    /// emergency state (issue #6).
    var effectiveScanInterval: TimeInterval {
        guard let config else { return 30 }
        guard config.emergencyModeEnabled else { return config.scanInterval }
        switch emergencyState {
        case .normal:
            return config.scanInterval
        case .elevated:
            // Bias toward more frequent scans, but never faster than 2s and
            // never slower than 10s.
            return max(2, min(config.scanInterval / 3, 10))
        case .emergency:
            // Aggressive 3s cadence with a hard 2s floor.
            return max(2, 3)
        }
    }

    /// Effective grace period applied in ``handleAutoKill(zombies:config:)``.
    /// Emergency collapses grace to zero — all pending kills become immediately
    /// eligible for termination.
    var effectiveGracePeriod: TimeInterval {
        guard let config else { return 30 }
        guard config.emergencyModeEnabled else { return config.gracePeriod }
        switch emergencyState {
        case .normal:    return config.gracePeriod
        case .elevated:  return config.gracePeriod / 2
        case .emergency: return 0
        }
    }

    // MARK: - Emergency state

    private func updateEmergencyState(from snapshot: SystemPressureSnapshot) {
        guard let config else { return }
        // Build a deriver from live config. Struct is cheap — no need to cache.
        let deriver = EmergencyStateDeriver(
            ncpu: snapshot.ncpu,
            emergencyLoadFactor: config.emergencyLoadFactor,
            elevatedLoadFactor: config.elevatedLoadFactor,
            cooldownSeconds: config.emergencyCooldown
        )
        let desired = deriver.desired(from: snapshot)
        let now = Date()
        let result = deriver.nextState(
            current: emergencyState,
            desired: desired,
            now: now,
            lastHighSeenAt: lastHighSeenAt
        )
        lastHighSeenAt = result.lastHighSeenAt

        if result.state != emergencyState {
            let previous = emergencyState
            emergencyState = result.state
            recordTransition(from: previous, to: result.state, at: now)
            handleStateTransition(from: previous, to: result.state, snapshot: snapshot)
        }
    }

    private func recordTransition(from: EmergencyState, to: EmergencyState, at date: Date) {
        stateTransitions.append(StateTransition(timestamp: date, from: from, to: to))
        if stateTransitions.count > Self.maxStateTransitions {
            stateTransitions.removeFirst(stateTransitions.count - Self.maxStateTransitions)
        }
    }

    private func handleStateTransition(
        from: EmergencyState,
        to: EmergencyState,
        snapshot: SystemPressureSnapshot
    ) {
        let decision = EmergencyNotificationBatcher.onStateTransition(from: from, to: to)

        // Track emergency periods for the "exit summary" notification.
        if decision.sendEntryAlert {
            emergencyEnteredAt = Date()
            emergencyKillCount = 0
            emergencyFreedMemoryMB = 0
            emergencyThrottledCount = 0
            sessionLog.log(
                .emergencyEntered,
                "Emergency entered (loadFactor \(String(format: "%.2f", snapshot.loadFactor)), level \(snapshot.level))"
            )
            Task { [notificationService] in
                await notificationService.sendEmergencyEnteredAlert(snapshot: snapshot)
            }
        } else if decision.sendExitAlert {
            let enteredAt = emergencyEnteredAt
            let killed = emergencyKillCount
            let throttled = emergencyThrottledCount
            let freed = emergencyFreedMemoryMB
            let duration: TimeInterval = enteredAt.map { Date().timeIntervalSince($0) } ?? 0
            sessionLog.log(
                .emergencyExited,
                "Emergency ended after \(Int(duration))s — \(killed) killed, \(throttled) throttled, \(String(format: "%.0f", freed)) MB freed"
            )
            emergencyEnteredAt = nil
            emergencyKillCount = 0
            emergencyFreedMemoryMB = 0
            emergencyThrottledCount = 0
            Task { [notificationService] in
                await notificationService.sendEmergencyExitedSummary(
                    duration: duration,
                    killedCount: killed,
                    throttledCount: throttled,
                    freedMemoryMB: freed
                )
            }
        }

        // Any state change potentially changes the effective scan interval.
        scheduleTimer()
    }

    private func emergencyScore(_ p: DevProcess) -> Double {
        return max(p.cpuPercent, 1.0) * max(p.memoryMB, 1.0)
    }

    private func handleAutoKill(zombies: [DevProcess], config: WatchdogConfig) async {
        let now = Date()

        // Find new zombies we haven't notified about yet
        let newZombiePIDs = Set(zombies.map(\.pid)).subtracting(notifiedZombiePIDs)

        // Send batch notification for new zombies
        if !newZombiePIDs.isEmpty {
            let newZombies = zombies.filter { newZombiePIDs.contains($0.pid) }

            // Group by project for summary
            var projects: [String: Int] = [:]
            for z in newZombies {
                let key = z.projectName ?? "unknown"
                projects[key, default: 0] += 1
            }
            let totalMemory = newZombies.reduce(0.0) { $0 + $1.memoryMB }

            await notificationService.sendBatchZombieAlert(
                count: newZombies.count,
                projects: projects,
                totalMemoryMB: totalMemory
            )

            notifiedZombiePIDs.formUnion(newZombiePIDs)
        }

        // Track grace period and kill when expired
        var killedCount = 0
        var freedMemory = 0.0

        // Use the emergency-aware grace period. Re-computed each scan so a
        // state transition during an active pending-kill queue is honoured —
        // entering .emergency effectively collapses grace to 0 and everything
        // expires on the next pass.
        let graceNow = effectiveGracePeriod

        for zombie in zombies {
            if let entry = pendingKills[zombie.pid] {
                // Evaluate against the *current* effective grace, not the one
                // snapshotted at first-seen time.
                if now.timeIntervalSince(entry.firstSeen) >= graceNow {
                    _ = terminator.terminate(pid: zombie.pid)
                    pendingKills.removeValue(forKey: zombie.pid)
                    notifiedZombiePIDs.remove(zombie.pid)
                    killedCount += 1
                    freedMemory += zombie.memoryMB
                    sessionLog.log(
                        .kill,
                        "Auto-killed zombie \(zombie.processName) (\(String(format: "%.0f", zombie.memoryMB)) MB)",
                        pid: zombie.pid,
                        processName: zombie.processName,
                        killReason: inferKillReason(for: zombie, config: config)
                    )
                    if emergencyState == .emergency {
                        emergencyKillCount += 1
                        emergencyFreedMemoryMB += zombie.memoryMB
                    }
                }
                // else: still within grace period, wait
            } else {
                // First time seeing this zombie — start grace period with the
                // current effective value.
                pendingKills[zombie.pid] = (firstSeen: now, gracePeriod: graceNow)
            }
        }

        // Send batch kill summary — unless we're in emergency, in which case
        // individual kills are aggregated into the exit summary instead.
        if killedCount > 0 {
            let decision = EmergencyNotificationBatcher.onKillDuringEmergency(
                emergencyState: emergencyState,
                isNewBatch: true
            )
            if !decision.suppressIndividualKills {
                await notificationService.sendBatchKillSummary(count: killedCount, freedMemoryMB: freedMemory)
            }

            // Remove killed zombies from published list
            let killedPIDs = Set(zombies.filter { pid in
                pendingKills[pid.pid] == nil && !notifiedZombiePIDs.contains(pid.pid)
            }.map(\.pid))
            zombieProcesses.removeAll { killedPIDs.contains($0.pid) }
        }

        // Clean up pending kills for processes that are no longer zombies
        let zombiePIDs = Set(zombies.map(\.pid))
        pendingKills = pendingKills.filter { zombiePIDs.contains($0.key) }
        notifiedZombiePIDs = notifiedZombiePIDs.intersection(zombiePIDs)
    }
}

// MARK: - Process List Parser (nonisolated for background execution)

enum PSParser: Sendable {
    struct PSParsed: Sendable {
        let user: String
        let pid: Int32
        let ppid: Int32
        let cpu: Double
        let mem: Double
        let rss: Int
        let state: String
        let command: String
        let startTime: Date?
    }

    static func parseProcessList(excludedApps: [String], inclusionPatterns: [String] = []) -> [DevProcess] {
        let pipe = Pipe()
        let process = Process()

        // Check if ps command exists before running
        let psURL = URL(fileURLWithPath: "/bin/ps")
        guard FileManager.default.fileExists(atPath: psURL.path) else {
            DWLogger.shared.log("ps command not found at /bin/ps", category: .monitor, level: .error)
            return []
        }

        process.executableURL = psURL
        process.arguments = ["-eo", "user=,pid=,ppid=,%cpu=,%mem=,rss=,state=,start=,args="]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            DWLogger.shared.log("Failed to run ps command: \(error.localizedDescription)", category: .monitor, level: .error)
            return []
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let output = String(data: data, encoding: .utf8) else { return [] }

        let lines = output.components(separatedBy: "\n")
        guard !lines.isEmpty else { return [] }

        var results: [DevProcess] = []
        let currentUser = NSUserName()

        for line in lines {
            guard !line.isEmpty else { continue }
            guard let parsed = parsePSLine(line) else { continue }

            // Only track the current user's processes
            guard parsed.user == currentUser else { continue }

            // Only track dev-related processes
            let cmd = parsed.command.lowercased()
            let isDevProcess = inclusionPatterns.contains { pattern in
                cmd.contains(pattern.lowercased())
            }

            guard isDevProcess else { continue }

            // Playwright-spawned browsers are dev processes — never exclude them
            let isPlaywrightBrowser = parsed.command.contains("ms-playwright")

            // Exclude known non-dev Electron/desktop apps (but not Playwright browsers)
            if !isPlaywrightBrowser {
                let isExcludedApp = excludedApps.contains { parsed.command.contains($0) }
                guard !isExcludedApp else { continue }
            }

            // Also exclude anything under /Applications/ that isn't a dev tool
            if !isPlaywrightBrowser && parsed.command.contains("/Applications/") {
                let isDevApp = parsed.command.contains("Visual Studio Code") ||
                    parsed.command.contains("Cursor") ||
                    parsed.command.contains("iTerm") ||
                    parsed.command.contains("Terminal") ||
                    parsed.command.contains("Warp")
                if !isDevApp { continue }
            }

            // Check if orphan (parent PID = 1 means adopted by launchd)
            let parentPID = parsed.ppid
            let isOrphan = parentPID == 1

            let devProcess = DevProcess(
                id: parsed.pid,
                user: parsed.user,
                cpuPercent: parsed.cpu,
                memPercent: parsed.mem,
                rss: parsed.rss,
                command: parsed.command,
                startTime: parsed.startTime,
                parentPID: parentPID,
                isOrphan: isOrphan,
                state: ProcessState(psStateString: parsed.state)
            )
            results.append(devProcess)
        }

        return results
    }

    static func parsePSLine(_ line: String) -> PSParsed? {
        // ps -eo format: USER PID PPID %CPU %MEM RSS STATE STARTED ARGS
        // Split by whitespace, but args (command) can contain spaces
        let components = line.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: true)
        guard components.count >= 9 else { return nil }

        guard let pid = Int32(components[1]) else { return nil }
        guard let ppid = Int32(components[2]) else { return nil }
        let cpu = Double(components[3]) ?? 0
        let mem = Double(components[4]) ?? 0
        let rss = Int(components[5]) ?? 0
        let state = String(components[6])
        let command = String(components[8])

        // Parse STARTED (column 7) - format varies: "HH:MM" or "MonDD" or "YYYY"
        let startedStr = String(components[7])
        let startTime = parseStartTime(startedStr)

        return PSParsed(
            user: String(components[0]),
            pid: pid,
            ppid: ppid,
            cpu: cpu,
            mem: mem,
            rss: rss,
            state: state,
            command: command,
            startTime: startTime
        )
    }

    static func parseStartTime(_ str: String) -> Date? {
        let now = Date()
        let calendar = Calendar.current

        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")

        // Try "H:MMam" / "H:MMpm" / "HH:mm" format (started today)
        for fmt in ["h:mmaa", "HH:mm"] {
            timeFormatter.dateFormat = fmt
            if let time = timeFormatter.date(from: str) {
                let timeComponents = calendar.dateComponents([.hour, .minute], from: time)
                var todayComponents = calendar.dateComponents([.year, .month, .day], from: now)
                todayComponents.hour = timeComponents.hour
                todayComponents.minute = timeComponents.minute
                if let date = calendar.date(from: todayComponents) {
                    if date > now {
                        return calendar.date(byAdding: .day, value: -1, to: date)
                    }
                    return date
                }
            }
        }

        // Format: "MonDD" (started this year, not today) - e.g., "Jan15"
        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        for fmt in ["MMMdd", "ddMMM"] {
            dayFormatter.dateFormat = fmt
            if let date = dayFormatter.date(from: str) {
                var components = calendar.dateComponents([.month, .day], from: date)
                components.year = calendar.component(.year, from: now)
                return calendar.date(from: components)
            }
        }

        // Format: "YYYY" (started in a previous year)
        if str.count == 4, let year = Int(str) {
            var components = DateComponents()
            components.year = year
            components.month = 1
            components.day = 1
            return calendar.date(from: components)
        }

        return nil
    }

}
