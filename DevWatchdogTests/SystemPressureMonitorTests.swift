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

    // MARK: - Compressor / memory-fraction math

    func testCompressorFraction() {
        let snap = makeSnapshot(compressorMB: 2048, physicalMB: 8192)
        XCTAssertEqual(snap.compressorFraction, 0.25, accuracy: 0.0001)
    }

    func testCompressorFractionClampsAtOne() {
        // If the kernel reports more compressor pages than physical RAM (shouldn't
        // happen, but be defensive), clamp to 1.0 so derivation thresholds still apply.
        let snap = makeSnapshot(compressorMB: 16_384, physicalMB: 8192)
        XCTAssertEqual(snap.compressorFraction, 1.0, accuracy: 0.0001)
    }

    func testCompressorFractionWithZeroPhysicalIsZero() {
        let snap = makeSnapshot(compressorMB: 2048, physicalMB: 0)
        XCTAssertEqual(snap.compressorFraction, 0)
    }

    func testMemoryUsageFractionPrefersCompressor() {
        // Apple Silicon case: zero swap, high compressor.
        let snap = makeSnapshot(
            swapUsed: 0, swapTotal: 0,
            compressorMB: 6144, physicalMB: 8192
        )
        XCTAssertEqual(snap.memoryUsageFraction, 0.75, accuracy: 0.0001)
    }

    func testMemoryUsageFractionPrefersSwap() {
        // Intel / swap-heavy case: high swap, no compressor reported.
        let snap = makeSnapshot(
            swapUsed: 1800, swapTotal: 2000,
            compressorMB: 100, physicalMB: 8192
        )
        XCTAssertEqual(snap.memoryUsageFraction, 0.9, accuracy: 0.0001)
    }

    // MARK: - Level derivation

    func testDeriveNormal() {
        let level = PressureDeriver.derive(
            memoryPressure: .normal,
            loadFactor: 0.3,
            memoryUsageFraction: 0.1
        )
        XCTAssertEqual(level, .normal)
    }

    func testDeriveElevatedFromLoad() {
        let level = PressureDeriver.derive(
            memoryPressure: .normal,
            loadFactor: 1.5,
            memoryUsageFraction: 0.0
        )
        XCTAssertEqual(level, .elevated)
    }

    func testDeriveCriticalFromMemory() {
        let level = PressureDeriver.derive(
            memoryPressure: .critical,
            loadFactor: 0.1,
            memoryUsageFraction: 0.0
        )
        XCTAssertEqual(level, .critical)
    }

    func testDeriveCriticalFromMemoryFraction() {
        let level = PressureDeriver.derive(
            memoryPressure: .normal,
            loadFactor: 0.1,
            memoryUsageFraction: 0.95
        )
        XCTAssertEqual(level, .critical)
    }

    func testDeriveCriticalFromLoad() {
        let level = PressureDeriver.derive(
            memoryPressure: .normal,
            loadFactor: 2.5,
            memoryUsageFraction: 0.0
        )
        XCTAssertEqual(level, .critical)
    }

    func testDeriveElevatedFromMemoryFraction() {
        let level = PressureDeriver.derive(
            memoryPressure: .normal,
            loadFactor: 0.0,
            memoryUsageFraction: 0.75
        )
        XCTAssertEqual(level, .elevated)
    }

    func testDeriveElevatedFromMemory() {
        let level = PressureDeriver.derive(
            memoryPressure: .elevated,
            loadFactor: 0.0,
            memoryUsageFraction: 0.0
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

    func testSysctlPhysicalMemoryPositive() {
        XCTAssertGreaterThan(SysctlReader.physicalMemoryMB(), 0)
    }

    func testVMStatsReaderSampleSucceeds() {
        let sample = VMStatsReader.sample()
        XCTAssertNotNil(sample, "host_statistics64 should never fail on a healthy host")
        guard let sample else { return }
        // Page size on macOS is 4K (Intel) or 16K (Apple Silicon).
        XCTAssertTrue(sample.pageSize == 4096 || sample.pageSize == 16384,
                      "unexpected page size \(sample.pageSize)")
        XCTAssertGreaterThanOrEqual(sample.compressions, 0)
    }

    func testVMStatsReaderRateIsNonNegative() {
        guard let first = VMStatsReader.sample() else {
            XCTFail("sample() returned nil")
            return
        }
        // Forge a second sample with artificially increased compressions.
        let second = VMStatsSample(
            pageSize: first.pageSize,
            compressorPages: first.compressorPages,
            compressions: first.compressions + 5_000,
            decompressions: first.decompressions,
            timestamp: first.timestamp.addingTimeInterval(5)
        )
        let rate = VMStatsReader.compressionRate(previous: first, current: second)
        XCTAssertEqual(rate, 1000, accuracy: 0.1)
    }

    func testVMStatsReaderRateZeroOnRegression() {
        let first = VMStatsSample(
            pageSize: 16384, compressorPages: 0,
            compressions: 1000, decompressions: 0,
            timestamp: Date(timeIntervalSince1970: 0)
        )
        let second = VMStatsSample(
            pageSize: 16384, compressorPages: 0,
            compressions: 500, decompressions: 0, // went DOWN
            timestamp: Date(timeIntervalSince1970: 5)
        )
        XCTAssertEqual(VMStatsReader.compressionRate(previous: first, current: second), 0)
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
        monitor.stop()
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
        compressorMB: Double = 0,
        physicalMB: Double = 0,
        compressionRate: Double = 0,
        level: PressureLevel = .normal
    ) -> SystemPressureSnapshot {
        SystemPressureSnapshot(
            level: level,
            memoryPressure: .normal,
            loadAverage1m: load,
            ncpu: ncpu,
            swapUsedMB: swapUsed,
            swapTotalMB: swapTotal,
            compressorUsedMB: compressorMB,
            physicalMemoryMB: physicalMB,
            compressionRate: compressionRate,
            timestamp: Date(timeIntervalSince1970: 0)
        )
    }
}
