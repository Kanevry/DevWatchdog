import XCTest
@testable import DevWatchdog

@MainActor
final class InsightsEngineTests: XCTestCase {

    private func clearDismissals() {
        UserDefaults.standard.removeObject(forKey: "insightsDismissals")
    }

    override func setUp() async throws {
        // Note: do NOT call super.setUp() — Swift 6.0 strict concurrency treats
        // sending a @MainActor-isolated self into XCTestCase's nonisolated
        // setUp() as a data race. XCTestCase's base setUp() is a no-op, so
        // skipping is safe. Matches the pattern used in other @MainActor
        // test classes in this target.
        clearDismissals()
    }

    override func tearDown() async throws {
        // See setUp() — same rationale; super.tearDown() omitted intentionally.
        clearDismissals()
    }

    // MARK: - Empty log

    func testEmptyLogYieldsNoRecommendations() {
        let log = SessionLog(capacity: 100)
        let config = WatchdogConfig()
        let engine = InsightsEngine(log: log, config: config)
        engine.refresh()
        XCTAssertTrue(engine.recommendations.isEmpty)
        XCTAssertNotNil(engine.lastAnalyzedAt)
    }

    // MARK: - Gap detection

    func testGapDetectionFiresWhenNoKillsIn7Days() {
        let log = SessionLog(capacity: 100)
        // Insert a non-kill entry so the log is not empty (gap-detection skips empty logs)
        log.log(.emergencyEntered, "pressure up")
        let config = WatchdogConfig()
        let engine = InsightsEngine(log: log, config: config)
        engine.refresh()
        let gaps = engine.recommendations.filter { $0.category == .gapDetection }
        XCTAssertEqual(gaps.count, 1, "expected a gap-detection recommendation when no kills in log")
    }

    func testGapDetectionDoesNotFireWhenKillExistsRecently() {
        let log = SessionLog(capacity: 100)
        let reason = KillReason(
            ruleID: nil,
            rulePattern: nil,
            trigger: .catchAllMaxRuntime,
            thresholdValue: 7200,
            actualValue: 7500,
            unit: "s"
        )
        log.log(.kill, "a kill", pid: 1, processName: "node", killReason: reason)
        let config = WatchdogConfig()
        let engine = InsightsEngine(log: log, config: config)
        engine.refresh()
        let gaps = engine.recommendations.filter { $0.category == .gapDetection }
        XCTAssertTrue(gaps.isEmpty, "gap-detection must not fire when there is a recent kill")
    }

    func testGapDetectionDoesNotFireOnEmptyLog() {
        let log = SessionLog(capacity: 100)
        let config = WatchdogConfig()
        let engine = InsightsEngine(log: log, config: config)
        engine.refresh()
        let gaps = engine.recommendations.filter { $0.category == .gapDetection }
        XCTAssertTrue(gaps.isEmpty, "gap-detection must not fire when log is completely empty")
    }

    // MARK: - Missing coverage

    func testMissingCoverageFiresAfter5CatchAllKills() {
        let log = SessionLog(capacity: 100)
        let config = WatchdogConfig()
        let reason = KillReason(
            ruleID: nil,
            rulePattern: nil,
            trigger: .catchAllMaxRuntime,
            thresholdValue: 7200,
            actualValue: 7500,
            unit: "s"
        )
        for _ in 0..<5 {
            log.log(.kill, "catch-all kill", pid: 1000, processName: "rspack", killReason: reason)
        }
        let engine = InsightsEngine(log: log, config: config)
        engine.refresh()
        let missing = engine.recommendations.filter { $0.category == .missingCoverage }
        XCTAssertGreaterThanOrEqual(missing.count, 1, "expected missing-coverage recommendation after 5 catch-all kills")
        XCTAssertTrue(missing.contains { $0.message.contains("rspack") })
    }

    func testMissingCoverageBelow5KillsDoesNotFire() {
        let log = SessionLog(capacity: 100)
        let config = WatchdogConfig()
        let reason = KillReason(
            ruleID: nil,
            rulePattern: nil,
            trigger: .catchAllMaxRuntime,
            thresholdValue: 7200,
            actualValue: 7500,
            unit: "s"
        )
        for _ in 0..<4 {
            log.log(.kill, "catch-all", pid: 1000, processName: "rspack", killReason: reason)
        }
        let engine = InsightsEngine(log: log, config: config)
        engine.refresh()
        let missing = engine.recommendations.filter { $0.category == .missingCoverage }
        XCTAssertTrue(missing.isEmpty, "missing-coverage should not fire with only 4 kills")
    }

