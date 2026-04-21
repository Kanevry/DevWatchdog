import XCTest
@testable import DevWatchdog

@MainActor
final class KillReasonAuditTests: XCTestCase {

    // MARK: - KillTrigger round-trip

    func testKillTriggerRoundTripJSON() throws {
        let triggers: [KillTrigger] = [
            .maxRuntime, .maxCPUPercent, .maxRSSMB,
            .orphanTimeout, .catchAllMaxRuntime,
            .emergencyPromotion, .manual
        ]
        for trigger in triggers {
            let data = try JSONEncoder().encode(trigger)
            let decoded = try JSONDecoder().decode(KillTrigger.self, from: data)
            XCTAssertEqual(decoded, trigger, "Round-trip failed for trigger: \(trigger)")
        }
    }

    func testKillTriggerRawValues() {
        // Verify raw string values match the documented API surface
        XCTAssertEqual(KillTrigger.maxRuntime.rawValue, "maxRuntime")
        XCTAssertEqual(KillTrigger.maxCPUPercent.rawValue, "maxCPUPercent")
        XCTAssertEqual(KillTrigger.maxRSSMB.rawValue, "maxRSSMB")
        XCTAssertEqual(KillTrigger.orphanTimeout.rawValue, "orphanTimeout")
        XCTAssertEqual(KillTrigger.catchAllMaxRuntime.rawValue, "catchAllMaxRuntime")
        XCTAssertEqual(KillTrigger.emergencyPromotion.rawValue, "emergencyPromotion")
        XCTAssertEqual(KillTrigger.manual.rawValue, "manual")
    }

    func testKillTriggerDecodesFromKnownRawString() throws {
        let jsonString = "\"emergencyPromotion\""
        let data = jsonString.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(KillTrigger.self, from: data)
        XCTAssertEqual(decoded, .emergencyPromotion)
    }

    // MARK: - KillReason round-trip

