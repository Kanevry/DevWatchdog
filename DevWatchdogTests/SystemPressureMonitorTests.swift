import XCTest
@testable import DevWatchdog

final class SystemPressureMonitorTests: XCTestCase {

    // MARK: - PressureLevel Comparable

    func testPressureLevelComparable() {
        XCTAssertLessThan(PressureLevel.normal, PressureLevel.elevated)
        XCTAssertLessThan(PressureLevel.elevated, PressureLevel.critical)
        XCTAssertLessThan(PressureLevel.normal, PressureLevel.critical)
        XCTAssertGreaterThan(PressureLevel.critical, PressureLevel.normal)
        XCTAssertEqual(PressureLevel.normal, PressureLevel.normal)
    }

    func testPressureLevelRawValuesStable() {
        // Codable stability: external code / persisted configs may rely on these.
        XCTAssertEqual(PressureLevel.normal.rawValue, 0)
        XCTAssertEqual(PressureLevel.elevated.rawValue, 1)
        XCTAssertEqual(PressureLevel.critical.rawValue, 2)
    }

    // MARK: - Snapshot math

    func testLoadFactor() {
        let snap = makeSnapshot(load: 4.0, ncpu: 8)
        XCTAssertEqual(snap.loadFactor, 0.5, accuracy: 0.0001)
    }

    func testLoadFactorWithZeroNcpuIsZero() {
        let snap = makeSnapshot(load: 4.0, ncpu: 0)
        XCTAssertEqual(snap.loadFactor, 0)
    }

    func testSwapUsageFraction() {
        let snap = makeSnapshot(swapUsed: 512, swapTotal: 2048)
        XCTAssertEqual(snap.swapUsageFraction, 0.25, accuracy: 0.0001)
    }

    func testSwapUsageFractionWithZeroTotalIsZero() {
        let snap = makeSnapshot(swapUsed: 0, swapTotal: 0)
        XCTAssertEqual(snap.swapUsageFraction, 0)
    }

    // MARK: - Level derivation

    func testDeriveNormal() {
        let level = PressureDeriver.derive(
            memoryPressure: .normal,
            loadFactor: 0.3,
            swapUsageFraction: 0.1
        )
        XCTAssertEqual(level, .normal)
    }

    func testDeriveElevatedFromLoad() {
        let level = PressureDeriver.derive(
            memoryPressure: .normal,
            loadFactor: 1.5,
            swapUsageFraction: 0.0
        )
        XCTAssertEqual(level, .elevated)
    }

    func testDeriveCriticalFromMemory() {
        let level = PressureDeriver.derive(
            memoryPressure: .critical,
            loadFactor: 0.1,
            swapUsageFraction: 0.0
        )
        XCTAssertEqual(level, .critical)
    }

    func testDeriveCriticalFromSwap() {
        let level = PressureDeriver.derive(
            memoryPressure: .normal,
            loadFactor: 0.1,
            swapUsageFraction: 0.95
        )
        XCTAssertEqual(level, .critical)
    }

    func testDeriveCriticalFromLoad() {
        let level = PressureDeriver.derive(
            memoryPressure: .normal,
            loadFactor: 2.5,
            swapUsageFraction: 0.0
        )
        XCTAssertEqual(level, .critical)
    }

    func testDeriveElevatedFromSwap() {
        let level = PressureDeriver.derive(
            memoryPressure: .normal,
            loadFactor: 0.0,
            swapUsageFraction: 0.75
        )
        XCTAssertEqual(level, .elevated)
    }

    func testDeriveElevatedFromMemory() {
        let level = PressureDeriver.derive(
            memoryPressure: .elevated,
            loadFactor: 0.0,
            swapUsageFraction: 0.0
        )
        XCTAssertEqual(level, .elevated)
    }

    // MARK: - Sysctl readers (live host)

    func testSysctlNcpuPositive() {
        XCTAssertGreaterThan(SysctlReader.ncpu(), 0)
    }

    func testSysctlLoadAverageNonNegative() {
        // Load average can dip to ~0 on idle CI, so only assert non-negative and finite.
        let load = SysctlReader.loadAverage1m()
        XCTAssertGreaterThanOrEqual(load, 0)
        XCTAssertTrue(load.isFinite)
    }

    func testSysctlSwapUsageSensible() {
        let swap = SysctlReader.swapUsage()
        XCTAssertGreaterThanOrEqual(swap.usedMB, 0)
        XCTAssertGreaterThanOrEqual(swap.totalMB, 0)
        // If there's any swap configured, used ≤ total.
        if swap.totalMB > 0 {
            XCTAssertLessThanOrEqual(swap.usedMB, swap.totalMB + 1) // tolerate rounding
        }
    }

    // MARK: - Live dispatch source wiring (regression)

    /// Regression test for the 2026-04-21 startup crash: under Swift 6 strict
    /// concurrency, `DispatchSource` event handlers formed inside a `@MainActor`
    /// function that capture `[weak self]` (a MainActor-isolated class) inherit
    /// an implicit executor check at closure entry. When the 5s fallback poll
    /// timer fired on `at.kanevry.DevWatchdog.SystemPressureMonitor`, the check
    /// called `dispatch_assert_queue` and crashed with `EXC_BREAKPOINT` / "BUG
    /// IN CLIENT OF LIBDISPATCH: Block was expected to execute on queue …".
    ///
    /// The fix produces the handlers from `nonisolated static` factories so
    /// they never inherit MainActor context. This test exercises the real
    /// `start()` path and waits for the first poll-timer fire (deadline `.now()`
    /// → fires within milliseconds) — if the regression comes back, this test
    /// will abort the process.
    @MainActor
    func testStartDoesNotCrashWhenPollTimerFires() async throws {
        let monitor = SystemPressureMonitor()

        // Subscribe BEFORE start() so we catch the first emit from the poll tick.
        let exp = expectation(description: "poll handler delivered a snapshot")
        exp.assertForOverFulfill = false
        let cancellable = monitor.snapshotPublisher
            .dropFirst() // skip the seeded initial value
            .sink { _ in exp.fulfill() }

        await monitor.start()

        // The poll timer is scheduled with `deadline: .now()`, so the first fire
        // happens on `pollQueue` essentially immediately. If the isolation-crash
        // regresses, the process aborts before this wait returns.
        await fulfillment(of: [exp], timeout: 10.0)

        cancellable.cancel()
        await monitor.stop()
    }

    // MARK: - FakeSystemPressureSource wiring

    @MainActor
    func testFakeSourceEmitsAndTracksStartStop() async {
        let fake = FakeSystemPressureSource()
        XCTAssertEqual(fake.startCount, 0)
        await fake.start()
        XCTAssertEqual(fake.startCount, 1)

        let next = makeSnapshot(load: 10, ncpu: 4, level: .critical)
        fake.emit(next)
        XCTAssertEqual(fake.currentSnapshot, next)

        fake.stop()
        XCTAssertEqual(fake.stopCount, 1)
    }

    // MARK: - Helpers

    private func makeSnapshot(
        load: Double = 0,
        ncpu: Int = 8,
        swapUsed: Double = 0,
        swapTotal: Double = 0,
        level: PressureLevel = .normal
    ) -> SystemPressureSnapshot {
        SystemPressureSnapshot(
            level: level,
            memoryPressure: .normal,
            loadAverage1m: load,
            ncpu: ncpu,
            swapUsedMB: swapUsed,
            swapTotalMB: swapTotal,
            timestamp: Date(timeIntervalSince1970: 0)
        )
    }
}
