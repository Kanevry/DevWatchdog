import Foundation

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
        if cmd.contains("tsc") || cmd.contains("typescript") {
            return "tsc"
        }
        if cmd.contains("esbuild") {
            if cmd.contains("--service") {
                return "esbuild (service)"
            }
            return "esbuild"
        }
        if cmd.contains("next") && cmd.contains("dev") {
            return "next dev"
        }
        if cmd.contains("next") {
            return "next.js"
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

        // Fallback: last path component of first arg
        let parts = cmd.split(separator: " ")
        if let first = parts.first {
            let pathParts = first.split(separator: "/")
            return String(pathParts.last ?? first)
        }
        return "node"
    }

    var projectName: String? {
        // Extract project from path: /Users/.../Projects/ProjectName/...
        guard let range = command.range(of: "/Projects/") else { return nil }
        let after = command[range.upperBound...]
        let projectPart = after.prefix(while: { $0 != "/" && $0 != " " })
        if projectPart.isEmpty { return nil }
        return String(projectPart)
    }

    // Severity for sorting
    var severity: Int {
        if isOrphan && cpuPercent > 80 { return 3 }
        if cpuPercent > 80 { return 2 }
        if cpuPercent > 50 { return 1 }
        return 0
    }
}
