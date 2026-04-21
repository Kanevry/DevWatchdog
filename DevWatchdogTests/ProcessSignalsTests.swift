import XCTest
@testable import DevWatchdog

/// Unit tests for ``ProcessSignalsAnalyzer`` — the classifier that turns raw
/// ``DevProcess`` measurements into user-facing "why?" badges + a
/// ``KillConfidence`` rating.
///
/// Design goal: the analyzer is pure (no actor isolation, no I/O), so tests
/// can supply fixtures directly without driving the scan pipeline.
final class ProcessSignalsTests: XCTestCase {

    // MARK: - Orphan signals

    func testNewlyOrphanedProducesHighConfidence() {
        let p = makeProcess(ppid: 1, orphanConfidence: .reparented, runtime: 300, cpu: 5)
        let s = ProcessSignalsAnalyzer.analyze(p)
        XCTAssertTrue(s.badges.contains(.newlyOrphaned))
        XCTAssertEqual(s.confidence, .high)
    }

    func testLongAdoptedOrphanProducesMediumConfidence() {
        // PPID==1 since first seen — launchd daemon. Long runtime → badge.
        let p = makeProcess(ppid: 1, orphanConfidence: .knownSinceFirstSeen, runtime: 600, cpu: 5)
        let s = ProcessSignalsAnalyzer.analyze(p)
        XCTAssertTrue(s.badges.contains(.adoptedByLaunchd))
        XCTAssertEqual(s.confidence, .medium)
    }

    func testShortAdoptedOrphanProducesNoBadge() {
        // Too young to be sure — no badge, confidence stays low.
        let p = makeProcess(ppid: 1, orphanConfidence: .knownSinceFirstSeen, runtime: 30, cpu: 0)
        let s = ProcessSignalsAnalyzer.analyze(p)
        XCTAssertFalse(s.badges.contains(.adoptedByLaunchd))
    }

    // MARK: - Paused (SIGSTOP)

    func testPausedProducesPausedBadgeEvenIfOrphan() {
        let p = makeProcess(
            ppid: 1, orphanConfidence: .reparented,
            runtime: 300, cpu: 0, state: .stopped
        )
        let s = ProcessSignalsAnalyzer.analyze(p)
        XCTAssertTrue(s.badges.contains(.paused), "Pause must always surface")
        // Orphan confidence still drives the aggregate rating.
        XCTAssertEqual(s.confidence, .high)
    }

    // MARK: - Memory leak heuristic

    func testMemoryLeakHeuristicFiresForHighRSSZeroCPU() {
        let p = makeProcess(ppid: 500, orphanConfidence: .none, runtime: 600, cpu: 0, rssMB: 2000)
        let s = ProcessSignalsAnalyzer.analyze(p)
        XCTAssertTrue(s.badges.contains(where: { if case .memoryLeak = $0 { return true }; return false }))
        XCTAssertEqual(s.confidence, .medium)
    }

    func testMemoryLeakDoesNotFireIfCPUActive() {
        let p = makeProcess(ppid: 500, orphanConfidence: .none, runtime: 600, cpu: 80, rssMB: 2000)
        let s = ProcessSignalsAnalyzer.analyze(p)
        XCTAssertFalse(s.badges.contains(where: { if case .memoryLeak = $0 { return true }; return false }))
    }

    // MARK: - Active vs idle

    func testActiveProcessBadgesAsActiveLowConfidence() {
        // No orphan, no rule match, just a running test chewing CPU.
        let p = makeProcess(ppid: 500, orphanConfidence: .none, runtime: 60, cpu: 80)
        let s = ProcessSignalsAnalyzer.analyze(p)
        XCTAssertTrue(s.badges.contains(where: { if case .active = $0 { return true }; return false }))
        XCTAssertEqual(s.confidence, .low, "Active = probably intentional")
    }

    func testIdleProcessBadgesWithMinutes() {
        let p = makeProcess(ppid: 500, orphanConfidence: .none, runtime: 600, cpu: 0)
        let s = ProcessSignalsAnalyzer.analyze(p)
        // runtime / 60 = 10
        XCTAssertTrue(s.badges.contains(.idle(minutes: 10)))
        XCTAssertEqual(s.confidence, .medium)
    }

