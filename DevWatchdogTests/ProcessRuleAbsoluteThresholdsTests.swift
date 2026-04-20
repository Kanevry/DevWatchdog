import XCTest
@testable import DevWatchdog

/// Tests for absolute CPU% and RSS thresholds added in Wave 2 (issue #5).
///
/// Covers `isMaxCPUExceeded`, `isMaxRSSExceeded`, `shouldHardKill` with both
/// `.any` and `.all` modes, Codable migration from legacy JSON, and the updated
/// default rules.
final class ProcessRuleAbsoluteThresholdsTests: XCTestCase {

    // MARK: - Helpers

    /// Create a DevProcess with the most common axes we care about.
    /// - Parameter rssMB: Resident set size expressed in MB (stored in the underlying `rss` field in KB).
    /// - Parameter runtime: Seconds the process has been running (nil for no start time).
    private func makeProcess(
        pid: Int32 = 42000,
        command: String = "/usr/local/bin/node tsgo typecheck",
        cpu: Double = 0,
        rssMB: Double = 0,
        runtime: TimeInterval? = 0,
        isOrphan: Bool = true
    ) -> DevProcess {
        let startTime: Date? = runtime.map { Date().addingTimeInterval(-$0) }
        return DevProcess(
            id: pid,
            user: "testuser",
            cpuPercent: cpu,
            memPercent: 0,
            rss: Int(rssMB * 1024.0), // rss is KB; memoryMB = rss/1024
            command: command,
            startTime: startTime,
            parentPID: isOrphan ? 1 : 500,
            isOrphan: isOrphan
        )
    }

    private func makeRule(
        pattern: String = "tsgo",
        cpuThreshold: Double = 0,
        runtimeThreshold: TimeInterval = 0,
        maxRuntime: TimeInterval = 0,
        maxCPUPercent: Double = 0,
        maxRSSMB: Double = 0,
        thresholdMode: ProcessRule.ThresholdMode = .any,
        action: ProcessRule.RuleAction = .warn,
        isEnabled: Bool = true,
        onlyWhenOrphan: Bool = false
    ) -> ProcessRule {
        ProcessRule(
            id: UUID(),
            pattern: pattern,
            cpuThreshold: cpuThreshold,
            runtimeThreshold: runtimeThreshold,
            maxRuntime: maxRuntime,
            maxCPUPercent: maxCPUPercent,
            maxRSSMB: maxRSSMB,
            thresholdMode: thresholdMode,
            action: action,
            isEnabled: isEnabled,
            onlyWhenOrphan: onlyWhenOrphan
        )
    }

    // MARK: - isMaxCPUExceeded

    func testIsMaxCPUExceededDisabledWhenZero() {
        let rule = makeRule(maxCPUPercent: 0)
        let proc = makeProcess(cpu: 999)
        XCTAssertFalse(rule.isMaxCPUExceeded(by: proc))
    }

    func testIsMaxCPUExceededBoundary() {
        let rule = makeRule(maxCPUPercent: 300)
        XCTAssertFalse(rule.isMaxCPUExceeded(by: makeProcess(cpu: 299.9)))
        XCTAssertTrue(rule.isMaxCPUExceeded(by: makeProcess(cpu: 300.0)))
        XCTAssertTrue(rule.isMaxCPUExceeded(by: makeProcess(cpu: 447.0)))
    }

    func testIsMaxCPUExceededRespectsMatches() {
        let rule = makeRule(pattern: "jest", maxCPUPercent: 100)
        let proc = makeProcess(command: "/usr/local/bin/node tsgo", cpu: 500)
        XCTAssertFalse(rule.isMaxCPUExceeded(by: proc))
    }

    func testIsMaxCPUExceededRespectsOnlyWhenOrphan() {
        let rule = makeRule(maxCPUPercent: 300, onlyWhenOrphan: true)
        let nonOrphan = makeProcess(cpu: 500, isOrphan: false)
        XCTAssertFalse(rule.isMaxCPUExceeded(by: nonOrphan))

        let orphan = makeProcess(cpu: 500, isOrphan: true)
        XCTAssertTrue(rule.isMaxCPUExceeded(by: orphan))
    }

    // MARK: - isMaxRSSExceeded

    func testIsMaxRSSExceededDisabledWhenZero() {
        let rule = makeRule(maxRSSMB: 0)
        let proc = makeProcess(rssMB: 99_999)
        XCTAssertFalse(rule.isMaxRSSExceeded(by: proc))
    }

    func testIsMaxRSSExceededBoundary() {
        let rule = makeRule(maxRSSMB: 1500)
        XCTAssertFalse(rule.isMaxRSSExceeded(by: makeProcess(rssMB: 1499.5)))
        XCTAssertTrue(rule.isMaxRSSExceeded(by: makeProcess(rssMB: 1500)))
        XCTAssertTrue(rule.isMaxRSSExceeded(by: makeProcess(rssMB: 2400)))
    }

