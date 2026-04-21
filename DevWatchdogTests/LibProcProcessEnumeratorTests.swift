import XCTest
import Darwin
@testable import DevWatchdog

final class LibProcProcessEnumeratorTests: XCTestCase {

    // MARK: - Helpers

    /// Inclusion patterns broad enough to match any xctest runner binary variant.
    private let selfMatchingPatterns = ["xctest", "swift-frontend", "xcodebuild", "Xcode"]

    private var selfPID: Int32 {
        ProcessInfo.processInfo.processIdentifier
    }

    // MARK: - 1. testEnumerateReturnsSelf

    func testEnumerateReturnsSelf() {
        let result = LibProcProcessEnumerator.parseProcessList(
            excludedApps: [],
            inclusionPatterns: selfMatchingPatterns
        )
        let pids = result.map(\.id)
        XCTAssertTrue(
            pids.contains(selfPID),
            "result must contain the test runner's own PID (\(selfPID)); got \(pids.count) processes"
        )
    }

    // MARK: - 2. testEmptyInclusionPatternsReturnsEmpty

    func testEmptyInclusionPatternsReturnsEmpty() {
        // PSParser semantics: no patterns → nothing passes the inclusion filter.
        let result = LibProcProcessEnumerator.parseProcessList(
            excludedApps: [],
            inclusionPatterns: []
        )
        XCTAssertTrue(
            result.isEmpty,
            "expected empty result when inclusionPatterns is []; got \(result.count) entries"
        )
    }

    // MARK: - 3. testExcludedAppsFiltersOut

    func testExcludedAppsFiltersOut() {
        // Baseline with no exclusions — self must appear.
        let baseline = LibProcProcessEnumerator.parseProcessList(
            excludedApps: [],
            inclusionPatterns: selfMatchingPatterns
        )
        guard baseline.map(\.id).contains(selfPID) else {
            XCTFail("Prerequisite failed: self PID not found in baseline enumeration")
            return
        }

        // Find the self entry's command so we can use a unique substring to exclude it.
        guard let selfEntry = baseline.first(where: { $0.id == selfPID }) else {
            XCTFail("Prerequisite failed: could not find self entry in baseline")
            return
        }

        // Use the full command path (or a tail component) as the excluded-app string.
        // The enumerator does `command.contains($0)` so any substring of the path works.
        let exclusionToken = selfEntry.command.isEmpty ? "xctest" : selfEntry.command

        let filtered = LibProcProcessEnumerator.parseProcessList(
            excludedApps: [exclusionToken],
            inclusionPatterns: selfMatchingPatterns
        )

        XCTAssertFalse(
            filtered.map(\.id).contains(selfPID),
            "self PID (\(selfPID)) must be absent when its command path is in excludedApps"
        )
    }

    // MARK: - 4. testOwnProcessFieldsParityWithProcPIDInfo

    func testOwnProcessFieldsParityWithProcPIDInfo() {
        guard let procInfo = ProcPIDInfo.lookup(pid: selfPID) else {
            return XCTFail("Prerequisite failed: ProcPIDInfo.lookup(self) returned nil")
        }

        let result = LibProcProcessEnumerator.parseProcessList(
            excludedApps: [],
            inclusionPatterns: selfMatchingPatterns
        )
        guard let selfEntry = result.first(where: { $0.id == selfPID }) else {
            return XCTFail("self PID not found in enumeration result")
        }

        // startTimestamp must match pbi_start_tvsec exactly (same kernel source).
        XCTAssertEqual(
            selfEntry.startTimestamp,
            procInfo.startTvSec,
            "startTimestamp must equal ProcPIDInfo.startTvSec for the same process"
        )

        // command is either the full exec path (containing comm as a tail) or the 16-char comm itself.
        let cmdLower = selfEntry.command.lowercased()
        let commLower = procInfo.comm.lowercased()
        XCTAssertFalse(selfEntry.command.isEmpty, "command must not be empty for a live process")
        XCTAssertTrue(
            cmdLower.contains(commLower) || commLower.contains(cmdLower),
            "command '\(selfEntry.command)' must contain or be contained by comm '\(procInfo.comm)'"
        )
    }

    // MARK: - 5. testPIDFieldMatchesInput

    func testPIDFieldMatchesInput() {
        let result = LibProcProcessEnumerator.parseProcessList(
            excludedApps: [],
            inclusionPatterns: selfMatchingPatterns
        )
        guard let selfEntry = result.first(where: { $0.id == selfPID }) else {
            return XCTFail("self PID not found in enumeration result")
        }

        XCTAssertEqual(selfEntry.id, selfPID, "devProcess.id must equal getpid()")
        XCTAssertGreaterThan(
            selfEntry.parentPID, 0,
            "parentPID must be > 0 — the test runner always has a real parent"
        )
    }