    func testKillReasonRoundTripJSON() throws {
        let id = UUID()
        let original = KillReason(
            ruleID: id,
            rulePattern: "vitest.*forks",
            trigger: .maxRuntime,
            thresholdValue: 1800,
            actualValue: 1825,
            unit: "s"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(KillReason.self, from: data)
        XCTAssertEqual(decoded.ruleID, original.ruleID)
        XCTAssertEqual(decoded.rulePattern, original.rulePattern)
        XCTAssertEqual(decoded.trigger, original.trigger)
        XCTAssertEqual(decoded.thresholdValue, 1800)
        XCTAssertEqual(decoded.actualValue, 1825)
        XCTAssertEqual(decoded.unit, "s")
    }

    func testKillReasonRoundTripCPUTrigger() throws {
        let original = KillReason(
            ruleID: UUID(),
            rulePattern: "tsc",
            trigger: .maxCPUPercent,
            thresholdValue: 300,
            actualValue: 350,
            unit: "%"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(KillReason.self, from: data)
        XCTAssertEqual(decoded.trigger, .maxCPUPercent)
        XCTAssertEqual(decoded.thresholdValue, 300)
        XCTAssertEqual(decoded.actualValue, 350)
        XCTAssertEqual(decoded.unit, "%")
    }

    func testKillReasonRoundTripRSSTrigger() throws {
        let original = KillReason(
            ruleID: UUID(),
            rulePattern: "next.*build",
            trigger: .maxRSSMB,
            thresholdValue: 3000,
            actualValue: 3200,
            unit: "MB"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(KillReason.self, from: data)
        XCTAssertEqual(decoded.trigger, .maxRSSMB)
        XCTAssertEqual(decoded.unit, "MB")
    }

    func testKillReasonRoundTripOrphanTimeout() throws {
        let original = KillReason(
            ruleID: UUID(),
            rulePattern: "mcp",
            trigger: .orphanTimeout,
            thresholdValue: 14400,
            actualValue: 15000,
            unit: "s"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(KillReason.self, from: data)
        XCTAssertEqual(decoded.trigger, .orphanTimeout)
    }

    func testKillReasonRoundTripEmergencyPromotion() throws {
        let original = KillReason(
            ruleID: UUID(),
            rulePattern: "vitest",
            trigger: .emergencyPromotion,
            thresholdValue: 0,
            actualValue: 0,
            unit: ""
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(KillReason.self, from: data)
        XCTAssertEqual(decoded.trigger, .emergencyPromotion)
    }

    func testKillReasonRoundTripManualTrigger() throws {
        let original = KillReason(
            ruleID: nil,
            rulePattern: nil,
            trigger: .manual,
            thresholdValue: 0,
            actualValue: 0,
            unit: ""
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(KillReason.self, from: data)
        XCTAssertEqual(decoded.trigger, .manual)
        XCTAssertNil(decoded.ruleID)
        XCTAssertNil(decoded.rulePattern)
    }

    // MARK: - Nil ruleID / rulePattern (catch-all scenario)

    func testKillReasonWithNilRuleIDCatchAll() throws {
        let reason = KillReason(
            ruleID: nil,
            rulePattern: nil,
            trigger: .catchAllMaxRuntime,
            thresholdValue: 7200,
            actualValue: 7500,
            unit: "s"
        )
        let data = try JSONEncoder().encode(reason)
        let decoded = try JSONDecoder().decode(KillReason.self, from: data)
        XCTAssertNil(decoded.ruleID)
        XCTAssertNil(decoded.rulePattern)
        XCTAssertEqual(decoded.trigger, .catchAllMaxRuntime)
        XCTAssertEqual(decoded.thresholdValue, 7200)
        XCTAssertEqual(decoded.actualValue, 7500)
    }

    // MARK: - SessionLog integration

    func testSessionLogAcceptsKillReason() {
        let log = SessionLog(capacity: 10)
        let reason = KillReason(
            ruleID: UUID(),
            rulePattern: "next.*build",
            trigger: .maxRSSMB,
            thresholdValue: 4096,
            actualValue: 5120,
            unit: "MB"
        )
        log.log(.kill, "Auto-killed next build", pid: 1234, processName: "next", killReason: reason)
        XCTAssertEqual(log.entries.count, 1)
        XCTAssertEqual(log.entries.first?.killReason?.trigger, .maxRSSMB)
        XCTAssertEqual(log.entries.first?.killReason?.actualValue, 5120)
        XCTAssertEqual(log.entries.first?.killReason?.unit, "MB")
    }

    func testSessionLogWithoutKillReasonStoresNil() {
        let log = SessionLog(capacity: 10)
        log.log(.throttle, "Throttled process", pid: 99, processName: "bash")
        XCTAssertEqual(log.entries.count, 1)
        XCTAssertNil(log.entries.first?.killReason)
    }

    func testSessionLogAllSevenTriggersAccepted() {
        let log = SessionLog(capacity: 20)
        let triggers: [KillTrigger] = [
            .maxRuntime, .maxCPUPercent, .maxRSSMB,
            .orphanTimeout, .catchAllMaxRuntime,
            .emergencyPromotion, .manual
        ]
        for (index, trigger) in triggers.enumerated() {
            let reason = KillReason(
                ruleID: UUID(),
                rulePattern: "process\(index)",
                trigger: trigger,
                thresholdValue: 100,
                actualValue: 110,
                unit: "s"
            )
            log.log(.kill, "killed by \(trigger.rawValue)", pid: Int32(1000 + index), killReason: reason)
        }
        XCTAssertEqual(log.entries.count, 7)
        let storedTriggers = log.entries.compactMap { $0.killReason?.trigger }
        XCTAssertEqual(storedTriggers.count, 7)
        XCTAssertTrue(storedTriggers.contains(.maxRuntime))
        XCTAssertTrue(storedTriggers.contains(.maxCPUPercent))
        XCTAssertTrue(storedTriggers.contains(.maxRSSMB))
        XCTAssertTrue(storedTriggers.contains(.orphanTimeout))
        XCTAssertTrue(storedTriggers.contains(.catchAllMaxRuntime))
        XCTAssertTrue(storedTriggers.contains(.emergencyPromotion))
        XCTAssertTrue(storedTriggers.contains(.manual))
    }

    func testSessionLogKillReasonPreservedAfterCapacityRollover() {
        let log = SessionLog(capacity: 3)
        // Fill past capacity
        for i in 0..<5 {
            let reason = KillReason(
                ruleID: nil,
                rulePattern: nil,
                trigger: .manual,
                thresholdValue: 0,
                actualValue: Double(i),
                unit: ""
            )
            log.log(.kill, "entry \(i)", killReason: reason)
        }
        XCTAssertEqual(log.entries.count, 3)
        // Last 3 entries (indices 2,3,4) should be retained
        XCTAssertEqual(log.entries.first?.killReason?.actualValue, 2)
        XCTAssertEqual(log.entries.last?.killReason?.actualValue, 4)
    }

    // MARK: - Sendable conformance (compile-time check)

    func testSessionLogEntryIsSendableSafe() {
        // Compile-time check: SessionLogEntry must stay Sendable even with KillReason field
        let _: any Sendable = SessionLogEntry(
            id: UUID(),
            timestamp: Date(),
            kind: .kill,
            message: "x",
            pid: Int32(1),
            processName: nil,
            killReason: KillReason(
                ruleID: nil,
                rulePattern: nil,
                trigger: .manual,
                thresholdValue: 0,
                actualValue: 0,
                unit: ""
            )
        )
    }

    func testKillReasonIsSendable() {
        let _: any Sendable = KillReason(
            ruleID: UUID(),
            rulePattern: "vitest",
            trigger: .maxCPUPercent,
            thresholdValue: 300,
            actualValue: 400,
            unit: "%"
        )
    }

    // MARK: - KillReason equality (Hashable)

    func testKillReasonHashableEquality() {
        let id = UUID()
        let a = KillReason(ruleID: id, rulePattern: "vitest", trigger: .maxRuntime, thresholdValue: 1800, actualValue: 1825, unit: "s")
        let b = KillReason(ruleID: id, rulePattern: "vitest", trigger: .maxRuntime, thresholdValue: 1800, actualValue: 1825, unit: "s")
        XCTAssertEqual(a, b)
    }

    func testKillReasonInequalityOnDifferentTrigger() {
        let id = UUID()
        let a = KillReason(ruleID: id, rulePattern: "vitest", trigger: .maxRuntime, thresholdValue: 1800, actualValue: 1825, unit: "s")
        let b = KillReason(ruleID: id, rulePattern: "vitest", trigger: .maxCPUPercent, thresholdValue: 1800, actualValue: 1825, unit: "s")
        XCTAssertNotEqual(a, b)
    }

    func testKillReasonUsableInSet() {
        let reason1 = KillReason(ruleID: nil, rulePattern: nil, trigger: .maxRuntime, thresholdValue: 100, actualValue: 150, unit: "s")
        let reason2 = KillReason(ruleID: nil, rulePattern: nil, trigger: .maxCPUPercent, thresholdValue: 80, actualValue: 95, unit: "%")
        let set: Set<KillReason> = [reason1, reason2]
        XCTAssertEqual(set.count, 2)
    }
}
