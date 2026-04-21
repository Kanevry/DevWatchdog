import XCTest
@testable import DevWatchdog

final class PIDReuseGuardTests: XCTestCase {

    // MARK: - No-baseline: guard must not block

    func testKillWithZeroBaselineSucceeds() async throws {
        // Spawn /bin/sleep and kill it with no baseline (expectedStart = 0).
        // The PID-reuse guard must not block when expectedStart == 0.
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sleep")
        proc.arguments = ["30"]
        try proc.run()
        let pid = proc.processIdentifier

        // Allow the process to fully materialise in the kernel.
        try await Task.sleep(nanoseconds: 100_000_000) // 100 ms

        let killer = ProcessKiller()
        let result = killer.kill(pid: pid, expectedStart: 0, expectedComm: nil)

        // With no baseline the guard passes → SIGTERM is sent → success or alreadyDead both valid.
        switch result {
        case .success, .alreadyDead:
            break  // expected
        case .permissionDenied, .failed:
            XCTFail("Expected kill to succeed when no baseline is set; got \(result)")
        }

        // Cleanup: ensure no orphan is left behind.
        if proc.isRunning { proc.terminate() }
        proc.waitUntilExit()
    }

    func testKillWithMatchingBaselineSucceeds() async throws {
        // Capture a real baseline from a live /bin/sleep process and kill it.
        // The guard must pass when the baseline matches the running process.
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sleep")
        proc.arguments = ["30"]
        try proc.run()
        let pid = proc.processIdentifier

        try await Task.sleep(nanoseconds: 100_000_000) // 100 ms

        guard let info = ProcPIDInfo.lookup(pid: pid) else {
            proc.terminate()
            proc.waitUntilExit()
            throw XCTSkip("ProcPIDInfo.lookup returned nil for /bin/sleep — skipping")
        }

        let killer = ProcessKiller()
        let result = killer.kill(pid: pid, expectedStart: info.startTvSec, expectedComm: info.comm)

        switch result {
        case .success, .alreadyDead:
            break  // expected — guard matched, kill allowed
        case .permissionDenied, .failed:
            XCTFail("Expected kill to succeed with a matching baseline; got \(result)")
        }

        if proc.isRunning { proc.terminate() }
        proc.waitUntilExit()
    }

    // MARK: - Mismatched baseline: guard must trip

    func testKillWithMismatchedStartTimestampIsAborted() async throws {
        // Supply a wildly wrong start timestamp to simulate a PID-reuse scenario.
        // The guard must detect the mismatch and abort the kill.
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sleep")
        proc.arguments = ["30"]
        try proc.run()
        let pid = proc.processIdentifier

        try await Task.sleep(nanoseconds: 100_000_000) // 100 ms

        let killer = ProcessKiller()
        // startTvSec = 1 is epoch 1970-01-01 00:00:01 — impossible for a live test process.
        let result = killer.kill(pid: pid, expectedStart: 1, expectedComm: "sleep")

        // Guard must trip → kill is aborted → not .success
        if case .success = result {
            XCTFail("PID-reuse guard must abort the kill when startTvSec does not match; got success")
        }

        // Clean up the still-alive /bin/sleep.
        proc.terminate()
        proc.waitUntilExit()
    }

    func testKillWithMismatchedCommIsAborted() async throws {
        // Correct start timestamp but wrong comm — guard must still block.
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sleep")
        proc.arguments = ["30"]
        try proc.run()
        let pid = proc.processIdentifier

        try await Task.sleep(nanoseconds: 100_000_000) // 100 ms

        guard let info = ProcPIDInfo.lookup(pid: pid) else {
            proc.terminate()
            proc.waitUntilExit()
            throw XCTSkip("ProcPIDInfo.lookup returned nil for /bin/sleep — skipping")
        }

        let killer = ProcessKiller()
        // Right start time, but comm is completely wrong.
        let result = killer.kill(pid: pid, expectedStart: info.startTvSec, expectedComm: "definitely-not-sleep")

        if case .success = result {
            XCTFail("PID-reuse guard must abort the kill when comm does not match; got success")
        }

        proc.terminate()
        proc.waitUntilExit()
    }

    // MARK: - Dead PID with non-zero baseline

    func testKillOfDeadPIDWithBaselineIsAborted() async throws {
        // Let /usr/bin/true run and exit, then try to kill its (now-recycled) PID
        // with a non-zero baseline. The guard detects the process is gone → false → aborted.
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try proc.run()
        let pid = proc.processIdentifier
        proc.waitUntilExit() // process is dead by here

        // Small delay to ensure the kernel has reaped the PID entry.
        try await Task.sleep(nanoseconds: 50_000_000) // 50 ms

        let killer = ProcessKiller()
        // Non-zero baseline → guard calls lookup → process gone → returns false → kill aborted.
        let result = killer.kill(pid: pid, expectedStart: 999_999_999, expectedComm: "true")

        if case .success = result {
            XCTFail("Kill must be aborted when the PID is dead and baseline is non-zero; got success")
        }
    }

    // MARK: - KillResult equatability (sanity)

    func testKillResultSucceededEqualityCheck() {
        // Ensure the KillResult enum has the expected cases and supports Equatable.
        let a: KillResult = .success
        let b: KillResult = .success
        XCTAssertEqual(a, b)
    }

    func testKillResultFailedCarriesErrno() {
        let r: KillResult = .failed(errno: 1)
        if case .failed(let e) = r {
            XCTAssertEqual(e, 1)
        } else {
            XCTFail("Expected .failed(errno:) case")
        }
    }
}