    func testMissingCoverageOnlyCountsCatchAllTrigger() {
        let log = SessionLog(capacity: 100)
        let config = WatchdogConfig()
        // 5 kills with a specific rule trigger — NOT catch-all
        let ruleID = UUID()
        let reason = KillReason(
            ruleID: ruleID,
            rulePattern: "rspack",
            trigger: .maxRuntime,
            thresholdValue: 7200,
            actualValue: 7500,
            unit: "s"
        )
        for _ in 0..<5 {
            log.log(.kill, "rule kill", pid: 1000, processName: "rspack", killReason: reason)
        }
        let engine = InsightsEngine(log: log, config: config)
        engine.refresh()
        let missing = engine.recommendations.filter { $0.category == .missingCoverage }
        XCTAssertTrue(missing.isEmpty, "missing-coverage must only count catch-all kills, not rule kills")
    }

    // MARK: - Pressure pattern

    func testPressurePatternFiresWhen3EmergencyEntriesIn24h() {
        let log = SessionLog(capacity: 100)
        let config = WatchdogConfig()
        config.softKillPreferred = false
        for _ in 0..<3 {
            log.log(.emergencyEntered, "pressure spike")
        }
        let engine = InsightsEngine(log: log, config: config)
        engine.refresh()
        let pressure = engine.recommendations.filter { $0.category == .pressurePattern }
        XCTAssertGreaterThanOrEqual(pressure.count, 1)
    }

    func testPressurePatternSuppressedWhenSoftKillAlreadyOn() {
        let log = SessionLog(capacity: 100)
        let config = WatchdogConfig()
        config.softKillPreferred = true
        for _ in 0..<3 {
            log.log(.emergencyEntered, "spike")
        }
        let engine = InsightsEngine(log: log, config: config)
        engine.refresh()
        let pressure = engine.recommendations.filter { $0.category == .pressurePattern }
        XCTAssertTrue(pressure.isEmpty, "should not recommend soft-kill when already on")
    }

    func testPressurePatternDoesNotFireWith2Entries() {
        let log = SessionLog(capacity: 100)
        let config = WatchdogConfig()
        config.softKillPreferred = false
        for _ in 0..<2 {
            log.log(.emergencyEntered, "spike")
        }
        let engine = InsightsEngine(log: log, config: config)
        engine.refresh()
        let pressure = engine.recommendations.filter { $0.category == .pressurePattern }
        XCTAssertTrue(pressure.isEmpty, "pressure-pattern must not fire with only 2 emergency entries")
    }

    // MARK: - Dismiss

    func testDismissHidesRecommendation() {
        let log = SessionLog(capacity: 100)
        log.log(.emergencyEntered, "x")
        let config = WatchdogConfig()
        config.softKillPreferred = false
        let engine = InsightsEngine(log: log, config: config)
        engine.refresh()
        guard let first = engine.recommendations.first else {
            return XCTFail("expected at least one recommendation")
        }
        engine.dismiss(first)
        // After dismiss, refresh is called internally — recommendation must be gone
        XCTAssertFalse(engine.recommendations.contains(where: { $0.id == first.id }))
    }

    func testDismissPersistsToUserDefaults() {
        let log = SessionLog(capacity: 100)
        log.log(.emergencyEntered, "x")
        let config = WatchdogConfig()
        config.softKillPreferred = false
        let engine = InsightsEngine(log: log, config: config)
        engine.refresh()
        guard let first = engine.recommendations.first else {
            return XCTFail("no recommendation")
        }
        engine.dismiss(first)
        let data = UserDefaults.standard.data(forKey: "insightsDismissals")
        XCTAssertNotNil(data)
    }

    func testDismissedRecommendationExcludedOnSubsequentRefresh() {
        let log = SessionLog(capacity: 100)
        log.log(.emergencyEntered, "y")
        let config = WatchdogConfig()
        config.softKillPreferred = false
        let engine = InsightsEngine(log: log, config: config)
        engine.refresh()
        guard let first = engine.recommendations.first else {
            return XCTFail("need a recommendation to dismiss")
        }
        let dismissedID = first.id
        engine.dismiss(first)
        // Create a fresh engine that loads persisted dismissals
        let engine2 = InsightsEngine(log: log, config: config)
        engine2.refresh()
        XCTAssertFalse(engine2.recommendations.contains(where: { $0.id == dismissedID }),
                       "dismissed recommendation must stay hidden across engine instances within 7-day window")
    }