    func testIsMaxRSSExceededRespectsMatches() {
        let rule = makeRule(pattern: "jest", maxRSSMB: 1000)
        let proc = makeProcess(command: "/usr/local/bin/node tsgo", rssMB: 5000)
        XCTAssertFalse(rule.isMaxRSSExceeded(by: proc))
    }

    // MARK: - shouldHardKill — .any mode

    func testShouldHardKillAnyFiresOnRuntime() {
        let rule = makeRule(maxRuntime: 300, maxCPUPercent: 300, maxRSSMB: 1500, thresholdMode: .any)
        let proc = makeProcess(cpu: 10, rssMB: 100, runtime: 400)
        XCTAssertTrue(rule.shouldHardKill(proc))
    }

    func testShouldHardKillAnyFiresOnCPU() {
        let rule = makeRule(maxRuntime: 300, maxCPUPercent: 300, maxRSSMB: 1500, thresholdMode: .any)
        let proc = makeProcess(cpu: 447, rssMB: 100, runtime: 30)
        XCTAssertTrue(rule.shouldHardKill(proc))
    }

    func testShouldHardKillAnyFiresOnRSS() {
        let rule = makeRule(maxRuntime: 300, maxCPUPercent: 300, maxRSSMB: 1500, thresholdMode: .any)
        let proc = makeProcess(cpu: 10, rssMB: 1600, runtime: 30)
        XCTAssertTrue(rule.shouldHardKill(proc))
    }

    func testShouldHardKillAnyFalseWhenAllUnderLimits() {
        let rule = makeRule(maxRuntime: 300, maxCPUPercent: 300, maxRSSMB: 1500, thresholdMode: .any)
        let proc = makeProcess(cpu: 10, rssMB: 100, runtime: 30)
        XCTAssertFalse(rule.shouldHardKill(proc))
    }

    // MARK: - shouldHardKill — .all mode

    func testShouldHardKillAllRequiresEveryConfiguredThreshold() {
        let rule = makeRule(maxRuntime: 300, maxCPUPercent: 300, maxRSSMB: 1500, thresholdMode: .all)

        // Only RSS exceeded — not enough.
        XCTAssertFalse(rule.shouldHardKill(makeProcess(cpu: 10, rssMB: 1600, runtime: 30)))
        // Only CPU and RSS exceeded — runtime still below.
        XCTAssertFalse(rule.shouldHardKill(makeProcess(cpu: 400, rssMB: 1600, runtime: 30)))
        // All three exceeded.
        XCTAssertTrue(rule.shouldHardKill(makeProcess(cpu: 400, rssMB: 1600, runtime: 400)))
    }

    func testShouldHardKillAllIgnoresDisabledThresholds() {
        // Only CPU + RSS configured — runtime disabled (0). Both configured must exceed.
        let rule = makeRule(maxRuntime: 0, maxCPUPercent: 300, maxRSSMB: 1500, thresholdMode: .all)

        // CPU exceeded only.
        XCTAssertFalse(rule.shouldHardKill(makeProcess(cpu: 400, rssMB: 100, runtime: 999_999)))
        // Both CPU and RSS exceeded — runtime is disabled and ignored.
        XCTAssertTrue(rule.shouldHardKill(makeProcess(cpu: 400, rssMB: 1600, runtime: 0)))
    }

    func testShouldHardKillFalseWhenNoThresholdsConfigured() {
        let ruleAny = makeRule(maxRuntime: 0, maxCPUPercent: 0, maxRSSMB: 0, thresholdMode: .any)
        let ruleAll = makeRule(maxRuntime: 0, maxCPUPercent: 0, maxRSSMB: 0, thresholdMode: .all)
        let proc = makeProcess(cpu: 9999, rssMB: 9999, runtime: 9999)
        XCTAssertFalse(ruleAny.shouldHardKill(proc))
        XCTAssertFalse(ruleAll.shouldHardKill(proc))
    }

    func testShouldHardKillRespectsMatches() {
        let rule = makeRule(pattern: "jest", maxRuntime: 300, maxCPUPercent: 300, maxRSSMB: 1500)
        let proc = makeProcess(command: "/usr/local/bin/node tsgo", cpu: 999, rssMB: 9999, runtime: 9999)
        XCTAssertFalse(rule.shouldHardKill(proc))
    }

    func testShouldHardKillRespectsOnlyWhenOrphan() {
        let rule = makeRule(maxCPUPercent: 300, onlyWhenOrphan: true)
        let nonOrphan = makeProcess(cpu: 500, isOrphan: false)
        XCTAssertFalse(rule.shouldHardKill(nonOrphan))
    }

    // MARK: - Codable

