import XCTest
@testable import DevWatchdog

final class EmergencyStateTests: XCTestCase {

    private let defaultDeriver = EmergencyStateDeriver(
        ncpu: 8,
        emergencyLoadFactor: 2.0,
        elevatedLoadFactor: 1.0,
        cooldownSeconds: 30
    )

    // MARK: - desired(from:)

    func testDesiredNormal() {
        let snap = makeSnapshot(level: .normal, loadAverage: 1.0, ncpu: 8) // lf = 0.125
        XCTAssertEqual(defaultDeriver.desired(from: snap), .normal)
    }

    func testDesiredElevatedFromMemoryPressure() {
        // Low load factor but OS-reported memory pressure elevated.
        let snap = makeSnapshot(level: .elevated, loadAverage: 0.5, ncpu: 8)
        XCTAssertEqual(defaultDeriver.desired(from: snap), .elevated)
    }

    func testDesiredElevatedFromLoadFactor() {
        // loadFactor 1.5 (12/8), but overall pressure only "normal".
        let snap = makeSnapshot(level: .normal, loadAverage: 12, ncpu: 8)
        XCTAssertEqual(defaultDeriver.desired(from: snap), .elevated)
    }

    func testDesiredEmergencyFromCriticalPressure() {
        let snap = makeSnapshot(level: .critical, loadAverage: 0.1, ncpu: 8)
        XCTAssertEqual(defaultDeriver.desired(from: snap), .emergency)
    }

    func testDesiredEmergencyFromLoadFactor() {
        // loadFactor 2.5 (20/8) > emergencyLoadFactor 2.0.
        let snap = makeSnapshot(level: .normal, loadAverage: 20, ncpu: 8)
        XCTAssertEqual(defaultDeriver.desired(from: snap), .emergency)
    }

    // MARK: - nextState (upward)

    func testUpwardTransitionIsImmediateNormalToElevated() {
        let now = Date()
        let r = defaultDeriver.nextState(current: .normal, desired: .elevated, now: now, lastHighSeenAt: nil)
        XCTAssertEqual(r.state, .elevated)
        XCTAssertEqual(r.lastHighSeenAt, now)
    }

    func testUpwardTransitionIsImmediateElevatedToEmergency() {
        let now = Date()
        let r = defaultDeriver.nextState(current: .elevated, desired: .emergency, now: now, lastHighSeenAt: nil)
        XCTAssertEqual(r.state, .emergency)
        XCTAssertEqual(r.lastHighSeenAt, now)
    }

    func testUpwardTransitionIsImmediateNormalToEmergency() {
        let now = Date()
        let r = defaultDeriver.nextState(current: .normal, desired: .emergency, now: now, lastHighSeenAt: nil)
        XCTAssertEqual(r.state, .emergency)
        XCTAssertEqual(r.lastHighSeenAt, now)
    }

    func testSameLevelStaysAndRefreshesTimestamp() {
        let then = Date(timeIntervalSince1970: 1000)
        let now = Date(timeIntervalSince1970: 1100)
        let r = defaultDeriver.nextState(current: .emergency, desired: .emergency, now: now, lastHighSeenAt: then)
        XCTAssertEqual(r.state, .emergency)
        // Must refresh so the downward cooldown starts from the newest "still high" moment.
        XCTAssertEqual(r.lastHighSeenAt, now)
    }

    // MARK: - nextState (downward — hysteresis)

    func testDownwardTransitionBlockedWithinCooldown() {
        let high = Date(timeIntervalSince1970: 1000)
        let now = high.addingTimeInterval(10) // 10s < 30s cooldown
        let r = defaultDeriver.nextState(current: .emergency, desired: .normal, now: now, lastHighSeenAt: high)
        XCTAssertEqual(r.state, .emergency, "Still within cooldown → must stay in emergency")
        XCTAssertEqual(r.lastHighSeenAt, high, "Preserves the high-water mark")
    }

    func testDownwardTransitionFiresAfterCooldown() {
        let high = Date(timeIntervalSince1970: 1000)
        let now = high.addingTimeInterval(31) // 31s > 30s cooldown
        let r = defaultDeriver.nextState(current: .emergency, desired: .normal, now: now, lastHighSeenAt: high)
        XCTAssertEqual(r.state, .normal)
        XCTAssertNil(r.lastHighSeenAt)
    }