    // MARK: - Threshold tuning

    func testThresholdTuningFiresWhenRuleKillsFrequentlyAtLowActual() {
        let log = SessionLog(capacity: 100)
        let config = WatchdogConfig()
        let rule = ProcessRule(
            id: UUID(),
            pattern: "vitest",
            cpuThreshold: 50,
            runtimeThreshold: 1800,
            maxRuntime: 1800,
            action: .warn,
            isEnabled: true
        )
        config.rules = [rule]

        let reason = KillReason(
            ruleID: rule.id,
            rulePattern: rule.pattern,
            trigger: .maxRuntime,
            thresholdValue: 1800,
            actualValue: 1820,  // barely above threshold (< threshold * 1.1)
            unit: "s"
        )
        for _ in 0..<4 {
            log.log(.kill, "kill vitest", pid: 42, processName: "vitest", killReason: reason)
        }
        let engine = InsightsEngine(log: log, config: config)
        engine.refresh()
        let tuning = engine.recommendations.filter { $0.category == .thresholdTuning }
        XCTAssertGreaterThanOrEqual(tuning.count, 1)
    }

    func testThresholdTuningDoesNotFireWhenActualFarAboveThreshold() {
        let log = SessionLog(capacity: 100)
        let config = WatchdogConfig()
        let rule = ProcessRule(
            id: UUID(),
            pattern: "vitest",
            cpuThreshold: 50,
            runtimeThreshold: 1800,
            maxRuntime: 1800,
            action: .warn,
            isEnabled: true
        )
        config.rules = [rule]

        // actualValue is 1.5× the threshold — well above the 1.1× proximity check
        let reason = KillReason(
            ruleID: rule.id,
            rulePattern: rule.pattern,
            trigger: .maxRuntime,
            thresholdValue: 1800,
            actualValue: 2700,
            unit: "s"
        )
        for _ in 0..<4 {
            log.log(.kill, "kill vitest", pid: 42, processName: "vitest", killReason: reason)
        }
        let engine = InsightsEngine(log: log, config: config)
        engine.refresh()
        let tuning = engine.recommendations.filter { $0.category == .thresholdTuning }
        XCTAssertTrue(tuning.isEmpty, "threshold-tuning must not fire when actual is far above threshold")
    }

    func testThresholdTuningDoesNotFireWith3KillsOnly() {
        let log = SessionLog(capacity: 100)
        let config = WatchdogConfig()
        let rule = ProcessRule(
            id: UUID(),
            pattern: "vitest",
            cpuThreshold: 50,
            runtimeThreshold: 1800,
            maxRuntime: 1800,
            action: .warn,
            isEnabled: true
        )
        config.rules = [rule]

        let reason = KillReason(
            ruleID: rule.id,
            rulePattern: rule.pattern,
            trigger: .maxRuntime,
            thresholdValue: 1800,
            actualValue: 1820,
            unit: "s"
        )
        for _ in 0..<3 {
            log.log(.kill, "kill vitest", pid: 42, processName: "vitest", killReason: reason)
        }
        let engine = InsightsEngine(log: log, config: config)
        engine.refresh()
        let tuning = engine.recommendations.filter { $0.category == .thresholdTuning }
        XCTAssertTrue(tuning.isEmpty, "threshold-tuning requires at least 4 kills")
    }

    // MARK: - lastAnalyzedAt

    func testLastAnalyzedAtIsSetAfterRefresh() {
        let log = SessionLog(capacity: 100)
        let config = WatchdogConfig()
        let engine = InsightsEngine(log: log, config: config)
        XCTAssertNil(engine.lastAnalyzedAt, "lastAnalyzedAt must be nil before first refresh")
        engine.refresh()
        XCTAssertNotNil(engine.lastAnalyzedAt)
    }

    func testLastAnalyzedAtUpdatesOnEachRefresh() {
        let log = SessionLog(capacity: 100)
        let config = WatchdogConfig()
        let engine = InsightsEngine(log: log, config: config)
        engine.refresh()
        let first = engine.lastAnalyzedAt
        engine.refresh()
        let second = engine.lastAnalyzedAt
        // Both must be non-nil; second must be >= first
        let firstDate = try? XCTUnwrap(first)
        let secondDate = try? XCTUnwrap(second)
        if let f = firstDate, let s = secondDate {
            XCTAssertGreaterThanOrEqual(s, f)
        }
    }
}
