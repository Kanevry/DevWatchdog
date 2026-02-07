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

    private var timer: Timer?
    private var config: WatchdogConfig?
    private let killer = ProcessKiller()
    private let notificationService = NotificationService()

    // Track processes pending auto-kill (PID -> first seen time)
    private var pendingKills: [Int32: Date] = [:]

    func start(config: WatchdogConfig) {
        self.config = config
        notificationService.requestPermission()
        scheduleTimer()

        // Initial scan
        Task { await scan() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func scan() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }

        let processes = await Task.detached {
            PSParser.parseProcessList()
        }.value

        guard let config else { return }

        var zombies: [DevProcess] = []
        var suspects: [DevProcess] = []
        var whitelisted: [DevProcess] = []

        for process in processes {
            if config.isWhitelisted(process) {
                whitelisted.append(process)
                continue
            }

            if let rule = config.matchingRule(for: process) {
                if rule.isTriggered(by: process) {
                    switch rule.action {
                    case .autoKill:
                        zombies.append(process)
                    case .warn:
                        suspects.append(process)
                    case .ignore, .whitelist:
                        break
                    }
                } else if rule.action != .ignore && rule.action != .whitelist {
                    // Matches pattern but thresholds not yet exceeded
                    suspects.append(process)
                }
            } else {
                // No specific rule, check general orphan heuristic
                if process.isOrphan && process.cpuPercent >= config.cpuThreshold
                    && (process.runtime ?? 0) >= config.runtimeThreshold {
                    zombies.append(process)
                } else if process.cpuPercent > 50 || (process.runtime ?? 0) > 600 {
                    suspects.append(process)
                }
            }
        }

        // Sort by severity (worst first)
        zombies.sort { $0.severity > $1.severity || ($0.severity == $1.severity && $0.cpuPercent > $1.cpuPercent) }
        suspects.sort { $0.cpuPercent > $1.cpuPercent }

        self.allProcesses = processes
        self.zombieProcesses = zombies
        self.suspectProcesses = suspects
        self.whitelistedProcesses = whitelisted
        self.totalCPU = processes.reduce(0) { $0 + $1.cpuPercent }
        self.totalMemoryMB = processes.reduce(0) { $0 + $1.memoryMB }
        self.lastScan = Date()

        // Handle auto-kill
        await handleAutoKill(zombies: zombies, config: config)

        // Notify about new suspects/zombies
        await handleNotifications(zombies: zombies, suspects: suspects, config: config)
    }

    func killProcess(_ process: DevProcess) {
        killer.kill(pid: process.pid)
        // Remove from lists immediately
        zombieProcesses.removeAll { $0.id == process.id }
        suspectProcesses.removeAll { $0.id == process.id }
        allProcesses.removeAll { $0.id == process.id }
        pendingKills.removeValue(forKey: process.pid)
    }

    func killAllZombies() {
        for process in zombieProcesses {
            killer.kill(pid: process.pid)
        }
        let count = zombieProcesses.count
        let cpuTotal = zombieProcesses.reduce(0) { $0 + $1.cpuPercent }
        zombieProcesses.removeAll()
        pendingKills.removeAll()

        if count > 0 {
            Task {
                await notificationService.send(
                    title: "Killed \(count) zombie processes",
                    body: "Freed \(String(format: "%.0f", cpuTotal))% CPU"
                )
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
        guard config.killMode != .notificationOnly else {
            pendingKills.removeAll()
            return
        }

        let now = Date()

        for zombie in zombies {
            if config.killMode == .aggressive {
                // Kill immediately
                killer.kill(pid: zombie.pid)
                await notificationService.send(
                    title: "Auto-killed: \(zombie.processName)",
                    body: "\(zombie.cpuFormatted) CPU, running \(zombie.runtimeFormatted)\(zombie.projectName.map { " (\($0))" } ?? "")"
                )
            } else {
                // Smart mode: grace period
                if let firstSeen = pendingKills[zombie.pid] {
                    if now.timeIntervalSince(firstSeen) >= config.gracePeriod {
                        killer.kill(pid: zombie.pid)
                        pendingKills.removeValue(forKey: zombie.pid)
                        await notificationService.send(
                            title: "Auto-killed: \(zombie.processName)",
                            body: "\(zombie.cpuFormatted) CPU, running \(zombie.runtimeFormatted)\(zombie.projectName.map { " (\($0))" } ?? "")"
                        )
                    }
                    // else: still within grace period, wait
                } else {
                    // First time seeing this zombie
                    pendingKills[zombie.pid] = now
                    let remaining = Int(config.gracePeriod)
                    await notificationService.send(
                        title: "Zombie detected: \(zombie.processName)",
                        body: "\(zombie.cpuFormatted) CPU, running \(zombie.runtimeFormatted). Will kill in \(remaining)s.\(zombie.projectName.map { " (\($0))" } ?? "")"
                    )
                }
            }
        }

        // Clean up pending kills for processes that are no longer zombies
        let zombiePIDs = Set(zombies.map(\.pid))
        pendingKills = pendingKills.filter { zombiePIDs.contains($0.key) }
    }

    private func handleNotifications(zombies: [DevProcess], suspects: [DevProcess], config: WatchdogConfig) async {
        // Sound on critical CPU load
        if config.soundOnCritical && totalCPU >= config.criticalCPUThreshold {
            await notificationService.send(
                title: "Critical CPU load: \(String(format: "%.0f", totalCPU))%",
                body: "\(zombies.count) zombies, \(suspects.count) suspects detected",
                sound: true
            )
        }
    }
}

// MARK: - Process List Parser (nonisolated for background execution)

enum PSParser: Sendable {
    struct PSParsed: Sendable {
        let user: String
        let pid: Int32
        let cpu: Double
        let mem: Double
        let rss: Int
        let command: String
        let startTime: Date?
    }

    static func parseProcessList() -> [DevProcess] {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["aux"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return []
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let output = String(data: data, encoding: .utf8) else { return [] }

        let lines = output.components(separatedBy: "\n")
        guard lines.count > 1 else { return [] }

        var results: [DevProcess] = []
        let currentUser = NSUserName()

        // Skip header line
        for line in lines.dropFirst() {
            guard !line.isEmpty else { continue }
            guard let parsed = parsePSLine(line) else { continue }

            // Only track the current user's processes
            guard parsed.user == currentUser else { continue }

            // Only track dev-related processes
            let cmd = parsed.command.lowercased()
            let isDevProcess = cmd.contains("node") || cmd.contains("vitest") ||
                cmd.contains("jest") || cmd.contains("tsc") || cmd.contains("esbuild") ||
                cmd.contains("next") || cmd.contains("webpack") || cmd.contains("turbo") ||
                cmd.contains("eslint") || cmd.contains("prettier") || cmd.contains("mcp") ||
                cmd.contains("pnpm") || cmd.contains("npm run") || cmd.contains("yarn")

            guard isDevProcess else { continue }

            // Check if orphan (parent PID = 1 means adopted by launchd)
            let parentPID = getParentPID(parsed.pid)
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
        // ps aux format: USER PID %CPU %MEM VSZ RSS TT STAT STARTED TIME COMMAND
        // Split by whitespace, but command can contain spaces
        let components = line.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: true)
        guard components.count >= 11 else { return nil }

        guard let pid = Int32(components[1]) else { return nil }
        let cpu = Double(components[2]) ?? 0
        let mem = Double(components[3]) ?? 0
        let rss = Int(components[5]) ?? 0
        let command = String(components[10])

        // Parse STARTED (column 8) - format varies: "HH:MM" or "MonDD" or "YYYY"
        let startedStr = String(components[8])
        let startTime = parseStartTime(startedStr)

        return PSParsed(
            user: String(components[0]),
            pid: pid,
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

    static func getParentPID(_ pid: Int32) -> Int32 {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "ppid=", "-p", "\(pid)"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if let str = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               let ppid = Int32(str) {
                return ppid
            }
        } catch {
            // ignore
        }
        return 0
    }
}
