import Foundation

struct ProcessRule: Identifiable, Codable, Hashable {
    let id: UUID
    var pattern: String
    var cpuThreshold: Double // Percent — for warn trigger (e.g. 50)
    var runtimeThreshold: TimeInterval // Seconds — for warn trigger (e.g. 1800)
    var maxRuntime: TimeInterval // Seconds — hard kill limit (0 = no limit). Exceeding this → zombie.
    var action: RuleAction
    var isEnabled: Bool

    enum RuleAction: String, Codable, CaseIterable {
        case whitelist = "whitelist"
        case warn = "warn"
        case ignore = "ignore"

        var displayName: String {
            switch self {
            case .whitelist: return "Whitelist (never kill)"
            case .warn: return "Warn"
            case .ignore: return "Ignore"
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

    /// Whether the warn thresholds are exceeded (CPU AND runtime).
    func isTriggered(by process: DevProcess) -> Bool {
        guard matches(process) else { return false }
        guard action == .warn else { return false }

        let cpuExceeded = process.cpuPercent >= cpuThreshold
        let runtimeExceeded = (process.runtime ?? 0) >= runtimeThreshold

        return cpuExceeded && runtimeExceeded
    }

    /// Whether the hard kill limit is exceeded.
    func isMaxRuntimeExceeded(by process: DevProcess) -> Bool {
        guard matches(process) else { return false }
        guard maxRuntime > 0 else { return false }
        return (process.runtime ?? 0) >= maxRuntime
    }

    // MARK: - Default Rules (based on BuchhaltGenieV5 cleanup-zombies.sh thresholds)

    static var defaultRules: [ProcessRule] {
        [
            // ── Test Workers (short-lived, should never run this long) ──
            rule("vitest.*forks",   warn: (cpu: 0, rt: 600),   kill: 1200),  // 20min
            rule("vitest.*worker",  warn: (cpu: 0, rt: 600),   kill: 1200),  // 20min
            rule("vitest.*child",   warn: (cpu: 0, rt: 600),   kill: 1200),  // 20min
            rule("vitest",          warn: (cpu: 0, rt: 600),   kill: 900),   // 15min main
            rule("jest.*worker",    warn: (cpu: 0, rt: 600),   kill: 900),   // 15min
            rule("jest",            warn: (cpu: 0, rt: 600),   kill: 900),   // 15min

            // ── Type Checking (should be fast) ──
            rule("tsgo",            warn: (cpu: 0, rt: 120),   kill: 300),   // 5min
            rule("tsc",             warn: (cpu: 0, rt: 240),   kill: 480),   // 8min

            // ── Build Processes ──
            rule("next.*build",     warn: (cpu: 0, rt: 600),   kill: 1200),  // 20min
            rule("esbuild",         warn: (cpu: 0, rt: 600),   kill: 1200),  // 20min

            // ── E2E / Visual Testing + Browsers ──
            rule("playwright",      warn: (cpu: 0, rt: 300),   kill: 600),   // 10min
            rule("ms-playwright.*chromium", warn: (cpu: 0, rt: 300), kill: 600),
            rule("ms-playwright.*firefox",  warn: (cpu: 0, rt: 300), kill: 600),
            rule("ms-playwright.*webkit",   warn: (cpu: 0, rt: 300), kill: 600),
            rule("percy",           warn: (cpu: 0, rt: 1800),  kill: 2700),  // 45min

            // ── Dev Servers (long-lived but not forever) ──
            rule("next.*dev",       warn: (cpu: 0, rt: 7200),  kill: 10800), // 3h
            rule("react-email",     warn: (cpu: 0, rt: 3600),  kill: 7200),  // 2h

            // ── MCP Servers ──
            rule("mcp",             warn: (cpu: 0, rt: 7200),  kill: 14400), // 4h

            // ── Package Managers ──
            rule("pnpm",            warn: (cpu: 0, rt: 900),   kill: 1800),  // 30min
            rule("npm run",         warn: (cpu: 0, rt: 900),   kill: 1800),  // 30min
        ]
    }

    /// Convenience initializer for default rules.
    private static func rule(
        _ pattern: String,
        warn: (cpu: Double, rt: TimeInterval),
        kill maxRuntime: TimeInterval
    ) -> ProcessRule {
        ProcessRule(
            id: UUID(),
            pattern: pattern,
            cpuThreshold: warn.cpu,
            runtimeThreshold: warn.rt,
            maxRuntime: maxRuntime,
            action: .warn,
            isEnabled: true
        )
    }
}
