import XCTest
@testable import DevWatchdog

final class ProcessRuleTests: XCTestCase {

    // MARK: - Helpers

    private func makeProcess(
        command: String = "/usr/local/bin/node vitest --forks",
        cpuPercent: Double = 80.0,
        startTime: Date = Date().addingTimeInterval(-3600),
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
            parentPID: isOrphan ? 1 : 500,
            isOrphan: isOrphan
        )
    }

    private func makeRule(
        pattern: String = "vitest",
        cpuThreshold: Double = 50.0,
        runtimeThreshold: TimeInterval = 600,
        maxRuntime: TimeInterval = 1200,
        action: ProcessRule.RuleAction = .warn,
        isEnabled: Bool = true,
        matchMode: ProcessRule.MatchMode = .substring
    ) -> ProcessRule {
        ProcessRule(
            id: UUID(),
            pattern: pattern,
            cpuThreshold: cpuThreshold,
            runtimeThreshold: runtimeThreshold,
            maxRuntime: maxRuntime,
            action: action,
            isEnabled: isEnabled,
            matchMode: matchMode
        )
    }

    // MARK: - matches()

    func testMatchesSimplePattern() {
        let rule = makeRule(pattern: "vitest")
        let process = makeProcess(command: "/usr/local/bin/node vitest --forks")
        XCTAssertTrue(rule.matches(process))
    }

    func testMatchesGlobPattern() {
        let rule = makeRule(pattern: "vitest.*forks")
        let process = makeProcess(command: "/usr/local/bin/node vitest --forks")
        XCTAssertTrue(rule.matches(process))
    }

    func testMatchesCaseInsensitive() {
        let rule = makeRule(pattern: "VITEST")
        let process = makeProcess(command: "/usr/local/bin/node vitest --forks")
        XCTAssertTrue(rule.matches(process))
    }

    func testMatchesReturnsFalseWhenDisabled() {
        let rule = makeRule(pattern: "vitest", isEnabled: false)
        let process = makeProcess(command: "/usr/local/bin/node vitest --forks")
        XCTAssertFalse(rule.matches(process))
    }

    func testMatchesReturnsFalseForNonMatchingPattern() {
        let rule = makeRule(pattern: "jest")
        let process = makeProcess(command: "/usr/local/bin/node vitest --forks")
        XCTAssertFalse(rule.matches(process))
    }

    // MARK: - isTriggered()

    func testIsTriggeredRequiresBothThresholds() {
        // CPU = 80 (above 50 threshold), runtime = 3600s (above 600 threshold)
        let rule = makeRule(cpuThreshold: 50.0, runtimeThreshold: 600)
        let process = makeProcess(cpuPercent: 80.0, startTime: Date().addingTimeInterval(-3600))
        XCTAssertTrue(rule.isTriggered(by: process))
    }

    func testIsTriggeredReturnsFalseWhenCPUBelowThreshold() {
        let rule = makeRule(cpuThreshold: 90.0, runtimeThreshold: 600)
        let process = makeProcess(cpuPercent: 80.0, startTime: Date().addingTimeInterval(-3600))
        XCTAssertFalse(rule.isTriggered(by: process))
    }

    func testIsTriggeredReturnsFalseWhenRuntimeBelowThreshold() {
        let rule = makeRule(cpuThreshold: 50.0, runtimeThreshold: 7200)
        let process = makeProcess(cpuPercent: 80.0, startTime: Date().addingTimeInterval(-3600))
        XCTAssertFalse(rule.isTriggered(by: process))
    }

    func testIsTriggeredReturnsFalseForNonWarnAction() {
        let rule = makeRule(action: .whitelist)
        let process = makeProcess()
        XCTAssertFalse(rule.isTriggered(by: process))
    }

    // MARK: - isMaxRuntimeExceeded()

    func testIsMaxRuntimeExceededWithZeroReturnsFFalse() {
        let rule = makeRule(maxRuntime: 0)
        let process = makeProcess(startTime: Date().addingTimeInterval(-999999))
        XCTAssertFalse(rule.isMaxRuntimeExceeded(by: process))
    }

    func testIsMaxRuntimeExceededReturnsTrueWhenExceeded() {
        let rule = makeRule(maxRuntime: 1200) // 20min limit
        // Process running for 1 hour (3600s) — well past 1200s limit
        let process = makeProcess(startTime: Date().addingTimeInterval(-3600))
        XCTAssertTrue(rule.isMaxRuntimeExceeded(by: process))
    }

    func testIsMaxRuntimeExceededReturnsFalseWhenNotExceeded() {
        let rule = makeRule(maxRuntime: 7200) // 2h limit
        // Process running for 1 hour (3600s) — under limit
        let process = makeProcess(startTime: Date().addingTimeInterval(-3600))
        XCTAssertFalse(rule.isMaxRuntimeExceeded(by: process))
    }

    // MARK: - Default rules for new tools

    func testDefaultRulesContainBun() {
        let bunRule = ProcessRule.defaultRules.first { $0.pattern == "bun" }
        XCTAssertNotNil(bunRule, "defaultRules should contain a 'bun' rule")
        XCTAssertEqual(bunRule?.runtimeThreshold, 600)
        XCTAssertEqual(bunRule?.maxRuntime, 1200)
    }

    func testDefaultRulesContainDeno() {
        let denoRule = ProcessRule.defaultRules.first { $0.pattern == "deno" }
        XCTAssertNotNil(denoRule, "defaultRules should contain a 'deno' rule")
        XCTAssertEqual(denoRule?.runtimeThreshold, 600)
        XCTAssertEqual(denoRule?.maxRuntime, 1200)
    }

    func testDefaultRulesContainSwc() {
        let swcRule = ProcessRule.defaultRules.first { $0.pattern == "swc" }
        XCTAssertNotNil(swcRule, "defaultRules should contain a 'swc' rule")
        XCTAssertEqual(swcRule?.runtimeThreshold, 600)
        XCTAssertEqual(swcRule?.maxRuntime, 1200)
    }

    // MARK: - Matching behavior for new tools

    func testBunRuleMatchesBunCommand() {
        let rule = makeRule(pattern: "bun")
        let process = makeProcess(command: "/usr/local/bin/bun run dev")
        XCTAssertTrue(rule.matches(process))
    }

    func testDenoRuleMatchesDenoCommand() {
        let rule = makeRule(pattern: "deno")
        let process = makeProcess(command: "/home/user/.deno/bin/deno run server.ts")
        XCTAssertTrue(rule.matches(process))
    }

    func testSwcRuleMatchesSwcCommand() {
        let rule = makeRule(pattern: "swc")
        let process = makeProcess(command: "/usr/local/bin/swc compile src/")
        XCTAssertTrue(rule.matches(process))
    }

    // MARK: - Case sensitivity edge cases

    func testMatchesIsCaseInsensitiveForNewTools() {
        let bunRule = makeRule(pattern: "BUN")
        let process = makeProcess(command: "/usr/local/bin/bun run dev")
        XCTAssertTrue(bunRule.matches(process), "Rule matching should be case-insensitive")
    }

    // MARK: - MatchMode: substring (default, existing behavior)

    func testSubstringModeMatchesSubstring() throws {
        let rule = makeRule(pattern: "node", matchMode: .substring)
        XCTAssertTrue(rule.matches(makeProcess(command: "/usr/local/bin/node script.js")))
        XCTAssertTrue(rule.matches(makeProcess(command: "/usr/local/bin/node-exporter")))
        // substring matches both — that's the expected "loose" behavior
    }

    // MARK: - MatchMode: glob (anchored)

    func testGlobModeAnchoredExactly() throws {
        let exactRule = makeRule(pattern: "node", matchMode: .glob)
        XCTAssertFalse(exactRule.matches(makeProcess(command: "/usr/local/bin/node")))  // no wildcards → exact lowercase match
        XCTAssertTrue(exactRule.matches(makeProcess(command: "node")))
    }

    func testGlobModeWildcards() throws {
        let rule = makeRule(pattern: "*vitest*forks*", matchMode: .glob)
        XCTAssertTrue(rule.matches(makeProcess(command: "/usr/bin/node /path/vitest --forks --worker")))
        XCTAssertFalse(rule.matches(makeProcess(command: "vitest")))  // needs 'forks'
    }

    func testGlobModeDoesNotMatchSubstringBoundary() throws {
        // "node" in glob mode must NOT match "node-exporter"
        let rule = makeRule(pattern: "node*", matchMode: .glob)
        XCTAssertTrue(rule.matches(makeProcess(command: "node-exporter")))
        XCTAssertTrue(rule.matches(makeProcess(command: "node")))

        let strict = makeRule(pattern: "node", matchMode: .glob)
        XCTAssertFalse(strict.matches(makeProcess(command: "node-exporter")))
    }

    func testGlobModeEscapesRegexMeta() throws {
        // pattern "foo.bar" in glob should only match literal "foo.bar", not "fooxbar"
        let rule = makeRule(pattern: "foo.bar", matchMode: .glob)
        XCTAssertTrue(rule.matches(makeProcess(command: "foo.bar")))
        XCTAssertFalse(rule.matches(makeProcess(command: "fooxbar")))
    }

    // MARK: - MatchMode: regex

    func testRegexModeWithAnchors() throws {
        let rule = makeRule(pattern: "^node$", matchMode: .regex)
        XCTAssertTrue(rule.matches(makeProcess(command: "node")))
        XCTAssertFalse(rule.matches(makeProcess(command: "node-exporter")))
    }

    func testRegexModeUnanchored() throws {
        let rule = makeRule(pattern: "(vitest|jest)", matchMode: .regex)
        XCTAssertTrue(rule.matches(makeProcess(command: "/path/to/vitest --forks")))
        XCTAssertTrue(rule.matches(makeProcess(command: "/path/to/jest --worker")))
        XCTAssertFalse(rule.matches(makeProcess(command: "/path/to/mocha")))
    }

    func testRegexModeInvalidPatternReturnsFalse() throws {
        let rule = makeRule(pattern: "[unclosed", matchMode: .regex)
        XCTAssertFalse(rule.matches(makeProcess(command: "anything")))
    }

    func testDisabledRuleDoesNotMatchInAnyMode() throws {
        for mode in ProcessRule.MatchMode.allCases {
            let rule = makeRule(pattern: ".*", isEnabled: false, matchMode: mode)
            XCTAssertFalse(rule.matches(makeProcess(command: "anything")))
        }
    }

    func testEmptyPatternDoesNotMatch() throws {
        for mode in ProcessRule.MatchMode.allCases {
            let rule = makeRule(pattern: "", matchMode: mode)
            XCTAssertFalse(rule.matches(makeProcess(command: "anything")))
        }
    }
}
