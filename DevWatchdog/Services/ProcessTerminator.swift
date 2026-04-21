import Foundation

/// Abstraction over process termination so that higher-level services can be
/// tested with fakes. The concrete default is ``ProcessKiller`` which shells
/// out to SIGTERM→SIGKILL escalation and also supports SIGSTOP/SIGCONT for
/// Emergency Mode triage.
protocol ProcessTerminator: Sendable {
    /// Politely terminate (SIGTERM with a follow-up SIGKILL if still alive).
    func terminate(pid: Int32) -> KillResult

    /// Politely terminate with PID-reuse identity verification.
    /// `expectedStart` is the proc_pidinfo start timestamp; 0 means "skip verification".
    /// `expectedComm` is the short process name (up to 15 chars); nil means "skip comm check".
    func terminate(pid: Int32, expectedStart: Int64, expectedComm: String?) -> KillResult

    /// Immediate, non-graceful kill (SIGKILL).
    func forceKill(pid: Int32)

    /// Liveness probe. Returns `true` if the PID still exists and is signalable.
    func isProcessAlive(_ pid: Int32) -> Bool

    /// Freeze a process without killing it (SIGSTOP + renice +20).
    /// Used as a graduated response before full termination.
    func throttle(pid: Int32) -> KillResult

    /// Resume a previously throttled/stopped process (SIGCONT).
    func resume(pid: Int32) -> KillResult
}

// MARK: - Default implementation for backward compatibility

extension ProcessTerminator {
    /// Default: no identity verification — delegates to the original `terminate(pid:)`.
    /// Test doubles that only implement the original method get this for free.
    func terminate(pid: Int32, expectedStart: Int64, expectedComm: String?) -> KillResult {
        terminate(pid: pid)
    }
}

// MARK: - ProcessKiller adoption

extension ProcessKiller: ProcessTerminator {
    /// Protocol alias that forwards to the existing ``kill(pid:)`` implementation.
    func terminate(pid: Int32) -> KillResult {
        kill(pid: pid)
    }

    /// Identity-verified termination — delegates to ``kill(pid:expectedStart:expectedComm:)``.
    func terminate(pid: Int32, expectedStart: Int64, expectedComm: String?) -> KillResult {
        kill(pid: pid, expectedStart: expectedStart, expectedComm: expectedComm)
    }
}
