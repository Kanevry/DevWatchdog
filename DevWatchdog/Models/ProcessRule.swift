import Foundation

struct ProcessRule: Identifiable, Codable, Hashable {
    let id: UUID
    var pattern: String
    var cpuThreshold: Double // Percent, e.g. 80
    var runtimeThreshold: TimeInterval // Seconds, e.g. 900 = 15 min
    var action: RuleAction
    var isEnabled: Bool

    enum RuleAction: String, Codable, CaseIterable {
        case autoKill = "auto_kill"
        case warn = "warn"
        case ignore = "ignore"
        case whitelist = "whitelist"

        var displayName: String {
            switch self {
            case .autoKill: return "Auto-Kill"
            case .warn: return "Warn"
            case .ignore: return "Ignore"
            case .whitelist: return "Whitelist (never kill)"
            }
        }
    }

    func matches(_ process: DevProcess) -> Bool {
        guard isEnabled else { return false }
        let cmd = process.command.lowercased()
        let pat = pattern.lowercased()

        // Support simple glob: "vitest.*forks" -> contains "vitest" and contains "forks"
        let parts = pat.split(separator: "*").map(String.init)
        if parts.count > 1 {
            return parts.allSatisfy { cmd.contains($0.trimmingCharacters(in: .punctuationCharacters)) }
        }
        return cmd.contains(pat)
    }

    func isTriggered(by process: DevProcess) -> Bool {
        guard matches(process) else { return false }
        guard action != .whitelist && action != .ignore else { return false }

        let cpuExceeded = process.cpuPercent >= cpuThreshold
        let runtimeExceeded = (process.runtime ?? 0) >= runtimeThreshold

        return cpuExceeded && runtimeExceeded
    }

    static var defaultRules: [ProcessRule] {
        [
            ProcessRule(
                id: UUID(), pattern: "vitest.*forks",
                cpuThreshold: 80, runtimeThreshold: 900,
                action: .autoKill, isEnabled: true
            ),
            ProcessRule(
                id: UUID(), pattern: "vitest.*worker",
                cpuThreshold: 80, runtimeThreshold: 900,
                action: .autoKill, isEnabled: true
            ),
            ProcessRule(
                id: UUID(), pattern: "vitest.*child",
                cpuThreshold: 80, runtimeThreshold: 900,
                action: .autoKill, isEnabled: true
            ),
            ProcessRule(
                id: UUID(), pattern: "jest.*worker",
                cpuThreshold: 80, runtimeThreshold: 900,
                action: .autoKill, isEnabled: true
            ),
            ProcessRule(
                id: UUID(), pattern: "jest",
                cpuThreshold: 80, runtimeThreshold: 900,
                action: .autoKill, isEnabled: true
            ),
            ProcessRule(
                id: UUID(), pattern: "tsc",
                cpuThreshold: 50, runtimeThreshold: 1800,
                action: .warn, isEnabled: true
            ),
            ProcessRule(
                id: UUID(), pattern: "esbuild.*service",
                cpuThreshold: 0, runtimeThreshold: 3600,
                action: .autoKill, isEnabled: true
            ),
            ProcessRule(
                id: UUID(), pattern: "next.*dev",
                cpuThreshold: 0, runtimeThreshold: 0,
                action: .whitelist, isEnabled: true
            ),
            ProcessRule(
                id: UUID(), pattern: "mcp",
                cpuThreshold: 5, runtimeThreshold: 7200,
                action: .warn, isEnabled: true
            ),
        ]
    }
}