    func testCodableRoundtripPreservesNewFields() throws {
        let rule = makeRule(
            pattern: "tsgo",
            cpuThreshold: 50,
            runtimeThreshold: 120,
            maxRuntime: 300,
            maxCPUPercent: 300,
            maxRSSMB: 1500,
            thresholdMode: .all
        )
        let encoded = try JSONEncoder().encode(rule)
        let decoded = try JSONDecoder().decode(ProcessRule.self, from: encoded)
        XCTAssertEqual(decoded.maxCPUPercent, 300)
        XCTAssertEqual(decoded.maxRSSMB, 1500)
        XCTAssertEqual(decoded.thresholdMode, .all)
        XCTAssertEqual(decoded.pattern, "tsgo")
        XCTAssertEqual(decoded.maxRuntime, 300)
    }

    func testCodableDecodesLegacyJSONWithDefaults() throws {
        // Legacy payload (pre-Wave-2): no maxCPUPercent, no maxRSSMB, no thresholdMode.
        let legacy = """
        {
            "id": "11111111-2222-3333-4444-555555555555",
            "pattern": "tsgo",
            "cpuThreshold": 50,
            "runtimeThreshold": 120,
            "maxRuntime": 300,
            "action": "warn",
            "isEnabled": true
        }
        """
        let data = Data(legacy.utf8)
        let decoded = try JSONDecoder().decode(ProcessRule.self, from: data)
        XCTAssertEqual(decoded.pattern, "tsgo")
        XCTAssertEqual(decoded.maxCPUPercent, 0, "Legacy rule should default maxCPUPercent to 0")
        XCTAssertEqual(decoded.maxRSSMB, 0, "Legacy rule should default maxRSSMB to 0")
        XCTAssertEqual(decoded.thresholdMode, .any, "Legacy rule should default thresholdMode to .any")
        XCTAssertFalse(decoded.onlyWhenOrphan)
    }

    // MARK: - Default rules

    func testTsgoDefaultHasAbsoluteThresholds() {
        guard let tsgo = ProcessRule.defaultRules.first(where: { $0.pattern == "tsgo" }) else {
            return XCTFail("Expected 'tsgo' default rule")
        }
        XCTAssertEqual(tsgo.maxCPUPercent, 300)
        XCTAssertEqual(tsgo.maxRSSMB, 1500)
        XCTAssertEqual(tsgo.thresholdMode, .any)
    }

    func testTsgoRuleHardKillsOnRSSBelowRuntimeWindow() {
        // The today incident: tsgo @ 2.4 GB RSS / 447 % CPU at 30 s runtime must be kicked instantly.
        guard let tsgo = ProcessRule.defaultRules.first(where: { $0.pattern == "tsgo" }) else {
            return XCTFail("Expected 'tsgo' default rule")
        }
        let incident = makeProcess(
            command: "/usr/local/bin/node tsgo typecheck",
            cpu: 447,
            rssMB: 2400,
            runtime: 30
        )
        XCTAssertTrue(tsgo.shouldHardKill(incident),
                      "tsgo should hard-kill on CPU/RSS even when runtime is tiny")
    }

    func testVitestDefaultsHaveRSSThreshold() {
        for pattern in ["vitest", "vitest.*forks", "vitest.*worker", "vitest.*child"] {
            guard let rule = ProcessRule.defaultRules.first(where: { $0.pattern == pattern }) else {
                XCTFail("Expected default rule for '\(pattern)'")
                continue
            }
            XCTAssertEqual(rule.maxRSSMB, 2000, "vitest-family rule '\(pattern)' should have maxRSSMB=2000")
            XCTAssertEqual(rule.maxCPUPercent, 0, "vitest-family rule '\(pattern)' should not set maxCPUPercent")
        }
    }

    func testEsbuildDefaultHasCPUAndRSSThresholds() {
        guard let esbuild = ProcessRule.defaultRules.first(where: { $0.pattern == "esbuild" }) else {
            return XCTFail("Expected 'esbuild' default rule")
        }
        XCTAssertEqual(esbuild.maxCPUPercent, 400)
        XCTAssertEqual(esbuild.maxRSSMB, 1500)
    }

    func testMCPDefaultHasRSSThreshold() {
        guard let mcp = ProcessRule.defaultRules.first(where: { $0.pattern == "mcp" }) else {
            return XCTFail("Expected 'mcp' default rule")
        }
        XCTAssertEqual(mcp.maxRSSMB, 1000)
        XCTAssertTrue(mcp.onlyWhenOrphan, "MCP rule must keep onlyWhenOrphan semantics")
    }

    func testUnrelatedDefaultsHaveNoAbsoluteThresholds() {
        // Rules without absolute limits should stay at 0 — playwright family, percy, dev servers, pnpm, npm.
        for pattern in ["playwright", "percy", "next.*dev", "react-email", "pnpm", "npm run"] {
            guard let rule = ProcessRule.defaultRules.first(where: { $0.pattern == pattern }) else {
                XCTFail("Expected default rule for '\(pattern)'")
                continue
            }
            XCTAssertEqual(rule.maxCPUPercent, 0, "'\(pattern)' should not have maxCPUPercent set")
            XCTAssertEqual(rule.maxRSSMB, 0, "'\(pattern)' should not have maxRSSMB set")
        }
    }
}
