import Foundation

enum KillResult: Sendable {
    case success
    case alreadyDead
    case permissionDenied
    case failed(errno: Int32)
}

final class ProcessKiller: Sendable {
    /// Kill a process. First sends SIGTERM, waits 5 seconds, then SIGKILL if still alive.
    func kill(pid: Int32) -> KillResult {
        // First try SIGTERM (graceful)
        let termResult = Foundation.kill(pid, SIGTERM)
        if termResult != 0 {
            let err = errno
            if err == ESRCH { return .alreadyDead }
            if err == EPERM { return .permissionDenied }
            return .failed(errno: err)
        }

        // Check after 5 seconds if still alive, then SIGKILL
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) { [self] in
            if self.isProcessAlive(pid) {
                Foundation.kill(pid, SIGKILL)
            }
        }
        return .success
    }

    /// Force kill immediately with SIGKILL (no grace period)
    func forceKill(pid: Int32) {
        Foundation.kill(pid, SIGKILL)
    }

    /// Check if a process is still running
    func isProcessAlive(_ pid: Int32) -> Bool {
        // kill with signal 0 checks existence without sending a signal
        return Foundation.kill(pid, 0) == 0
    }
}
