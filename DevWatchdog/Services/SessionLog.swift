import Foundation
import Combine

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
        processName: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.message = message
        self.pid = pid
        self.processName = processName
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
        processName: String? = nil
    ) {
        append(
            SessionLogEntry(
                kind: kind,
                message: message,
                pid: pid,
                processName: processName
            )
        )
    }

    /// Drop every entry. Triggered by the "Löschen" button in the log view.
    func clear() {
        entries.removeAll()
    }
}
