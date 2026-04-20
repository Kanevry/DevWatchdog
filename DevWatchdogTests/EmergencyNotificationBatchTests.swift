import XCTest
@testable import DevWatchdog

final class EmergencyNotificationBatchTests: XCTestCase {

    // MARK: - State transition matrix (3×3 = 9 cases)

    func testNormalToNormal() {
        let d = EmergencyNotificationBatcher.onStateTransition(from: .normal, to: .normal)
        XCTAssertFalse(d.sendEntryAlert)
        XCTAssertFalse(d.sendExitAlert)
        XCTAssertFalse(d.suppressIndividualKills)
    }

    func testNormalToElevated() {
        let d = EmergencyNotificationBatcher.onStateTransition(from: .normal, to: .elevated)
        XCTAssertFalse(d.sendEntryAlert, "elevated is not a critical state")
        XCTAssertFalse(d.sendExitAlert)
        XCTAssertFalse(d.suppressIndividualKills)
    }

    func testNormalToEmergency() {
        let d = EmergencyNotificationBatcher.onStateTransition(from: .normal, to: .emergency)
        XCTAssertTrue(d.sendEntryAlert)
        XCTAssertFalse(d.sendExitAlert)
        XCTAssertTrue(d.suppressIndividualKills)
    }

    func testElevatedToNormal() {
        let d = EmergencyNotificationBatcher.onStateTransition(from: .elevated, to: .normal)
        XCTAssertFalse(d.sendEntryAlert)
        XCTAssertFalse(d.sendExitAlert, "elevated → normal is quiet — no exit summary")
        XCTAssertFalse(d.suppressIndividualKills)
    }

    func testElevatedToElevated() {
        let d = EmergencyNotificationBatcher.onStateTransition(from: .elevated, to: .elevated)
        XCTAssertFalse(d.sendEntryAlert)
        XCTAssertFalse(d.sendExitAlert)
        XCTAssertFalse(d.suppressIndividualKills)
    }

    func testElevatedToEmergency() {
        let d = EmergencyNotificationBatcher.onStateTransition(from: .elevated, to: .emergency)
        XCTAssertTrue(d.sendEntryAlert)
        XCTAssertFalse(d.sendExitAlert)
        XCTAssertTrue(d.suppressIndividualKills)
    }

    func testEmergencyToNormal() {
        let d = EmergencyNotificationBatcher.onStateTransition(from: .emergency, to: .normal)
        XCTAssertFalse(d.sendEntryAlert)
        XCTAssertTrue(d.sendExitAlert)
        XCTAssertFalse(d.suppressIndividualKills, "back to normal — resume individual kill toasts")
    }

    func testEmergencyToElevated() {
        let d = EmergencyNotificationBatcher.onStateTransition(from: .emergency, to: .elevated)
        XCTAssertFalse(d.sendEntryAlert)
        XCTAssertTrue(d.sendExitAlert)
        XCTAssertFalse(d.suppressIndividualKills)
    }

    func testEmergencyToEmergency() {
        let d = EmergencyNotificationBatcher.onStateTransition(from: .emergency, to: .emergency)
        XCTAssertFalse(d.sendEntryAlert, "already in emergency — no double alert")
        XCTAssertFalse(d.sendExitAlert)
        XCTAssertTrue(d.suppressIndividualKills, "still in emergency — still suppressing")
    }

    // MARK: - Kill-during-emergency decisions

    func testKillDuringEmergencyIsSuppressed() {
        let d = EmergencyNotificationBatcher.onKillDuringEmergency(
            emergencyState: .emergency,
            isNewBatch: true
        )
        XCTAssertTrue(d.suppressIndividualKills)
        XCTAssertFalse(d.sendKillDuringEmergency)
    }

    func testKillOutsideEmergencyNotifiesNormally() {
        for state: EmergencyState in [.normal, .elevated] {
            let d = EmergencyNotificationBatcher.onKillDuringEmergency(
                emergencyState: state,
                isNewBatch: true
            )
            XCTAssertFalse(d.suppressIndividualKills, "outside emergency: no suppression (\(state))")
            XCTAssertTrue(d.sendKillDuringEmergency, "outside emergency: normal batch flow fires (\(state))")
        }
    }

    // MARK: - Invariants

    func testEntryAndExitAreMutuallyExclusive() {
        for from in EmergencyState.allCases {
            for to in EmergencyState.allCases {
                let d = EmergencyNotificationBatcher.onStateTransition(from: from, to: to)
                XCTAssertFalse(d.sendEntryAlert && d.sendExitAlert,
                    "entry+exit simultaneously for \(from) → \(to)")
            }
        }
    }

    func testSuppressIndividualKillsMatchesDestinationEmergency() {
        for from in EmergencyState.allCases {
            for to in EmergencyState.allCases {
                let d = EmergencyNotificationBatcher.onStateTransition(from: from, to: to)
                XCTAssertEqual(d.suppressIndividualKills, to == .emergency,
                    "suppress flag should mirror destination == .emergency (\(from) → \(to))")
            }
        }
    }
}
