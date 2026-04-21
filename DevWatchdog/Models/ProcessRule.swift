import Foundation

struct ProcessRule: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var pattern: String
    var cpuThreshold: Double // Percent — for warn trigger (e.g. 50)
    var runtimeThreshold: TimeInterval // Seconds — for warn trigger (e.g. 1800)
    var maxRuntime: TimeInterval // Seconds — hard kill limit (0 = no limit). Exceeding this → zombie.

    // MARK: - Absolute thresholds (Emergency-Mode, issue #5)
    /// Hard kill trigger when CPU% exceeds this value. 0 = disabled. Fires independent of runtime.
    var maxCPUPercent: Double
    /// Hard kill trigger when RSS (MB) exceeds this value. 0 = disabled.
    var maxRSSMB: Double
    /// Combinator for the hard kill thresholds (runtime / CPU / RSS).
    var thresholdMode: ThresholdMode

    var action: RuleAction
    var isEnabled: Bool
    var onlyWhenOrphan: Bool
    var matchMode: MatchMode

    init(
        id: UUID,
        pattern: String,
        cpuThreshold: Double,
        runtimeThreshold: TimeInterval,
        maxRuntime: TimeInterval,
        maxCPUPercent: Double = 0,
        maxRSSMB: Double = 0,
        thresholdMode: ThresholdMode = .any,
        action: RuleAction,
        isEnabled: Bool,
        onlyWhenOrphan: Bool = false,
        matchMode: MatchMode = .substring
    ) {
        self.id = id
        self.pattern = pattern
        self.cpuThreshold = cpuThreshold
        self.runtimeThreshold = runtimeThreshold
        self.maxRuntime = maxRuntime
        self.maxCPUPercent = maxCPUPercent
        self.maxRSSMB = maxRSSMB
        self.thresholdMode = thresholdMode
        self.action = action
        self.isEnabled = isEnabled
        self.onlyWhenOrphan = onlyWhenOrphan
        self.matchMode = matchMode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        pattern = try container.decode(String.self, forKey: .pattern)
        cpuThreshold = try container.decode(Double.self, forKey: .cpuThreshold)
        runtimeThreshold = try container.decode(TimeInterval.self, forKey: .runtimeThreshold)
        maxRuntime = try container.decode(TimeInterval.self, forKey: .maxRuntime)
        maxCPUPercent = try container.decodeIfPresent(Double.self, forKey: .maxCPUPercent) ?? 0
        maxRSSMB = try container.decodeIfPresent(Double.self, forKey: .maxRSSMB) ?? 0
        thresholdMode = try container.decodeIfPresent(ThresholdMode.self, forKey: .thresholdMode) ?? .any
        action = try container.decode(RuleAction.self, forKey: .action)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        onlyWhenOrphan = try container.decodeIfPresent(Bool.self, forKey: .onlyWhenOrphan) ?? false
        matchMode = try container.decodeIfPresent(MatchMode.self, forKey: .matchMode) ?? .substring
    }

    enum CodingKeys: String, CodingKey {
        case id
        case pattern
        case cpuThreshold
        case runtimeThreshold
        case maxRuntime
        case maxCPUPercent
        case maxRSSMB
        case thresholdMode
        case action
        case isEnabled
        case onlyWhenOrphan
        case matchMode
    }

    enum RuleAction: String, Codable, CaseIterable, Sendable {
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

    enum ThresholdMode: String, Codable, CaseIterable, Sendable {
        case any
        case all

        var displayName: String {
            self == .any ? "Any threshold (OR)" : "All thresholds (AND)"
        }
    }

    enum MatchMode: String, Codable, CaseIterable, Sendable {
        case substring   // cmd.contains(pattern) — exactly like current default
        case glob        // shell-style: * matches any chars, ? matches single char, anchored at both ends
        case regex       // full NSRegularExpression (anchors and case handled inside pattern)

        var displayName: String {
            switch self {
            case .substring: return "Substring"
            case .glob:      return "Glob"
            case .regex:     return "Regex"
            }
        }
    }

    func matches(_ process: DevProcess) -> Bool {
        guard isEnabled else { return false }
        let cmd = process.command.lowercased()
        let pat = pattern.lowercased()
        guard !pat.isEmpty else { return false }

        switch matchMode {
        case .substring:
            // Preserve legacy split-on-'*' behavior so existing rules and JSON continue to work.
            // Patterns without '*' fall through to plain contains.
            let parts = pat.split(separator: "*").map(String.init)
            if parts.count > 1 {
                return parts.allSatisfy { cmd.contains($0.trimmingCharacters(in: .punctuationCharacters)) }
            }
            return cmd.contains(pat)

        case .glob:
            return Self.globMatches(pattern: pat, input: cmd)

        case .regex:
            // For regex we preserve user's case semantics (pass options in regex)
            return Self.regexMatches(pattern: pattern, input: process.command)
        }
    }

    private static func globMatches(pattern: String, input: String) -> Bool {
        // Convert glob to regex: escape all regex metachars EXCEPT * and ?
        // * → .*   ? → .   else: escape
        var regex = "^"
        for ch in pattern {
            switch ch {
            case "*": regex += ".*"
            case "?": regex += "."
            case ".", "+", "(", ")", "[", "]", "{", "}", "^", "$", "|", "\\":
                regex += "\\\(ch)"
            default:
                regex.append(ch)
            }
        }
        regex += "$"
        return regexMatches(pattern: regex, input: input)
    }

    private static func regexMatches(pattern: String, input: String) -> Bool {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return false
        }
        let range = NSRange(input.startIndex..., in: input)
        return re.firstMatch(in: input, options: [], range: range) != nil
    }

    /// Whether the warn thresholds are exceeded (CPU AND runtime).
    func isTriggered(by process: DevProcess) -> Bool {
        guard matches(process) else { return false }
        guard action == .warn else { return false }
        if onlyWhenOrphan && !process.isOrphan { return false }

        let cpuExceeded = process.cpuPercent >= cpuThreshold
        let runtimeExceeded = (process.runtime ?? 0) >= runtimeThreshold

        return cpuExceeded && runtimeExceeded
    }

    /// Whether the hard runtime kill limit is exceeded.
    func isMaxRuntimeExceeded(by process: DevProcess) -> Bool {
        guard matches(process) else { return false }
        guard maxRuntime > 0 else { return false }
        if onlyWhenOrphan && !process.isOrphan { return false }
        return (process.runtime ?? 0) >= maxRuntime
    }

    /// Whether the absolute CPU% kill threshold is exceeded.
    func isMaxCPUExceeded(by process: DevProcess) -> Bool {
        guard matches(process) else { return false }
        guard maxCPUPercent > 0 else { return false }
        if onlyWhenOrphan && !process.isOrphan { return false }
        return process.cpuPercent >= maxCPUPercent
    }

    /// Whether the absolute RSS (MB) kill threshold is exceeded.
    func isMaxRSSExceeded(by process: DevProcess) -> Bool {
        guard matches(process) else { return false }
        guard maxRSSMB > 0 else { return false }
        if onlyWhenOrphan && !process.isOrphan { return false }
        return process.memoryMB >= maxRSSMB
    }

    /// True when the hard kill limits (runtime/CPU/RSS) are exceeded per `thresholdMode`.
    ///
    /// `.any` (default): true if any single configured (non-zero) threshold is exceeded.
    /// `.all`: true only if ALL configured (non-zero) thresholds are exceeded. A disabled
    /// threshold (0) is treated as "not required". With zero thresholds configured, returns false.
    func shouldHardKill(_ process: DevProcess) -> Bool {
        guard matches(process) else { return false }
        if onlyWhenOrphan && !process.isOrphan { return false }

        let runtimeConfigured = maxRuntime > 0
        let cpuConfigured = maxCPUPercent > 0
        let rssConfigured = maxRSSMB > 0

        let runtimeExceeded = runtimeConfigured && (process.runtime ?? 0) >= maxRuntime
        let cpuExceeded = cpuConfigured && process.cpuPercent >= maxCPUPercent
        let rssExceeded = rssConfigured && process.memoryMB >= maxRSSMB

        switch thresholdMode {
        case .any:
            return runtimeExceeded || cpuExceeded || rssExceeded
        case .all:
            let configuredCount = (runtimeConfigured ? 1 : 0) + (cpuConfigured ? 1 : 0) + (rssConfigured ? 1 : 0)
            guard configuredCount > 0 else { return false }
            // Every configured threshold must be exceeded. Disabled thresholds are ignored.
            if runtimeConfigured && !runtimeExceeded { return false }
            if cpuConfigured && !cpuExceeded { return false }
            if rssConfigured && !rssExceeded { return false }
            return true
        }
    }

    // MARK: - Default Rules (based on BuchhaltGenieV5 cleanup-zombies.sh thresholds)

    static var defaultRules: [ProcessRule] {
        [
            // ── Test Workers (short-lived, should never run this long) ──
            rule("vitest.*forks",   warn: (cpu: 0, rt: 600),   kill: 1200, maxRSSMB: 2000),  // 20min
            rule("vitest.*worker",  warn: (cpu: 0, rt: 600),   kill: 1200, maxRSSMB: 2000),  // 20min
            rule("vitest.*child",   warn: (cpu: 0, rt: 600),   kill: 1200, maxRSSMB: 2000),  // 20min
            rule("vitest",          warn: (cpu: 0, rt: 600),   kill: 900,  maxRSSMB: 2000),  // 15min main
            rule("jest.*worker",    warn: (cpu: 0, rt: 600),   kill: 900,  maxRSSMB: 2000),  // 15min
            rule("jest",            warn: (cpu: 0, rt: 600),   kill: 900,  maxRSSMB: 2000),  // 15min

            // ── Type Checking (should be fast) ──
            rule("tsgo",            warn: (cpu: 0, rt: 120),   kill: 300,  maxCPUPercent: 300, maxRSSMB: 1500), // 5min
            rule("tsc",             warn: (cpu: 0, rt: 240),   kill: 480,  maxCPUPercent: 300, maxRSSMB: 1500), // 8min

            // ── Build Processes ──
            rule("next.*build",     warn: (cpu: 0, rt: 600),   kill: 1200, maxRSSMB: 3000),  // 20min
            rule("esbuild",         warn: (cpu: 0, rt: 600),   kill: 1200, maxCPUPercent: 400, maxRSSMB: 1500), // 20min

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
            rule("mcp",             warn: (cpu: 0, rt: 7200),  kill: 14400, maxRSSMB: 1000, onlyWhenOrphan: true), // 4h

            // ── Runtimes ──
            rule("bun",             warn: (cpu: 0, rt: 600),   kill: 1200, maxRSSMB: 1500),  // 20min
            rule("deno",            warn: (cpu: 0, rt: 600),   kill: 1200, maxRSSMB: 1500),  // 20min

            // ── Compilers ──
            rule("swc",             warn: (cpu: 0, rt: 600),   kill: 1200, maxRSSMB: 1500),  // 20min

            // ── Package Managers ──
            rule("pnpm",            warn: (cpu: 0, rt: 900),   kill: 1800),  // 30min
            rule("npm run",         warn: (cpu: 0, rt: 900),   kill: 1800),  // 30min
        ]
    }

    /// Convenience initializer for default rules.
    private static func rule(
        _ pattern: String,
        warn: (cpu: Double, rt: TimeInterval),
        kill maxRuntime: TimeInterval,
        maxCPUPercent: Double = 0,
        maxRSSMB: Double = 0,
        thresholdMode: ThresholdMode = .any,
        onlyWhenOrphan: Bool = false
    ) -> ProcessRule {
        ProcessRule(
            id: UUID(),
            pattern: pattern,
            cpuThreshold: warn.cpu,
            runtimeThreshold: warn.rt,
            maxRuntime: maxRuntime,
            maxCPUPercent: maxCPUPercent,
            maxRSSMB: maxRSSMB,
            thresholdMode: thresholdMode,
            action: .warn,
            isEnabled: true,
            onlyWhenOrphan: onlyWhenOrphan
        )
    }
}
