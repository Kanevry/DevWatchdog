import XCTest
@testable import DevWatchdog

final class ProcPIDInfoCwdTests: XCTestCase {

    func test_cwd_ofSelf_returnsNonEmptyPath() {
        let pid = ProcessInfo.processInfo.processIdentifier
        guard let path = ProcPIDInfo.cwd(pid: pid) else {
            return XCTFail("cwd(self) must return a non-nil path for the running test process")
        }
        XCTAssertFalse(path.isEmpty, "cwd must not be an empty string")
        XCTAssertTrue(path.hasPrefix("/"), "cwd must be an absolute path starting with '/'")
    }

    func test_cwd_ofNonexistentPID_returnsNil() {
        // PID 999_999 is well beyond the macOS PID range limit (99_999 by default) and
        // is almost certainly not in use.
        let result = ProcPIDInfo.cwd(pid: 999_999)
        XCTAssertNil(result, "cwd of a non-existent PID must return nil")
    }

    func test_cwd_ofLaunchd_returnsValue_orNilIfEPERM() {
        // PID 1 is launchd. Two outcomes are both acceptable:
        //   1. Returns a non-empty absolute path (running as root or if the kernel allows it).
        //   2. Returns nil (EPERM — permission denied for sandboxed / non-root processes).
        // We simply assert that we don't get an empty string — either nil or a real path.
        let result = ProcPIDInfo.cwd(pid: 1)
        if let path = result {
            XCTAssertFalse(path.isEmpty, "If a path is returned for PID 1 it must not be empty")
            XCTAssertTrue(path.hasPrefix("/"), "If a path is returned for PID 1 it must be absolute")
        }
        // nil is also a valid outcome (EPERM) — no assertion failure needed.
    }
}