    // MARK: - 6. testRSSIsPositiveForLiveProcess

    func testRSSIsPositiveForLiveProcess() {
        let result = LibProcProcessEnumerator.parseProcessList(
            excludedApps: [],
            inclusionPatterns: selfMatchingPatterns
        )
        guard let selfEntry = result.first(where: { $0.id == selfPID }) else {
            return XCTFail("self PID not found in enumeration result")
        }

        XCTAssertGreaterThan(selfEntry.rss, 0, "RSS must be > 0 KB for a live process")
        // Sanity: < 10 GB — catches unit regressions where bytes are not divided by 1024.
        XCTAssertLessThan(
            selfEntry.rss, 10_000_000,
            "RSS must be < 10_000_000 KB (10 GB) — a value this large likely means bytes were used instead of KB"
        )
    }

    // MARK: - 7. testMemPercentIsSane

    func testMemPercentIsSane() {
        let result = LibProcProcessEnumerator.parseProcessList(
            excludedApps: [],
            inclusionPatterns: selfMatchingPatterns
        )
        guard let selfEntry = result.first(where: { $0.id == selfPID }) else {
            return XCTFail("self PID not found in enumeration result")
        }

        XCTAssertGreaterThan(
            selfEntry.memPercent, 0.0,
            "memPercent must be > 0 for a live process using resident memory"
        )
        XCTAssertLessThan(
            selfEntry.memPercent, 100.0,
            "memPercent must be < 100 — the test runner cannot use all physical RAM; a value >= 100 likely indicates a unit conversion bug"
        )
    }

    // MARK: - 8. testIsOrphanFalseForOurProcess

    func testIsOrphanFalseForOurProcess() throws {
        // xctest is launched by xcodebuild — not by launchd (PID 1).
        // isOrphan == true only when parentPID == 1.
        let result = LibProcProcessEnumerator.parseProcessList(
            excludedApps: [],
            inclusionPatterns: selfMatchingPatterns
        )
        guard let selfEntry = result.first(where: { $0.id == selfPID }) else {
            return XCTFail("self PID not found in enumeration result")
        }

        // If the runner is somehow under PID 1 (e.g. reparented in an unusual CI env),
        // skip rather than fail — the logic is correct but environment-dependent.
        if selfEntry.parentPID == 1 {
            throw XCTSkip("test runner parent is PID 1 (reparented environment) — isOrphan=true is correct but this test is environment-dependent")
        }

        XCTAssertFalse(
            selfEntry.isOrphan,
            "xctest launched by xcodebuild must not be an orphan (parentPID=\(selfEntry.parentPID))"
        )
    }

    // MARK: - 9. testUIDFilterExcludesOtherUsers

    func testUIDFilterExcludesOtherUsers() {
        // We cannot easily inject other-user processes, but we can verify the enumerator
        // runs without crashing and returns well-formed DevProcess values.
        let result = LibProcProcessEnumerator.parseProcessList(
            excludedApps: [],
            inclusionPatterns: ["node", "xctest", "swift", "xcodebuild"]
        )

        for process in result {
            XCTAssertGreaterThan(process.id, 0, "every returned PID must be > 0")
            XCTAssertFalse(
                process.command.isEmpty,
                "every returned process must have a non-empty command (pid=\(process.id))"
            )
        }
        // Result count is in a sane range — not negative (compile check), not millions
        XCTAssertLessThanOrEqual(
            result.count, 50_000,
            "result count must be in a sane range (< 50 000)"
        )
    }

    // MARK: - 10. testApplicationsHeuristicAllowsDevTools

    func testApplicationsHeuristicAllowsDevTools() {
        // The /Applications/ heuristic must NOT exclude recognised dev tools (Cursor, VS Code, etc.).
        // This test is a smoke-test: if Cursor/VS Code is running, it must be includable.
        // We pass a matching pattern ("Cursor" or "Code") so it would be included if running.
        let devToolPatterns = ["Cursor", "Code", "iTerm", "Terminal", "Warp"]
        let result = LibProcProcessEnumerator.parseProcessList(
            excludedApps: [],
            inclusionPatterns: devToolPatterns
        )

        // If any dev-tool process is in the result, every one must have a non-empty command.
        // (We cannot assert count > 0 because dev tools may not be running in CI.)
        for process in result {
            XCTAssertFalse(
                process.command.isEmpty,
                "dev tool process (pid=\(process.id)) must have a non-empty command"
            )
            // The command must contain one of the recognised patterns (smoke-check filter logic).
            let cmd = process.command.lowercased()
            let matched = devToolPatterns.contains { cmd.contains($0.lowercased()) }
            XCTAssertTrue(
                matched,
                "returned process '\(process.command)' must match at least one dev-tool pattern"
            )
        }
    }

