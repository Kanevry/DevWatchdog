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

    private var timer: Timer?
    private var config: WatchdogConfig?
    private var cancellables = Set<AnyCancellable>()
    private let killer = ProcessKiller()
    private let notificationService = NotificationService()

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

        // Request notification permission
        Task {
            await notificationService.requestPermission()
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
    }


    func scan() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }

        let excludedApps = config?.excludedApps ?? WatchdogConfig.defaultExcludedApps
        let processes = await Task.detached {
            PSParser.parseProcessList(excludedApps: excludedApps)
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
                // Hard kill limit exceeded → zombie (even with living parent)
                if rule.isMaxRuntimeExceeded(by: process) {
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
        let result = killer.kill(pid: process.pid)
        switch result {
        case .success, .alreadyDead:
            zombieProcesses.removeAll { $0.id == process.id }
            suspectProcesses.removeAll { $0.id == process.id }
            allProcesses.removeAll { $0.id == process.id }
            pendingKills.removeValue(forKey: process.pid)
            notifiedZombiePIDs.remove(process.pid)
        case .permissionDenied:
            lastError = "Permission denied for PID \(process.pid)"
            Task {
                await notificationService.send(
                    title: "Kill failed",
                    body: "Permission denied for \(process.processName) (PID \(process.pid))."
                )
            }
        case .failed(let err):
            lastError = "Kill failed for PID \(process.pid) (errno: \(err))"
        }
        // Clear error after 5 seconds
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
            _ = killer.kill(pid: process.pid)
        }
        zombieProcesses.removeAll()
        pendingKills.removeAll()
        notifiedZombiePIDs.removeAll()

        if count > 0 {
            Task {
                await notificationService.sendBatchKillSummary(count: count, freedMemoryMB: memoryMB)
            }
        }
    }

    func killAllSuspects() {
        let memoryMB = suspectProcesses.reduce(0.0) { $0 + $1.memoryMB }
        let count = suspectProcesses.count

        for process in suspectProcesses {
            _ = killer.kill(pid: process.pid)
        }
        suspectProcesses.removeAll()
        allProcesses.removeAll { p in !zombieProcesses.contains(where: { $0.id == p.id }) && !whitelistedProcesses.contains(where: { $0.id == p.id }) }

        if count > 0 {
            Task {
                await notificationService.sendBatchKillSummary(count: count, freedMemoryMB: memoryMB)
            }
        }
    }

    // MARK: - Private

    private func scheduleTimer() {
        timer?.invalidate()
        let interval = config?.scanInterval ?? 30
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.scan()
            }
        }
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

        for zombie in zombies {
            if let entry = pendingKills[zombie.pid] {
                if now.timeIntervalSince(entry.firstSeen) >= entry.gracePeriod {
                    _ = killer.kill(pid: zombie.pid)
                    pendingKills.removeValue(forKey: zombie.pid)
                    notifiedZombiePIDs.remove(zombie.pid)
                    killedCount += 1
                    freedMemory += zombie.memoryMB
                }
                // else: still within grace period, wait
            } else {
                // First time seeing this zombie — start grace period
                pendingKills[zombie.pid] = (firstSeen: now, gracePeriod: config.gracePeriod)
            }
        }

        // Send batch kill summary
        if killedCount > 0 {
            await notificationService.sendBatchKillSummary(count: killedCount, freedMemoryMB: freedMemory)

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
        let command: String
        let startTime: Date?
    }

    static func parseProcessList(excludedApps: [String]) -> [DevProcess] {
        let pipe = Pipe()
        let process = Process()

        // Check if ps command exists before running
        let psURL = URL(fileURLWithPath: "/bin/ps")
        guard FileManager.default.fileExists(atPath: psURL.path) else {
            print("DevWatchdog: ps command not found at /bin/ps")
            return []
        }

        process.executableURL = psURL
        process.arguments = ["-eo", "user=,pid=,ppid=,%cpu=,%mem=,rss=,start=,args="]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            print("DevWatchdog: Failed to run ps command: \(error.localizedDescription)")
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
            let isDevProcess = cmd.contains("node") || cmd.contains("vitest") ||
                cmd.contains("jest") || cmd.contains("tsc") || cmd.contains("tsgo") ||
                cmd.contains("esbuild") || cmd.contains("next") || cmd.contains("webpack") ||
                cmd.contains("turbo") || cmd.contains("eslint") || cmd.contains("prettier") ||
                cmd.contains("mcp") || cmd.contains("pnpm") || cmd.contains("npm run") ||
                cmd.contains("yarn") || cmd.contains("playwright") ||
                cmd.contains("ms-playwright") || cmd.contains("percy") ||
                cmd.contains("react-email")

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
                isOrphan: isOrphan
            )
            results.append(devProcess)
        }

        return results
    }

    static func parsePSLine(_ line: String) -> PSParsed? {
        // ps -eo format: USER PID PPID %CPU %MEM RSS STARTED ARGS
        // Split by whitespace, but args (command) can contain spaces
        let components = line.split(separator: " ", maxSplits: 7, omittingEmptySubsequences: true)
        guard components.count >= 8 else { return nil }

        guard let pid = Int32(components[1]) else { return nil }
        guard let ppid = Int32(components[2]) else { return nil }
        let cpu = Double(components[3]) ?? 0
        let mem = Double(components[4]) ?? 0
        let rss = Int(components[5]) ?? 0
        let command = String(components[7])

        // Parse STARTED (column 6) - format varies: "HH:MM" or "MonDD" or "YYYY"
        let startedStr = String(components[6])
        let startTime = parseStartTime(startedStr)

        return PSParsed(
            user: String(components[0]),
            pid: pid,
            ppid: ppid,
            cpu: cpu,
            mem: mem,
            rss: rss,
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
