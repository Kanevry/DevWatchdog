import XCTest
@testable import DevWatchdog

final class ProcPIDInfoTests: XCTestCase {

    func testLookupSelfReturnsNonNilInfo() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let info = ProcPIDInfo.lookup(pid: pid)
        XCTAssertNotNil(info, "lookup(self) must return a valid Info struct")
        XCTAssertGreaterThan(info!.startTvSec, 0, "startTvSec must be a positive Unix timestamp")
        XCTAssertFalse(info!.comm.isEmpty, "comm must not be empty for a running process")
    }

    func testLookupNonExistentPIDReturnsNil() {
        // PID 2147483646 is near Int32.max and almost certainly not in use.
        let info = ProcPIDInfo.lookup(pid: 2147483646)
        XCTAssertNil(info, "lookup of a non-existent PID must return nil")
    }

    func testVerifyIdentityMatchesCurrentProcess() {
        let pid = ProcessInfo.processInfo.processIdentifier
        guard let info = ProcPIDInfo.lookup(pid: pid) else {
            return XCTFail("Prerequisite failed: lookup(self) returned nil")
        }
        XCTAssertTrue(
            ProcPIDInfo.verifyIdentity(pid: pid, expectedStart: info.startTvSec, expectedComm: info.comm),
            "verifyIdentity must return true when start + comm match the live process"
        )
    }

    func testVerifyIdentityStartTvSecMismatchReturnsFalse() {
        let pid = ProcessInfo.processInfo.processIdentifier
        guard let info = ProcPIDInfo.lookup(pid: pid) else {
            return XCTFail("Prerequisite failed: lookup(self) returned nil")
        }
        // Simulate a wrong start timestamp — the process looks like a different one (PID reuse).
        XCTAssertFalse(
            ProcPIDInfo.verifyIdentity(pid: pid, expectedStart: info.startTvSec + 1000, expectedComm: info.comm),
            "verifyIdentity must return false when startTvSec does not match"
        )
    }

    func testVerifyIdentityZeroBaselineReturnsTrue() {
        // expectedStart == 0 means we never captured a baseline → must NOT block the kill.
        let pid = ProcessInfo.processInfo.processIdentifier
        XCTAssertTrue(
            ProcPIDInfo.verifyIdentity(pid: pid, expectedStart: 0, expectedComm: nil),
            "verifyIdentity must return true when expectedStart is 0 (no baseline captured)"
        )
    }

    func testVerifyIdentityZeroBaselineWithCommReturnsTrue() {
        // Even if a comm is supplied, a zero start timestamp skips all verification.
        let pid = ProcessInfo.processInfo.processIdentifier
        XCTAssertTrue(
            ProcPIDInfo.verifyIdentity(pid: pid, expectedStart: 0, expectedComm: "anything"),
            "verifyIdentity must return true when expectedStart is 0, regardless of comm"
        )
    }

    func testVerifyIdentityProcessGoneReturnsFalse() {
        // Non-existent PID with a non-zero baseline → process is gone → abort kill.
        XCTAssertFalse(
            ProcPIDInfo.verifyIdentity(pid: 2147483646, expectedStart: 12345, expectedComm: nil),
            "verifyIdentity must return false when the process does not exist and baseline is non-zero"
        )
    }

    func testVerifyIdentityNilCommSkipsCommCheck() {
        // When expectedComm is nil the comm field must not cause a mismatch.
        let pid = ProcessInfo.processInfo.processIdentifier
        guard let info = ProcPIDInfo.lookup(pid: pid) else {
            return XCTFail("Prerequisite failed: lookup(self) returned nil")
        }
        XCTAssertTrue(
            ProcPIDInfo.verifyIdentity(pid: pid, expectedStart: info.startTvSec, expectedComm: nil),
            "verifyIdentity must return true when expectedComm is nil (comm check skipped)"
        )
    }

    func testVerifyIdentityEmptyCommSkipsCommCheck() {
        // Empty string comm is treated equivalently to nil — no comm comparison.
        let pid = ProcessInfo.processInfo.processIdentifier
        guard let info = ProcPIDInfo.lookup(pid: pid) else {
            return XCTFail("Prerequisite failed: lookup(self) returned nil")
        }
        XCTAssertTrue(
            ProcPIDInfo.verifyIdentity(pid: pid, expectedStart: info.startTvSec, expectedComm: ""),
            "verifyIdentity must return true when expectedComm is empty (comm check skipped)"
        )
    }

    func testLookupInfoIsHashable() {
        let pid = ProcessInfo.processInfo.processIdentifier
        guard let a = ProcPIDInfo.lookup(pid: pid),
              let b = ProcPIDInfo.lookup(pid: pid) else {
            return XCTFail("lookup(self) returned nil")
        }
        // Two lookups of the same live process must be equal and hash identically.
        XCTAssertEqual(a, b, "Two consecutive lookups of the same PID must produce equal Info values")
        XCTAssertEqual(a.hashValue, b.hashValue, "Equal Info values must have equal hash values")
    }
}
