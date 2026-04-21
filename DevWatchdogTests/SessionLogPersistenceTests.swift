import XCTest
@testable import DevWatchdog

/// Round-trip tests for ``SessionLogPersistence``.
///
/// We avoid stubbing the filesystem — these tests use an isolated actor
/// backed by a temporary directory, then exercise the real API. The tests
/// are small and fast because each spins up a single-file JSONL stream.
final class SessionLogPersistenceTests: XCTestCase {

    /// Unique per-test temp directory — never touches the user's Application Support.
    private func makeTempPersistence() -> (SessionLogPersistence, URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: "DevWatchdogTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let persistence = SessionLogPersistence(retentionDays: 14, directoryURL: tmp)
        return (persistence, tmp)
    }

    override func tearDown() async throws {
        try await super.tearDown()
    }

    func testAppendAndReadRoundTrip() async throws {
        let (persistence, tmp) = makeTempPersistence()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let entry = SessionLogEntry(
            kind: .kill,
            message: "test kill",
            pid: 4242,
            processName: "vitest"
        )

        await persistence.append(entry)
        let recent = await persistence.recent(days: 1)

        let found = recent.first(where: { $0.id == entry.id })
        XCTAssertNotNil(found, "appended entry should be retrievable via recent(days:)")
        XCTAssertEqual(found?.pid, 4242)
        XCTAssertEqual(found?.processName, "vitest")
        XCTAssertEqual(found?.kind, .kill)
    }

    func testMultipleEntriesAllRetrievable() async throws {
        let (persistence, tmp) = makeTempPersistence()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let e1 = SessionLogEntry(kind: .kill, message: "a", pid: 1, processName: "a")
        let e2 = SessionLogEntry(kind: .throttle, message: "b", pid: 2, processName: "b")
        let e3 = SessionLogEntry(kind: .resume, message: "c", pid: 3, processName: "c")
        await persistence.append(e1)
        await persistence.append(e2)
        await persistence.append(e3)

        let recent = await persistence.recent(days: 1)
        let ids = Set(recent.map(\.id))
        XCTAssertTrue(ids.contains(e1.id))
        XCTAssertTrue(ids.contains(e2.id))
        XCTAssertTrue(ids.contains(e3.id))
    }

    func testCodableKillReason() async throws {
        let reason = KillReason(
            ruleID: UUID(),
            rulePattern: "rolldown",
            trigger: .maxCPUPercent,
            thresholdValue: 50,
            actualValue: 121,
            unit: "%"
        )
        let entry = SessionLogEntry(
            kind: .kill,
            message: "hard kill",
            pid: 99,
            processName: "rolldown",
            killReason: reason
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try encoder.encode(entry)
        let round = try decoder.decode(SessionLogEntry.self, from: data)
        XCTAssertEqual(round.killReason?.trigger, .maxCPUPercent)
        XCTAssertEqual(round.killReason?.actualValue, 121)
        XCTAssertEqual(round.killReason?.rulePattern, "rolldown")
    }
}
