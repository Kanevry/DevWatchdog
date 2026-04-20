import XCTest
import Foundation
@testable import DevWatchdog

final class ProcessKillerThrottleTests: XCTestCase {

    // MARK: - ESRCH / non-existent PID

    func testThrottleReturnsAlreadyDeadForNonExistentPID() {
        let killer = ProcessKiller()
        // PID 999_999 should almost certainly not exist on a dev machine.
        let result = killer.throttle(pid: 999_999)
        XCTAssertEqual(result, .alreadyDead, "throttling a non-existent PID should return .alreadyDead")
    }

    func testResumeReturnsAlreadyDeadForNonExistentPID() {
        let killer = ProcessKiller()
        let result = killer.resume(pid: 999_999)
        XCTAssertEqual(result, .alreadyDead, "resuming a non-existent PID should return .alreadyDead")
    }

    // MARK: - PSParser state mapping

    func testPSParserParsesStoppedState() {
        let line = "  testuser  4242     1  0.0   1.0  2048 T 10:00 /usr/bin/node slow-script.js"
        let parsed = PSParser.parsePSLine(line)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.state, "T")
        XCTAssertEqual(ProcessState(psStateString: parsed?.state ?? ""), .stopped)
    }

    func testPSParserParsesRunningState() {
        let line = "  testuser  4242     1  25.0   1.0  2048 R 10:00 /usr/bin/node busy.js"
        let parsed = PSParser.parsePSLine(line)
        XCTAssertEqual(parsed?.state, "R")
        XCTAssertEqual(ProcessState(psStateString: parsed?.state ?? ""), .running)
    }

    func testPSParserParsesSleepingState() {
        // macOS often marks idle processes with modifiers, e.g. "S+" or "Ss".
        let line = "  testuser  4242     1  0.1   1.0  2048 Ss 10:00 /usr/bin/node idle.js"
        let parsed = PSParser.parsePSLine(line)
        XCTAssertEqual(parsed?.state, "Ss")
        XCTAssertEqual(ProcessState(psStateString: parsed?.state ?? ""), .running)
    }

    func testPSParserParsesZombieState() {
        let line = "  testuser  4242     1  0.0   0.0     0 Z 10:00 (defunct)"
        let parsed = PSParser.parsePSLine(line)
        XCTAssertEqual(parsed?.state, "Z")
        XCTAssertEqual(ProcessState(psStateString: parsed?.state ?? ""), .zombie)
    }

    func testProcessStateUnknownForEmpty() {
        XCTAssertEqual(ProcessState(psStateString: ""), .unknown)
    }

    func testProcessStateUnknownForGarbage() {
        XCTAssertEqual(ProcessState(psStateString: "?"), .unknown)
    }

    // MARK: - Integration: spawn a real child, throttle, resume, kill.
    //
    // This test shells out to `ps` to verify the state column. It may be
    // flaky or disallowed under tight sandboxes; skip gracefully in that case.

    func testThrottleAndResumeRealProcess() throws {
        #if os(macOS)
        // Allow CI / sandboxed runs to opt out explicitly.
        if ProcessInfo.processInfo.environment["DEVWATCHDOG_SKIP_INTEGRATION"] != nil {
            throw XCTSkip("Integration test skipped via DEVWATCHDOG_SKIP_INTEGRATION")
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sleep")
        proc.arguments = ["60"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice

        do {
            try proc.run()
        } catch {
            throw XCTSkip("Could not spawn child process in this sandbox: \(error)")
        }

        let pid = proc.processIdentifier
        addTeardownBlock {
            // Best-effort cleanup — SIGKILL so even stopped processes die.
            _ = Foundation.kill(pid, SIGKILL)
        }

        // Give the child a tick to fully start.
        usleep(100_000)

        let killer = ProcessKiller()
        XCTAssertTrue(killer.isProcessAlive(pid), "child process should be alive")

        // Throttle → should succeed.
        let throttleResult = killer.throttle(pid: pid)
        XCTAssertEqual(throttleResult, .success, "throttle should succeed on live child")

        // Give kernel a moment to reflect the state change in ps.
        usleep(200_000)

        let stateAfterThrottle = readPSState(pid: pid)
        if let s = stateAfterThrottle {
            XCTAssertTrue(s.uppercased().hasPrefix("T"),
                          "ps state should start with 'T' after SIGSTOP, got '\(s)'")
        } else {
            // If ps reporting is unavailable, at least verify the process still exists
            // (SIGSTOP'd processes are still signalable).
            XCTAssertTrue(killer.isProcessAlive(pid), "stopped process should still exist")
        }

        // Resume → should succeed and state should no longer be 'T'.
        let resumeResult = killer.resume(pid: pid)
        XCTAssertEqual(resumeResult, .success, "resume should succeed on stopped child")

        usleep(200_000)
        if let s = readPSState(pid: pid) {
            XCTAssertFalse(s.uppercased().hasPrefix("T"),
                           "ps state should not be 'T' after SIGCONT, got '\(s)'")
        }
        XCTAssertTrue(killer.isProcessAlive(pid), "child should still be alive after resume")

        // Cleanup via SIGKILL (avoids the 5-second SIGTERM grace in kill()).
        killer.forceKill(pid: pid)
        #else
        throw XCTSkip("Throttle integration test only runs on macOS")
        #endif
    }

    // MARK: - Helpers

    /// Shell out to `ps` once to read the state column for a specific PID.
    /// Returns nil if ps fails or the PID is not found.
    private func readPSState(pid: Int32) -> String? {
        let pipe = Pipe()
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-o", "state=", "-p", String(pid)]
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        guard let out = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
