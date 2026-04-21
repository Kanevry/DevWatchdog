import Foundation
import Combine

// MARK: - Kill reason metadata (issue #24)

/// Which automated rule or heuristic caused the kill.
enum KillTrigger: String, Sendable, Hashable, Codable {
    case maxRuntime
    case maxCPUPercent
    case maxRSSMB
    case orphanTimeout
    case catchAllMaxRuntime
    case emergencyPromotion
    case manual
}

/// Structured annotation attached to every auto-kill log entry.
/// Carries enough information to reconstruct "why" a process was killed:
/// which rule matched, which threshold fired, and what the observed value was.
struct KillReason: Sendable, Hashable, Codable {
    let ruleID: UUID?
    let rulePattern: String?
    let trigger: KillTrigger
    let thresholdValue: Double
    let actualValue: Double
    let unit: String // "s" / "%" / "MB"
}

/// Single line item in the in-memory session log.
///
/// Everything relevant to the UI row is captured here — timestamp,
/// kind (used for icon/colour), human-readable message, and optional
/// PID/process-name context for diagnostics.
struct SessionLogEntry: Identifiable, Sendable, Hashable {
    let id: UUID
    let timestamp: Date
    let kind: Kind
    let message: String
    let pid: Int32?
    let processName: String?
    let killReason: KillReason?

    enum Kind: String, Sendable, Hashable {
        case kill
        case throttle
        case resume
        case emergencyEntered
        case emergencyExited
        case pressureWarning
        case error
    }

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        kind: Kind,
        message: String,
        pid: Int32? = nil,
        processName: String? = nil,
        killReason: KillReason? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.message = message
        self.pid = pid
        self.processName = processName
        self.killReason = killReason
    }
}

/// Bounded in-memory log of recent monitor actions. Acts as a ring buffer:
/// once `capacity` entries are stored, the oldest entry is dropped on append.
///
/// Lives on the MainActor so SwiftUI views can observe `entries` directly
/// via `@ObservedObject` without extra hops.
@MainActor
final class SessionLog: ObservableObject {
    /// Ordered list of entries, oldest first. Views typically reverse for display.
    @Published private(set) var entries: [SessionLogEntry] = []

    /// Maximum number of entries kept in memory. Fixed at construction time.
    let capacity: Int

    init(capacity: Int = 500) {
        self.capacity = capacity
    }

    /// Append a new entry. If `capacity` would be exceeded, the oldest entry
    /// is removed first so the buffer size stays bounded.
    func append(_ entry: SessionLogEntry) {
        entries.append(entry)
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }

    /// Convenience overload: build + append in one call.
    func log(
        _ kind: SessionLogEntry.Kind,
        _ message: String,
        pid: Int32? = nil,
        processName: String? = nil,
        killReason: KillReason? = nil
    ) {
        append(
            SessionLogEntry(
                kind: kind,
                message: message,
                pid: pid,
                processName: processName,
                killReason: killReason
            )
        )
    }

    /// Drop every entry. Triggered by the "Löschen" button in the log view.
    func clear() {
        entries.removeAll()
    }
}
