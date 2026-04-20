import Foundation

/// Abstraction over process termination so that higher-level services can be
/// tested with fakes. The concrete default is ``ProcessKiller`` which shells
/// out to SIGTERM→SIGKILL escalation and also supports SIGSTOP/SIGCONT for
/// Emergency Mode triage.
protocol ProcessTerminator: Sendable {
    /// Politely terminate (SIGTERM with a follow-up SIGKILL if still alive).
    func terminate(pid: Int32) -> KillResult

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

// MARK: - ProcessKiller adoption

extension ProcessKiller: ProcessTerminator {
    /// Protocol alias that forwards to the existing ``kill(pid:)`` implementation.
    func terminate(pid: Int32) -> KillResult {
        kill(pid: pid)
    }
}
