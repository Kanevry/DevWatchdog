import Foundation

/// Strategy + counts produced by a panic run.
struct PanicResult: Equatable, Sendable {
    let killedCount: Int
    let throttledCount: Int
    let freedMemoryMB: Double
    let strategy: Strategy

    enum Strategy: String, Sendable {
        case hardKill
        case softKill
    }

    static let empty = PanicResult(
        killedCount: 0,
        throttledCount: 0,
        freedMemoryMB: 0,
        strategy: .hardKill
    )
}

/// Pure, testable implementation of the "Panic" action.
///
/// Depending on `config.softKillPreferred` it either:
/// - Hard-kills every zombie + suspect, or
/// - Throttles (SIGSTOP) every suspect and kills every zombie (they're
///   already doomed).
///
/// Sends a summary notification when finished.
@MainActor
final class PanicAction {
    private let monitor: ProcessMonitor
    private let config: WatchdogConfig
    private let notifications: NotificationService

    init(
        monitor: ProcessMonitor,
        config: WatchdogConfig,
        notifications: NotificationService = NotificationService()
    ) {
        self.monitor = monitor
        self.config = config
        self.notifications = notifications
    }

    /// Execute the panic action immediately. Returns a `PanicResult` summary.
    @discardableResult
    func execute() -> PanicResult {
        let zombies = monitor.zombieProcesses
        let suspects = monitor.suspectProcesses
        let softKill = config.softKillPreferred

        // Compute freed memory from whatever we actually terminate.
        // Throttled processes don't free memory — only killed ones do.
        var killedCount = 0
        var throttledCount = 0
        var freedMemory = 0.0

        if softKill {
            // Suspects: throttle (SIGSTOP + renice).
            for suspect in suspects {
                monitor.throttleProcess(suspect)
                throttledCount += 1
            }
            // Zombies: kill outright.
            for zombie in zombies {
                freedMemory += zombie.memoryMB
                monitor.killProcess(zombie)
                killedCount += 1
            }
        } else {
            for process in zombies {
                freedMemory += process.memoryMB
                monitor.killProcess(process)
                killedCount += 1
            }
            for process in suspects {
                freedMemory += process.memoryMB
                monitor.killProcess(process)
                killedCount += 1
            }
        }

        let result = PanicResult(
            killedCount: killedCount,
            throttledCount: throttledCount,
            freedMemoryMB: freedMemory,
            strategy: softKill ? .softKill : .hardKill
        )

        // Fire-and-forget summary notification.
        Task { [notifications, result] in
            await notifications.send(
                title: "Panic aktiviert",
                body: Self.summaryBody(for: result),
                sound: true
            )
        }

        return result
    }

    /// Human-readable notification body for a panic run.
    static func summaryBody(for result: PanicResult) -> String {
        let memStr = String(format: "%.0f MB", result.freedMemoryMB)
        switch result.strategy {
        case .softKill:
            if result.killedCount == 0 && result.throttledCount == 0 {
                return "Keine verdächtigen Prozesse gefunden."
            }
            var parts: [String] = []
            if result.throttledCount > 0 {
                parts.append("\(result.throttledCount) pausiert")
            }
            if result.killedCount > 0 {
                parts.append("\(result.killedCount) beendet (\(memStr) frei)")
            }
            return parts.joined(separator: ", ")
        case .hardKill:
            if result.killedCount == 0 {
                return "Keine verdächtigen Prozesse gefunden."
            }
            return "\(result.killedCount) Prozesse beendet — \(memStr) frei."
        }
    }
}