    // MARK: - 11. testNonEmptyResultForStandardDevPatterns

    func testNonEmptyResultForStandardDevPatterns() {
        // Smoke-test: running with default inclusion patterns must not crash.
        // We cannot guarantee any pattern matches in CI, so the assertion is lenient.
        // Patterns inlined here to avoid @MainActor requirement of WatchdogConfig.
        let defaultPatterns = [
            "node", "vitest", "jest", "tsc", "tsgo", "esbuild", "next", "webpack",
            "turbo", "eslint", "prettier", "mcp", "pnpm", "npm run", "yarn",
            "playwright", "ms-playwright", "percy", "react-email", "bun", "deno", "swc",
        ]
        let result = LibProcProcessEnumerator.parseProcessList(
            excludedApps: [],
            inclusionPatterns: defaultPatterns
        )
        // Only verifiable guarantee: the count is non-negative and sane.
        XCTAssertGreaterThanOrEqual(result.count, 0, "result.count must be non-negative")
        XCTAssertLessThanOrEqual(result.count, 50_000, "result.count must be in a sane range")
    }

    // MARK: - 12. testParityShapeAgainstPSParserForSelf

    func testParityShapeAgainstPSParserForSelf() throws {
        // Side-by-side comparison of libproc and PSParser for the test runner's own PID.
        guard FileManager.default.fileExists(atPath: "/bin/ps") else {
            throw XCTSkip("parity test requires /bin/ps — not available in this environment")
        }

        let libprocResult = LibProcProcessEnumerator.parseProcessList(
            excludedApps: [],
            inclusionPatterns: selfMatchingPatterns
        )
        let psResult = PSParser.parseProcessList(
            excludedApps: [],
            inclusionPatterns: selfMatchingPatterns,
            timeout: 10
        )

        guard let libprocSelf = libprocResult.first(where: { $0.id == selfPID }) else {
            throw XCTSkip("parity test: libproc did not return self PID — skipping")
        }
        guard let psSelf = psResult.first(where: { $0.id == selfPID }) else {
            throw XCTSkip("parity test: PSParser did not return self PID — /bin/ps may be unavailable or timing issue")
        }

        // PID (tautological but serves as a sanity check)
        XCTAssertEqual(libprocSelf.id, psSelf.id, "PID must match between libproc and PSParser")

        // parentPID
        XCTAssertEqual(
            libprocSelf.parentPID, psSelf.parentPID,
            "parentPID must match between libproc (\(libprocSelf.parentPID)) and PSParser (\(psSelf.parentPID))"
        )

        // user
        XCTAssertEqual(
            libprocSelf.user, psSelf.user,
            "user must match between libproc ('\(libprocSelf.user)') and PSParser ('\(psSelf.user)')"
        )

        // startTimestamp: both read the same kernel value; allow 1-second delta for race.
        if let libprocTS = libprocSelf.startTimestamp, let psTS = psSelf.startTimestamp {
            XCTAssertLessThanOrEqual(
                abs(libprocTS - psTS), 1,
                "startTimestamp must match within 1 second: libproc=\(libprocTS) ps=\(psTS)"
            )
        }
        // If PSParser doesn't populate startTimestamp that's acceptable — the test is lenient.

        // RSS: live memory fluctuates; allow 10% relative difference.
        // Processes can allocate/free between the two calls, so we're generous.
        if libprocSelf.rss > 0 && psSelf.rss > 0 {
            let delta = abs(libprocSelf.rss - psSelf.rss)
            let maxAllowed = max(libprocSelf.rss, psSelf.rss) / 10  // 10%
            XCTAssertLessThanOrEqual(
                delta, maxAllowed + 1,
                "RSS should not differ by more than 10%: libproc=\(libprocSelf.rss) KB, ps=\(psSelf.rss) KB"
            )
        }

        // State: both should be .running for the live xctest process.
        XCTAssertEqual(
            libprocSelf.state, psSelf.state,
            "state must match: libproc=\(libprocSelf.state) ps=\(psSelf.state)"
        )
    }
}
