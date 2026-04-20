import XCTest
@testable import DevWatchdog

@MainActor
final class SessionLogTests: XCTestCase {

    // MARK: - Append / order

    func testAppendPreservesChronologicalOrder() {
        let log = SessionLog()
        log.log(.kill, "one")
        log.log(.throttle, "two")
        log.log(.resume, "three")

        XCTAssertEqual(log.entries.count, 3)
        XCTAssertEqual(log.entries.map(\.message), ["one", "two", "three"])
        XCTAssertEqual(log.entries.map(\.kind), [.kill, .throttle, .resume])
    }

    func testAppendCarriesPidAndProcessName() {
        let log = SessionLog()
        log.log(.kill, "zombie", pid: 4242, processName: "node")

        let entry = try? XCTUnwrap(log.entries.first)
        XCTAssertEqual(entry?.pid, 4242)
        XCTAssertEqual(entry?.processName, "node")
        XCTAssertEqual(entry?.kind, .kill)
    }

    // MARK: - Capacity / ring buffer

    func testCapacityLimitDropsOldestEntries() {
        let log = SessionLog(capacity: 10)

        for i in 0..<15 {
            log.log(.kill, "entry \(i)")
        }

        XCTAssertEqual(log.entries.count, 10, "must not exceed capacity")
        XCTAssertEqual(log.entries.first?.message, "entry 5", "oldest 5 should have been dropped")
        XCTAssertEqual(log.entries.last?.message, "entry 14")
    }

    func testAppendingExactlyCapacityKeepsAll() {
        let log = SessionLog(capacity: 5)
        for i in 0..<5 {
            log.log(.throttle, "e\(i)")
        }
        XCTAssertEqual(log.entries.count, 5)
        XCTAssertEqual(log.entries.first?.message, "e0")
    }

    func testDefaultCapacityIs500() {
        let log = SessionLog()
        XCTAssertEqual(log.capacity, 500)

        // Insert 501 — expect 500 retained, oldest ("0") dropped.
        for i in 0..<501 {
            log.log(.kill, "\(i)")
        }
        XCTAssertEqual(log.entries.count, 500)
        XCTAssertEqual(log.entries.first?.message, "1")
        XCTAssertEqual(log.entries.last?.message, "500")
    }

    // MARK: - Clear

    func testClearRemovesAllEntries() {
        let log = SessionLog()
        log.log(.kill, "a")
        log.log(.kill, "b")
        XCTAssertFalse(log.entries.isEmpty)

        log.clear()
        XCTAssertTrue(log.entries.isEmpty)
    }

    func testClearOnEmptyIsNoop() {
        let log = SessionLog()
        log.clear()
        XCTAssertTrue(log.entries.isEmpty)
    }

    // MARK: - Entry identity

    func testEntriesHaveUniqueIds() {
        let log = SessionLog()
        for _ in 0..<20 {
            log.log(.kill, "same message")
        }
        let ids = Set(log.entries.map(\.id))
        XCTAssertEqual(ids.count, 20, "every append must produce a unique id")
    }
}
