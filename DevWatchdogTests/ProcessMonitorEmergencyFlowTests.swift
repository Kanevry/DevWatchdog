import XCTest
import Combine
@testable import DevWatchdog

@MainActor
final class ProcessMonitorEmergencyFlowTests: XCTestCase {

    // MARK: - Setup

    private func makeMonitor() -> (ProcessMonitor, FakeSystemPressureSource, FakeProcessTerminator, WatchdogConfig) {
        let fake = FakeSystemPressureSource()
        let terminator = FakeProcessTerminator()
        let monitor = ProcessMonitor(pressureSource: fake, terminator: terminator)
        let config = WatchdogConfig()
        // Deterministic defaults — don't rely on prior UserDefaults state.
        config.scanInterval = 30
        config.gracePeriod = 30
        config.emergencyModeEnabled = true
        config.emergencyLoadFactor = 2.0
        config.elevatedLoadFactor = 1.0
        config.emergencyCooldown = 30
        return (monitor, fake, terminator, config)
    }

    override func tearDown() async throws {
        // Reset the volatile emergency keys so tests don't leak state.
        let keys = ["emergencyModeEnabled", "emergencyLoadFactor", "elevatedLoadFactor", "emergencyCooldown", "softKillPreferred"]
        for k in keys { UserDefaults.standard.removeObject(forKey: k) }
    }

    // MARK: - Tests

    func testNormalSnapshotYieldsNormalState() async {
        let (monitor, fake, _, config) = makeMonitor()
        monitor.start(config: config)
        defer { monitor.stop() }

        fake.emit(makeSnapshot(level: .normal, load: 0.5, ncpu: 8))

        // Allow RunLoop hop from the subscriber.
        await yieldMainRunLoop()

        XCTAssertEqual(monitor.emergencyState, .normal)
        XCTAssertEqual(monitor.effectiveScanInterval, 30)
        XCTAssertEqual(monitor.effectiveGracePeriod, 30)
    }

    func testCriticalSnapshotDrivesEmergencyWithinOneScan() async {
        let (monitor, fake, _, config) = makeMonitor()
        monitor.start(config: config)
        defer { monitor.stop() }

        fake.emit(makeSnapshot(level: .critical, load: 30, ncpu: 8))
        await yieldMainRunLoop()

        XCTAssertEqual(monitor.emergencyState, .emergency)
        XCTAssertEqual(monitor.effectiveScanInterval, 3, "Emergency cadence is 3s")
        XCTAssertEqual(monitor.effectiveGracePeriod, 0, "Emergency collapses grace to 0")
    }

    func testElevatedSnapshotTightensScanInterval() async {
        let (monitor, fake, _, config) = makeMonitor()
        monitor.start(config: config)
        defer { monitor.stop() }

        // loadFactor ~1.5 — elevated but not emergency.
        fake.emit(makeSnapshot(level: .elevated, load: 12, ncpu: 8))
        await yieldMainRunLoop()

        XCTAssertEqual(monitor.emergencyState, .elevated)
        // max(2, min(30/3, 10)) = max(2, min(10, 10)) = 10
        XCTAssertEqual(monitor.effectiveScanInterval, 10)
        // gracePeriod / 2 = 15
        XCTAssertEqual(monitor.effectiveGracePeriod, 15)
    }

    func testDisablingEmergencyModeRestoresStaticInterval() async {
        let (monitor, fake, _, config) = makeMonitor()
        monitor.start(config: config)
        defer { monitor.stop() }

        fake.emit(makeSnapshot(level: .critical, load: 30, ncpu: 8))
        await yieldMainRunLoop()
        XCTAssertEqual(monitor.effectiveScanInterval, 3)

        config.emergencyModeEnabled = false
        await yieldMainRunLoop()
        XCTAssertEqual(monitor.effectiveScanInterval, config.scanInterval,
            "With Emergency Mode off, fall back to the configured static interval")
        XCTAssertEqual(monitor.effectiveGracePeriod, config.gracePeriod)
    }

    func testStateTransitionIsRecorded() async {
        let (monitor, fake, _, config) = makeMonitor()
        monitor.start(config: config)
        defer { monitor.stop() }

        fake.emit(makeSnapshot(level: .critical, load: 30, ncpu: 8))
        await yieldMainRunLoop()

        XCTAssertFalse(monitor.stateTransitions.isEmpty)
        let last = monitor.stateTransitions.last
        XCTAssertEqual(last?.from, .normal)
        XCTAssertEqual(last?.to, .emergency)
    }

    func testDownwardTransitionWaitsForCooldown() async {
        let (monitor, fake, _, config) = makeMonitor()
        // Long cooldown so the test doesn't have to sleep for real seconds.
        config.emergencyCooldown = 3600
        monitor.start(config: config)
        defer { monitor.stop() }

        // Spike to emergency
        fake.emit(makeSnapshot(level: .critical, load: 30, ncpu: 8))
        await yieldMainRunLoop()
        XCTAssertEqual(monitor.emergencyState, .emergency)

        // Pressure drops — but cooldown hasn't elapsed. Must stay in emergency.
        fake.emit(makeSnapshot(level: .normal, load: 0.1, ncpu: 8))
        await yieldMainRunLoop()
        XCTAssertEqual(monitor.emergencyState, .emergency, "Hysteresis must block downward transition during cooldown")
    }

    // MARK: - Helpers

    private func makeSnapshot(
        level: PressureLevel,
        load: Double,
        ncpu: Int
    ) -> SystemPressureSnapshot {
        SystemPressureSnapshot(
            level: level,
            memoryPressure: level,
            loadAverage1m: load,
            ncpu: ncpu,
            swapUsedMB: 0,
            swapTotalMB: 1024,
            timestamp: Date()
        )
    }

    /// Drain pending RunLoop.main work so the pressure sink can deliver.
    /// The sink hops via `.receive(on: RunLoop.main)`, which schedules on the
    /// default RunLoop mode rather than the cooperative pool — so sleeping
    /// alone is not enough; we also need to let the main RunLoop tick.
    private func yieldMainRunLoop() async {
        for _ in 0..<5 {
            try? await Task.sleep(nanoseconds: 20_000_000) // 20 ms
            await MainActor.run {
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            }
        }
    }
}
