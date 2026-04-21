import XCTest
@testable import DevWatchdog

/// Unit tests for ``OrphanConfidence`` and the ``ProcessMonitor`` PPID-history
/// classifier.
///
/// The classifier distinguishes three shapes of PPID==1 processes:
/// - `.none` (not an orphan at all; PPID != 1)
/// - `.knownSinceFirstSeen` (first observation already under PID 1 — could
///   legitimately be a launchd-managed daemon, treat conservatively)
/// - `.reparented` (previous observation had a real parent, now PID 1 —
///   parent just died, fast-track to zombie)
@MainActor
final class OrphanConfidenceTests: XCTestCase {

    // MARK: - Enum plumbing

    func testOrphanConfidenceRawValuesStable() {
        // Codable stability: if we ever persist SessionLog entries that embed
        // this enum, changing these strings would break backward compatibility.
        XCTAssertEqual(OrphanConfidence.none.rawValue, "none")
        XCTAssertEqual(OrphanConfidence.knownSinceFirstSeen.rawValue, "knownSinceFirstSeen")
        XCTAssertEqual(OrphanConfidence.reparented.rawValue, "reparented")
    }

    // MARK: - DevProcess.withOrphanConfidence

    func testDefaultOrphanConfidenceIsNone() {
        let p = makeProcess(pid: 100, ppid: 1, isOrphan: true)
        XCTAssertEqual(p.orphanConfidence, .none)
    }

    func testWithOrphanConfidenceProducesCopy() {
        let base = makeProcess(pid: 100, ppid: 1, isOrphan: true)
        let enriched = base.withOrphanConfidence(.reparented)
        XCTAssertEqual(enriched.orphanConfidence, .reparented)
        XCTAssertEqual(enriched.id, base.id)
        XCTAssertEqual(enriched.parentPID, base.parentPID)
        XCTAssertEqual(enriched.isOrphan, base.isOrphan)
        XCTAssertEqual(enriched.command, base.command)
    }

    // MARK: - ProcessMonitor.classifyOrphanConfidence

    func testClassifyNonOrphan() {
        let monitor = makeMonitor()
        // Any PPID != 1 → `.none` regardless of history.
        XCTAssertEqual(monitor.classifyOrphanConfidence(pid: 42, currentPPID: 200), .none)
    }

    func testClassifyOrphanWithNoPriorHistory() {
        let monitor = makeMonitor()
        // First observation PPID == 1 → conservative "knownSinceFirstSeen".
        XCTAssertEqual(
            monitor.classifyOrphanConfidence(pid: 42, currentPPID: 1),
            .knownSinceFirstSeen
        )
    }

    func testClassifyReparentedFromRealParent() {
        let monitor = makeMonitor()
        // Prior PPID was 12345, now it's 1 → real reparenting, fast-track.
        monitor._testing_setPPIDHistory([42: 12345])
        XCTAssertEqual(
            monitor.classifyOrphanConfidence(pid: 42, currentPPID: 1),
            .reparented
        )
    }

    func testClassifyStableUnderLaunchd() {
        let monitor = makeMonitor()
        // Prior PPID was already 1 — long-time launchd resident.
        monitor._testing_setPPIDHistory([42: 1])
        XCTAssertEqual(
            monitor.classifyOrphanConfidence(pid: 42, currentPPID: 1),
            .knownSinceFirstSeen
        )
    }

    func testClassifyTransitionNotToPID1StaysNone() {
        let monitor = makeMonitor()
        // Prior parent died, but process is re-adopted by a non-launchd
        // process (rare but possible). Still not an orphan.
        monitor._testing_setPPIDHistory([42: 12345])
        XCTAssertEqual(
            monitor.classifyOrphanConfidence(pid: 42, currentPPID: 99),
            .none
        )
    }

    // MARK: - Helpers

    private func makeMonitor() -> ProcessMonitor {
        ProcessMonitor(
            pressureSource: FakeSystemPressureSource(),
            terminator: FakeProcessTerminator()
        )
    }

    private func makeProcess(pid: Int32, ppid: Int32, isOrphan: Bool) -> DevProcess {
        DevProcess(
            id: pid, user: "u",
            cpuPercent: 1, memPercent: 1, rss: 1024,
            command: "node fixture.js",
            startTime: Date(timeIntervalSince1970: 0),
            parentPID: ppid, isOrphan: isOrphan,
            state: .running,
            startTimestamp: 0
        )
    }
}