    func testDownwardTransitionWithoutTimestampIsImmediate() {
        let now = Date()
        let r = defaultDeriver.nextState(current: .elevated, desired: .normal, now: now, lastHighSeenAt: nil)
        XCTAssertEqual(r.state, .normal)
        XCTAssertNil(r.lastHighSeenAt)
    }

    // MARK: - Full sequence

    func testNormalToEmergencyToNormalWithStateTracking() {
        let t0 = Date(timeIntervalSince1970: 0)
        var state: EmergencyState = .normal
        var lastHigh: Date? = nil

        // t0: spike to emergency
        var r = defaultDeriver.nextState(current: state, desired: .emergency, now: t0, lastHighSeenAt: lastHigh)
        state = r.state; lastHigh = r.lastHighSeenAt
        XCTAssertEqual(state, .emergency)
        XCTAssertEqual(lastHigh, t0)

        // t0+10: pressure says normal again, but we're still in cooldown.
        let t10 = t0.addingTimeInterval(10)
        r = defaultDeriver.nextState(current: state, desired: .normal, now: t10, lastHighSeenAt: lastHigh)
        state = r.state; lastHigh = r.lastHighSeenAt
        XCTAssertEqual(state, .emergency)
        XCTAssertEqual(lastHigh, t0)

        // t0+45: cooldown elapsed → drop to normal.
        let t45 = t0.addingTimeInterval(45)
        r = defaultDeriver.nextState(current: state, desired: .normal, now: t45, lastHighSeenAt: lastHigh)
        state = r.state; lastHigh = r.lastHighSeenAt
        XCTAssertEqual(state, .normal)
        XCTAssertNil(lastHigh)
    }

    func testDownwardTwoStepRespectsCooldownAtEachStep() {
        let t0 = Date(timeIntervalSince1970: 0)
        // emergency → elevated is still a downward transition and gated by cooldown.
        let early = defaultDeriver.nextState(
            current: .emergency,
            desired: .elevated,
            now: t0.addingTimeInterval(5),
            lastHighSeenAt: t0
        )
        XCTAssertEqual(early.state, .emergency)

        let late = defaultDeriver.nextState(
            current: .emergency,
            desired: .elevated,
            now: t0.addingTimeInterval(31),
            lastHighSeenAt: t0
        )
        XCTAssertEqual(late.state, .elevated)
    }

    func testLastHighSeenAtRefreshesOnUpwardSpike() {
        let t0 = Date(timeIntervalSince1970: 0)
        let t10 = t0.addingTimeInterval(10)
        let r = defaultDeriver.nextState(current: .elevated, desired: .emergency, now: t10, lastHighSeenAt: t0)
        XCTAssertEqual(r.state, .emergency)
        XCTAssertEqual(r.lastHighSeenAt, t10, "Upward promotion must refresh the timestamp")
    }

    // MARK: - Enum plumbing

    func testEmergencyStateDisplayNames() {
        XCTAssertEqual(EmergencyState.normal.displayName, "Normal")
        XCTAssertEqual(EmergencyState.elevated.displayName, "Elevated")
        XCTAssertEqual(EmergencyState.emergency.displayName, "Emergency")
    }

    func testEmergencyStateSeverityOrdering() {
        XCTAssertLessThan(EmergencyState.normal.severity, EmergencyState.elevated.severity)
        XCTAssertLessThan(EmergencyState.elevated.severity, EmergencyState.emergency.severity)
    }

    // MARK: - Helpers

    private func makeSnapshot(
        level: PressureLevel,
        loadAverage: Double,
        ncpu: Int
    ) -> SystemPressureSnapshot {
        SystemPressureSnapshot(
            level: level,
            memoryPressure: level,
            loadAverage1m: loadAverage,
            ncpu: ncpu,
            swapUsedMB: 0,
            swapTotalMB: 1024,
            timestamp: Date(timeIntervalSince1970: 0)
        )
    }
}
