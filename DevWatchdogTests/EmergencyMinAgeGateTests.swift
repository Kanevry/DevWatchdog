import XCTest
@testable import DevWatchdog

@MainActor
final class EmergencyMinAgeGateTests: XCTestCase {

    override func tearDown() async throws {
        // Clean up UserDefaults keys written by WatchdogConfig so tests don't leak state.
        let keys = [
            "emergencyMinAgeSeconds", "emergencyModeEnabled", "emergencyLoadFactor",
            "elevatedLoadFactor", "emergencyCooldown", "softKillPreferred", "psTimeoutSeconds",
        ]
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
    }

    // MARK: - WatchdogConfig defaults

    func testConfigHasDefaultMinAgeOf60Seconds() {
        // Remove any previously persisted value so we always read the hard-coded default.
        UserDefaults.standard.removeObject(forKey: "emergencyMinAgeSeconds")
        let config = WatchdogConfig()
        XCTAssertEqual(config.emergencyMinAgeSeconds, 60,
            "Default emergencyMinAgeSeconds must be 60")
    }

    func testConfigMinAgePersistsToUserDefaults() {
        let config = WatchdogConfig()
        config.emergencyMinAgeSeconds = 45
        XCTAssertEqual(
            UserDefaults.standard.double(forKey: "emergencyMinAgeSeconds"),
            45,
            "emergencyMinAgeSeconds must be persisted to UserDefaults when changed"
        )
    }

    func testConfigMinAgeCanBeSetToZero() {
        // Zero means "promote immediately regardless of age" — must be storable.
        let config = WatchdogConfig()
        config.emergencyMinAgeSeconds = 0
        // After setting to 0 the config reads back via UserDefaults; 0.nonZero is nil,
        // so a freshly loaded config would reset to the default. Test the live config object.
        XCTAssertEqual(config.emergencyMinAgeSeconds, 0,
            "emergencyMinAgeSeconds must be 0 after explicitly setting it to 0 (live object)")
    }

    // MARK: - DevProcess.runtime gate

    func testFreshProcessRuntimeBelowMinAgeThreshold() {
        // A process started 5 seconds ago must have runtime < 10s.
        let nowSec = Int64(Date().timeIntervalSince1970)
        let fresh = DevProcess(
            id: 99991,
            user: "testuser",
            cpuPercent: 50,
            memPercent: 10,
            rss: 1_048_576, // 1 GB in KB
            command: "/usr/bin/next build",
            startTime: nil,
            parentPID: 1,
            isOrphan: false,
            state: .running,
            startTimestamp: nowSec - 5  // 5 seconds old
        )
        let rt = fresh.runtime
        XCTAssertNotNil(rt, "runtime must not be nil when startTimestamp is set")
        XCTAssertLessThan(rt!, 10,
            "A process started 5s ago must have runtime < 10s")
    }

    func testOldProcessRuntimeAboveMinAgeThreshold() {
        // A process started 120 seconds ago must have runtime >= 60s.
        let nowSec = Int64(Date().timeIntervalSince1970)
        let old = DevProcess(
            id: 99992,
            user: "testuser",
            cpuPercent: 80,
            memPercent: 30,
            rss: 524_288, // 512 MB in KB
            command: "/usr/bin/webpack",
            startTime: nil,
            parentPID: 1,
            isOrphan: false,
            state: .running,
            startTimestamp: nowSec - 120  // 120 seconds old
        )
        let rt = old.runtime
        XCTAssertNotNil(rt, "runtime must not be nil when startTimestamp is set")
        XCTAssertGreaterThanOrEqual(rt!, 60,
            "A process started 120s ago must have runtime >= 60s")
    }

    func testProcessWithNoStartInfoHasNilRuntime() {
        // When both startTimestamp and startTime are absent, runtime must be nil.
        let p = DevProcess(
            id: 99993,
            user: "testuser",
            cpuPercent: 30,
            memPercent: 5,
            rss: 10_240,
            command: "/usr/local/bin/node server.js",
            startTime: nil,
            parentPID: 1,
            isOrphan: true,
            state: .running,
            startTimestamp: nil
        )
        XCTAssertNil(p.runtime,
            "runtime must be nil when neither startTimestamp nor startTime is available")
    }

    func testMinAgeGateLogic_freshProcessShouldBeExcluded() {
        // Mirror the inline filter from ProcessMonitor.scan():
        //   guard let rt = p.runtime else { return true }
        //   return rt >= minAge
        let nowSec = Int64(Date().timeIntervalSince1970)
        let minAge: TimeInterval = 60

        let fresh = DevProcess(
            id: 99994,
            user: "testuser",
            cpuPercent: 95,
            memPercent: 40,
            rss: 204_800,
            command: "/usr/bin/esbuild --bundle",
            startTime: nil,
            parentPID: 1,
            isOrphan: false,
            state: .running,
            startTimestamp: nowSec - 10  // only 10 seconds old
        )

        let shouldPromote: Bool = {
            guard let rt = fresh.runtime else { return true }
            return rt >= minAge
        }()

        XCTAssertFalse(shouldPromote,
            "A process with runtime < minAge must be excluded from emergency promotion")
    }

    func testMinAgeGateLogic_oldProcessShouldBeIncluded() {
        let nowSec = Int64(Date().timeIntervalSince1970)
        let minAge: TimeInterval = 60

        let old = DevProcess(
            id: 99995,
            user: "testuser",
            cpuPercent: 90,
            memPercent: 35,
            rss: 307_200,
            command: "/usr/bin/tsc --watch",
            startTime: nil,
            parentPID: 1,
            isOrphan: false,
            state: .running,
            startTimestamp: nowSec - 300  // 5 minutes old
        )

        let shouldPromote: Bool = {
            guard let rt = old.runtime else { return true }
            return rt >= minAge
        }()

        XCTAssertTrue(shouldPromote,
            "A process with runtime >= minAge must be eligible for emergency promotion")
    }

    func testMinAgeGateLogic_processWithNoRuntimeIsIncluded() {
        // When runtime is unknown (nil), the gate must NOT block (treat as old).
        let minAge: TimeInterval = 60

        let unknown = DevProcess(
            id: 99996,
            user: "testuser",
            cpuPercent: 70,
            memPercent: 20,
            rss: 102_400,
            command: "/usr/local/bin/node worker.js",
            startTime: nil,
            parentPID: 1,
            isOrphan: true,
            state: .running,
            startTimestamp: nil
        )

        let shouldPromote: Bool = {
            guard let rt = unknown.runtime else { return true }
            return rt >= minAge
        }()

        XCTAssertTrue(shouldPromote,
            "A process with no known runtime must pass the min-age gate (treated as old)")
    }
}
