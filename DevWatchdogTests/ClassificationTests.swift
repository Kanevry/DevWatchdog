import XCTest
@testable import DevWatchdog

/// Tests classification logic by simulating the stages from ProcessMonitor.scan()
/// without instantiating WatchdogConfig (which depends on UserDefaults).
final class ClassificationTests: XCTestCase {

    // MARK: - Helpers

    private func makeProcess(
        command: String = "/usr/local/bin/node vitest --forks",
        cpuPercent: Double = 80.0,
        startTime: Date = Date().addingTimeInterval(-3600),
        parentPID: Int32 = 1,
        isOrphan: Bool = true
    ) -> DevProcess {
        DevProcess(
            id: 12345,
            user: "testuser",
            cpuPercent: cpuPercent,
            memPercent: 5.0,
            rss: 102400,
            command: command,
            startTime: startTime,
            parentPID: parentPID,
            isOrphan: isOrphan
        )
    }

    private func makeRule(
        pattern: String = "vitest",
        cpuThreshold: Double = 50.0,
        runtimeThreshold: TimeInterval = 600,
        maxRuntime: TimeInterval = 1200,
        action: ProcessRule.RuleAction = .warn,
        isEnabled: Bool = true
    ) -> ProcessRule {
        ProcessRule(
            id: UUID(),
            pattern: pattern,
            cpuThreshold: cpuThreshold,
            runtimeThreshold: runtimeThreshold,
            maxRuntime: maxRuntime,
            action: action,
            isEnabled: isEnabled
        )
    }

    /// Simulates the classification stages from ProcessMonitor.scan().
    private enum Classification {
        case whitelisted
        case zombie
        case suspect
        case none
    }

    private func classify(
        process: DevProcess,
        rules: [ProcessRule],
        orphanTimeout: TimeInterval = 120,
        catchAllMaxRuntime: TimeInterval = 28800
    ) -> Classification {
        // Stage 1: Whitelist
        let isWhitelisted = rules.contains { rule in
            rule.isEnabled && rule.action == .whitelist && rule.matches(process)
        }
        if isWhitelisted { return .whitelisted }

        // Stage 2: Orphan + old enough -> zombie
        if process.isOrphan && (process.runtime ?? 0) >= orphanTimeout {
            return .zombie
        }

        // Stage 3: Rule-based
        if let rule = rules.first(where: { $0.isEnabled && $0.matches(process) }) {
            if rule.isMaxRuntimeExceeded(by: process) {
                return .zombie
            } else if rule.isTriggered(by: process) {
                return .suspect
            } else if rule.action == .warn {
                return .suspect
            }
            return .none
        }

        // Stage 4: General heuristic
        let runtime = process.runtime ?? 0
        if catchAllMaxRuntime > 0 && runtime >= catchAllMaxRuntime {
            return .zombie
        } else if process.cpuPercent > 50 || runtime > 600 {
            return .suspect
        }

        return .none
    }

    // MARK: - Stage 1: Whitelist

    func testWhitelistedProcessIsClassifiedCorrectly() {
        let rule = makeRule(pattern: "vitest", action: .whitelist)
        let process = makeProcess(command: "/usr/bin/node vitest --forks")

        let result = classify(process: process, rules: [rule])
        XCTAssertEqual(result, .whitelisted)
    }

    // MARK: - Stage 2: Orphan timeout

    func testOrphanExceedingTimeoutIsZombie() {
        let process = makeProcess(
            startTime: Date().addingTimeInterval(-300), // 5 min ago
            isOrphan: true
        )
        // orphanTimeout = 120s (2 min), runtime ~300s > 120s -> zombie
        let result = classify(process: process, rules: [], orphanTimeout: 120)
        XCTAssertEqual(result, .zombie)
    }

    // MARK: - Stage 3: Rule-based

    func testRuleMaxRuntimeExceededIsZombie() {
        let rule = makeRule(pattern: "vitest", maxRuntime: 1200)
        // Process running for 2 hours — well past 1200s (20min) max
        let process = makeProcess(
            startTime: Date().addingTimeInterval(-7200),
            isOrphan: false
        )

        let result = classify(process: process, rules: [rule])
        XCTAssertEqual(result, .zombie)
    }

    func testRuleWarnThresholdsExceededIsSuspect() {
        let rule = makeRule(
            pattern: "vitest",
            cpuThreshold: 50.0,
            runtimeThreshold: 600,
            maxRuntime: 99999 // won't be exceeded
        )
        let process = makeProcess(
            cpuPercent: 80.0,
            startTime: Date().addingTimeInterval(-3600),
            isOrphan: false
        )

        let result = classify(process: process, rules: [rule])
        XCTAssertEqual(result, .suspect)
    }

    // MARK: - Stage 4: Heuristic

    func testHighCPUNonOrphanIsSuspect() {
        // No matching rules, high CPU -> stage 4 heuristic -> suspect
        let process = makeProcess(
            command: "/usr/bin/some-unknown-tool",
            cpuPercent: 60.0,
            startTime: Date().addingTimeInterval(-60), // just 1 min, runtime < 600
            isOrphan: false
        )

        let result = classify(process: process, rules: [])
        XCTAssertEqual(result, .suspect)
    }

    func testOrphanBelowTimeoutIsNotZombie() {
        // Orphan running for 30s, orphanTimeout = 120s -> NOT zombie yet
        let process = makeProcess(
            command: "/usr/bin/some-unknown-tool",
            cpuPercent: 10.0,
            startTime: Date().addingTimeInterval(-30),
            isOrphan: true
        )

        let result = classify(process: process, rules: [], orphanTimeout: 120)
        // Runtime ~30s: not orphan-timeout zombie, no rule match,
        // cpuPercent 10 <= 50 and runtime 30 <= 600 -> none
        XCTAssertEqual(result, .none)
    }
}
