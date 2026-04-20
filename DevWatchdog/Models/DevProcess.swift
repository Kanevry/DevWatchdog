import Foundation

/// Unix process state, parsed from the `ps` `state` column.
enum ProcessState: String, Sendable, Codable, Hashable {
    /// Normal running / sleeping / idle states ('R', 'S', 'I', 'U', 'D', 'W').
    case running
    /// Stopped via SIGSTOP / SIGTSTP ('T').
    case stopped
    /// Unix-level zombie process ('Z') — distinct from DevWatchdog's "zombie" concept.
    case zombie
    /// Could not be determined.
    case unknown

    /// Map a `ps` state string (first character matters) to a ``ProcessState``.
    init(psStateString: String) {
        guard let first = psStateString.uppercased().first else {
            self = .unknown
            return
        }
        switch first {
        case "T": self = .stopped
        case "Z": self = .zombie
        case "R", "S", "I", "U", "D", "W": self = .running
        default: self = .unknown
        }
    }
}

struct DevProcess: Identifiable, Hashable, Sendable {
    let id: Int32 // PID
    let user: String
    let cpuPercent: Double
    let memPercent: Double
    let rss: Int // KB
    let command: String
    let startTime: Date?
    let parentPID: Int32
    let isOrphan: Bool
    let state: ProcessState

    init(
        id: Int32,
        user: String,
        cpuPercent: Double,
        memPercent: Double,
        rss: Int,
        command: String,
        startTime: Date?,
        parentPID: Int32,
        isOrphan: Bool,
        state: ProcessState = .unknown
    ) {
        self.id = id
        self.user = user
        self.cpuPercent = cpuPercent
        self.memPercent = memPercent
        self.rss = rss
        self.command = command
        self.startTime = startTime
        self.parentPID = parentPID
        self.isOrphan = isOrphan
        self.state = state
    }

    var pid: Int32 { id }

    var runtime: TimeInterval? {
        guard let start = startTime else { return nil }
        return Date().timeIntervalSince(start)
    }

    var runtimeFormatted: String {
        guard let runtime else { return "?" }
        let minutes = Int(runtime) / 60
        let hours = minutes / 60
        if hours > 0 {
            return "\(hours)h \(minutes % 60)m"
        }
        return "\(minutes)m"
    }

    var memoryMB: Double {
        Double(rss) / 1024.0
    }

    var memoryFormatted: String {
        if memoryMB >= 1024 {
            return String(format: "%.1f GB", memoryMB / 1024.0)
        }
        return String(format: "%.0f MB", memoryMB)
    }

    var cpuFormatted: String {
        String(format: "%.0f%%", cpuPercent)
    }

    var processName: String {
        // Extract meaningful name from command
        let cmd = command

        if cmd.contains("vitest") {
            if cmd.contains("forks") || cmd.contains("child") {
                return "vitest (fork worker)"
            }
            if cmd.contains("worker") {
                return "vitest (worker)"
            }
            return "vitest"
        }
        if cmd.contains("jest") {
            if cmd.contains("worker") {
                return "jest (worker)"
            }
            return "jest"
        }
        if cmd.contains("tsgo") {
            return "tsgo"
        }
        if cmd.contains("tsc") || cmd.contains("typescript") {
            return "tsc"
        }
        if cmd.contains("esbuild") {
            if cmd.contains("--service") {
                return "esbuild (service)"
            }
            return "esbuild"
        }
        if cmd.contains("next") && cmd.contains("build") {
            return "next build"
        }
        if cmd.contains("next") && cmd.contains("dev") {
            return "next dev"
        }
        if cmd.contains("next") {
            return "next.js"
        }
        if cmd.contains("ms-playwright") || cmd.contains("playwright") {
            if cmd.contains("chromium") { return "Chromium (Playwright)" }
            if cmd.contains("firefox") { return "Firefox (Playwright)" }
            if cmd.contains("webkit") { return "WebKit (Playwright)" }
            return "Playwright"
        }
        if cmd.contains("percy") {
            return "Percy"
        }
        if cmd.contains("react-email") {
            return "react-email"
        }
        if cmd.contains("mcp") {
            return "MCP server"
        }
        if cmd.contains("webpack") {
            return "webpack"
        }
        if cmd.contains("turbopack") || cmd.contains("turbo") {
            return "turbopack"
        }
        if cmd.contains("eslint") {
            return "eslint"
        }
        if cmd.contains("prettier") {
            return "prettier"
        }
        if cmd.contains("pnpm") || cmd.contains("npm") || cmd.contains("yarn") {
            return "package manager"
        }
        if cmd.contains("bun") {
            return "bun"
        }
        if cmd.contains("deno") {
            return "deno"
        }
        if cmd.contains("swc") {
            return "swc"
        }

        // Fallback: last path component of first arg
        let parts = cmd.split(separator: " ")
        if let first = parts.first {
            let pathParts = first.split(separator: "/")
            return String(pathParts.last ?? first)
        }
        return "node"
    }

    var projectName: String? {
        let markers = ["/Projects/", "/Developer/", "/repos/", "/src/", "/workspace/", "/Sites/"]
        for marker in markers {
            if let range = command.range(of: marker, options: .caseInsensitive) {
                let after = command[range.upperBound...]
                let projectPart = after.prefix(while: { $0 != "/" && $0 != " " })
                if !projectPart.isEmpty { return String(projectPart) }
            }
        }
        return nil
    }

    // Severity for sorting — orphan is the primary signal
    var severity: Int {
        if isOrphan { return 3 }
        if cpuPercent > 80 { return 2 }
        if cpuPercent > 50 { return 1 }
        return 0
    }
}

// MARK: - Process Grouping

struct ProcessGroup: Identifiable, Sendable {
    let id: String
    let name: String
    let projectName: String?
    let processes: [DevProcess]

    var totalCPU: Double { processes.reduce(0) { $0 + $1.cpuPercent } }
    var totalMemoryMB: Double { processes.reduce(0) { $0 + $1.memoryMB } }
    var count: Int { processes.count }
    var maxCPU: Double { processes.map(\.cpuPercent).max() ?? 0 }
    var hasOrphans: Bool { processes.contains { $0.isOrphan } }
}

extension Array where Element == DevProcess {
    func grouped() -> [ProcessGroup] {
        let dict = Dictionary(grouping: self) { process in
            "\(process.processName)-\(process.parentPID)"
        }
        return dict.map { (key, processes) in
            ProcessGroup(
                id: key,
                name: processes.first?.processName ?? "unknown",
                projectName: processes.first?.projectName,
                processes: processes
            )
        }
        .sorted { $0.totalCPU > $1.totalCPU }
    }
}
