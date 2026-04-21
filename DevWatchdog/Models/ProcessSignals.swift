import Foundation

/// Single, user-readable badge explaining *why* a process is on the list.
///
/// Badges are computed by ``ProcessSignalsAnalyzer`` from a ``DevProcess``'s
/// raw measurements (CPU, RSS, runtime, orphan confidence, rule matches).
/// The UI renders each badge as a small capsule in ``ProcessRowView``, in
/// priority order (most-actionable-first).
///
/// Keep raw values inside `.detail` short enough to fit a capsule — UI code
/// may truncate to ~20 characters.
enum ProcessSignal: Sendable, Hashable {
    /// Parent died between scans (`PPID: X → 1`). Fast-track zombie.
    case newlyOrphaned
    /// Parent has always been PID 1. Maybe a legitimate launchd daemon —
    /// treat conservatively.
    case adoptedByLaunchd
    /// Not quantitatively active — `cpuPercent ≤ 0.1` for this scan.
    /// `minutes` reflects how long the process has been running (not how
    /// long it has been idle — we don't track per-PID CPU history yet).
    case idle(minutes: Int)
    /// High CPU right now — likely an active test/build the user cares about.
    case active(percent: Int)
    /// High RSS but effectively no CPU activity — classic memory leak.
    case memoryLeak(mb: Int)
    /// A configured ``ProcessRule`` with `.warn` action triggered (thresholds
    /// crossed but not yet at hard-kill limits).
    case ruleWarn(pattern: String)
    /// Hard-kill limit on a rule was exceeded — CPU% / RSS / runtime.
    case ruleHardKill(pattern: String, trigger: String)
    /// Orphan/rule-independent: running longer than the catch-all safety net.
    case catchAllExpired
    /// Process already STOPPED (SIGSTOP) — user is mid-inspection.
    case paused

    /// Short user-facing label. English base — localize when the catalog lands.
    var label: String {
        switch self {
        case .newlyOrphaned:      return "NEW ORPHAN"
        case .adoptedByLaunchd:   return "ORPHAN"
        case .idle(let m):        return "IDLE \(m)m"
        case .active(let p):      return "ACTIVE \(p)%"
        case .memoryLeak(let mb): return "LEAK \(mb)MB"
        case .ruleWarn(let p):    return "RULE: \(p)"
        case .ruleHardKill(let p, let trigger):
                                  return "KILL: \(p) · \(trigger)"
        case .catchAllExpired:    return "EXPIRED"
        case .paused:             return "PAUSED"
        }
    }
}

/// Overall "how confident are we this is killable" rating. Drives row-level
/// color coding in the menu bar so the user can scan a list quickly.
///
/// - `.high` = orange/red row tint — strong reason to kill.
/// - `.medium` = standard row — review recommended.
/// - `.low` = subtle row — likely intentional (active process, paused).
enum KillConfidence: Int, Sendable, Hashable, Comparable {
    case low = 0
    case medium = 1
    case high = 2

    static func < (lhs: KillConfidence, rhs: KillConfidence) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Bundle of derived signals attached to a process by ``ProcessSignalsAnalyzer``.
///
/// Kept as a separate value-type so the analyzer can be unit-tested without
/// dragging in `ProcessMonitor`, `WatchdogConfig`, or UIKit/SwiftUI.
struct ProcessSignals: Sendable, Hashable {
    /// Prioritized badge list (most actionable first). Limit to ~3 in UI.
    let badges: [ProcessSignal]
    /// Aggregate "is this safe to kill" rating.
    let confidence: KillConfidence

    static let empty = ProcessSignals(badges: [], confidence: .low)
}

/// Pure, testable classifier that turns a ``DevProcess`` + rule match into a
/// ``ProcessSignals`` value. No side effects, no actor isolation required.
enum ProcessSignalsAnalyzer {

    /// CPU threshold below which we consider a process "idle" for badging.
    static let idleCPUThreshold: Double = 0.1
    /// Absolute RSS threshold for memory-leak heuristic (MB).
    static let leakRSSThresholdMB: Double = 500
    /// CPU threshold above which we consider a process "actively working".
    static let activeCPUThreshold: Double = 25

    /// Analyze one process. `rule` should be the highest-priority matching
    /// enabled ``ProcessRule`` (if any); `hardKillTrigger` should be a
    /// short string like "CPU" / "RSS" / "runtime" when the rule's hard-kill
    /// path is tripped, else `nil`.
    static func analyze(
        _ process: DevProcess,
        rule: ProcessRule? = nil,
        hardKillTrigger: String? = nil,
        catchAllExceeded: Bool = false
    ) -> ProcessSignals {
        var out: [ProcessSignal] = []
        var confidence: KillConfidence = .low

        // 1. Paused — always surface first; overrides killable-looking flags.
        if process.state == .stopped {
            out.append(.paused)
            confidence = max(confidence, .low)
        }

        // 2. Orphan confidence
        switch process.orphanConfidence {
        case .reparented:
            out.append(.newlyOrphaned)
            confidence = max(confidence, .high)
        case .knownSinceFirstSeen:
            // Only badge if long-running enough to be interesting; otherwise
            // it's probably a short-lived daemon.
            if let rt = process.runtime, rt > 60 {
                out.append(.adoptedByLaunchd)
                confidence = max(confidence, .medium)
            }
        case .none:
            break
        }

        // 3. Rule-driven signals
        if let rule {
            if let trigger = hardKillTrigger {
                out.append(.ruleHardKill(pattern: rule.pattern, trigger: trigger))
                confidence = max(confidence, .high)
            } else if rule.action == .warn {
                out.append(.ruleWarn(pattern: rule.pattern))
                confidence = max(confidence, .medium)
            }
        }

        // 4. Catch-all safety net
        if catchAllExceeded {
            out.append(.catchAllExpired)
            confidence = max(confidence, .high)
        }

        // 5. Memory leak heuristic — independent of rules, always useful.
        if process.cpuPercent <= idleCPUThreshold,
           process.memoryMB >= leakRSSThresholdMB,
           process.state != .stopped {
            out.append(.memoryLeak(mb: Int(process.memoryMB)))
            confidence = max(confidence, .medium)
        }

        // 6. Activity vs. idleness — show at most one of these, and only if
        // no higher-priority kill signal already explains the row.
        if !out.contains(where: { isKillSignal($0) }) {
            if process.cpuPercent >= activeCPUThreshold {
                out.append(.active(percent: Int(process.cpuPercent)))
                // Active suggests *don't* kill — keep confidence low.
            } else if process.cpuPercent <= idleCPUThreshold,
                      process.state != .stopped,
                      let rt = process.runtime {
                let minutes = Int(rt) / 60
                if minutes >= 5 {
                    out.append(.idle(minutes: minutes))
                    confidence = max(confidence, .medium)
                }
            }
        }

        return ProcessSignals(badges: out, confidence: confidence)
    }

    /// Signals that explicitly argue for killing (not mere context).
    private static func isKillSignal(_ s: ProcessSignal) -> Bool {
        switch s {
        case .newlyOrphaned, .adoptedByLaunchd,
             .ruleHardKill, .catchAllExpired, .memoryLeak:
            return true
        case .ruleWarn, .active, .idle, .paused:
            return false
        }
    }
}