    func testShortIdleDoesNotBadge() {
        // Runtime under 5 min → no idle badge, avoid noise.
        let p = makeProcess(ppid: 500, orphanConfidence: .none, runtime: 60, cpu: 0)
        let s = ProcessSignalsAnalyzer.analyze(p)
        XCTAssertFalse(s.badges.contains(where: { if case .idle = $0 { return true }; return false }))
    }

    // MARK: - Rule signals

    func testRuleWarnBadgesAsRuleWithMediumConfidence() {
        let rule = ProcessRule(
            id: UUID(), pattern: "vitest",
            cpuThreshold: 50, runtimeThreshold: 600, maxRuntime: 1200,
            action: .warn, isEnabled: true
        )
        let p = makeProcess(ppid: 500, orphanConfidence: .none, runtime: 700, cpu: 30)
        let s = ProcessSignalsAnalyzer.analyze(p, rule: rule)
        XCTAssertTrue(s.badges.contains(.ruleWarn(pattern: "vitest")))
        XCTAssertEqual(s.confidence, .medium)
    }

    func testRuleHardKillBadgesAsKillWithHighConfidence() {
        let rule = ProcessRule(
            id: UUID(), pattern: "vitest",
            cpuThreshold: 50, runtimeThreshold: 600, maxRuntime: 1200,
            action: .warn, isEnabled: true
        )
        let p = makeProcess(ppid: 500, orphanConfidence: .none, runtime: 1300, cpu: 80)
        let s = ProcessSignalsAnalyzer.analyze(p, rule: rule, hardKillTrigger: "runtime")
        XCTAssertTrue(s.badges.contains(.ruleHardKill(pattern: "vitest", trigger: "runtime")))
        XCTAssertEqual(s.confidence, .high)
    }

    // MARK: - Catch-all

    func testCatchAllExpiredBadgesWithHighConfidence() {
        let p = makeProcess(ppid: 500, orphanConfidence: .none, runtime: 36_000, cpu: 0)
        let s = ProcessSignalsAnalyzer.analyze(p, catchAllExceeded: true)
        XCTAssertTrue(s.badges.contains(.catchAllExpired))
        XCTAssertEqual(s.confidence, .high)
    }

    // MARK: - Label rendering

    func testBadgeLabels() {
        XCTAssertEqual(ProcessSignal.newlyOrphaned.label, "NEW ORPHAN")
        XCTAssertEqual(ProcessSignal.adoptedByLaunchd.label, "ORPHAN")
        XCTAssertEqual(ProcessSignal.idle(minutes: 7).label, "IDLE 7m")
        XCTAssertEqual(ProcessSignal.active(percent: 121).label, "ACTIVE 121%")
        XCTAssertEqual(ProcessSignal.memoryLeak(mb: 1234).label, "LEAK 1234MB")
        XCTAssertEqual(ProcessSignal.paused.label, "PAUSED")
        XCTAssertEqual(ProcessSignal.catchAllExpired.label, "EXPIRED")
    }

    // MARK: - Kill signal priority (active vs. orphan)

    func testActiveBadgeSuppressedByKillSignal() {
        // High-CPU process that's also reparented: we still want NEW ORPHAN
        // to drive the decision, not an ACTIVE badge that would lull the user.
        let p = makeProcess(ppid: 1, orphanConfidence: .reparented, runtime: 300, cpu: 80)
        let s = ProcessSignalsAnalyzer.analyze(p)
        XCTAssertTrue(s.badges.contains(.newlyOrphaned))
        XCTAssertFalse(s.badges.contains(where: { if case .active = $0 { return true }; return false }),
                       "A kill signal already explains the row — don't add ACTIVE")
    }

    // MARK: - Helpers

    private func makeProcess(
        pid: Int32 = 1000,
        ppid: Int32,
        orphanConfidence: OrphanConfidence,
        runtime: TimeInterval,
        cpu: Double,
        rssMB: Double = 100,
        state: ProcessState = .running
    ) -> DevProcess {
        let now = Date()
        return DevProcess(
            id: pid, user: "u",
            cpuPercent: cpu, memPercent: 5,
            rss: Int(rssMB * 1024), // KB
            command: "vitest --forks --silent",
            startTime: now.addingTimeInterval(-runtime),
            parentPID: ppid,
            isOrphan: ppid == 1,
            state: state,
            startTimestamp: Int64(now.timeIntervalSince1970 - runtime),
            orphanConfidence: orphanConfidence
        )
    }
}
