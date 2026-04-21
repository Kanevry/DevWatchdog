import Foundation
import os.log

/// Disk-persists ``SessionLogEntry`` values as one-JSON-object-per-line files
/// (JSONL) under `~/Library/Application Support/DevWatchdog/sessions/YYYY-MM-DD.jsonl`.
///
/// Why this exists: ``InsightsEngine`` needs enough history to spot patterns
/// ("you start vitest --watch 3× a week and forget it"). With only an
/// in-memory ring buffer, every app restart wipes that data and Insights
/// never gets beyond "not enough data yet". Writing through to disk lets
/// Insights accrue value across days/weeks of actual usage.
///
/// Design goals:
/// - Append is fire-and-forget from the caller — callers hand an entry to the
///   actor via `Task { await SessionLogPersistence.shared.append(entry) }`
///   and never block on file I/O.
/// - Reads are bounded by a day count so Insights gets a bounded, recent
///   window (default 24 h) without scanning weeks of history.
/// - Rotation caps on-disk retention at ``retentionDays`` (default 14) so
///   disk footprint stays predictable without manual cleanup.
actor SessionLogPersistence {

    /// Shared instance — the whole app funnels to one file-per-day per install.
    static let shared = SessionLogPersistence()

    private let retentionDays: Int
    private let directoryURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let logger = Logger(subsystem: "at.gotzendorfer.DevWatchdog", category: "SessionLogPersistence")

    init(retentionDays: Int = 14, directoryURL: URL? = nil) {
        self.retentionDays = retentionDays
        if let directoryURL {
            self.directoryURL = directoryURL
        } else {
            let fm = FileManager.default
            let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
                ?? fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fm.temporaryDirectory
            self.directoryURL = base.appending(path: "DevWatchdog/sessions", directoryHint: .isDirectory)
        }

        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }

    // MARK: - Append

    /// Append a single entry to today's JSONL file. Creates directory and file
    /// as needed. Never throws: a single I/O failure is logged to os_log but
    /// does not break the caller.
    func append(_ entry: SessionLogEntry) {
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let url = fileURL(for: entry.timestamp)
            let lineData = try encoder.encode(entry)
            var data = Data()
            data.append(lineData)
            data.append(0x0A) // newline terminator — canonical JSONL format

            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: url, options: .atomic)
            }
        } catch {
            logger.error("Failed to append session log entry: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Read

    /// Read up to the last `days` calendar days of entries, sorted newest-first.
    /// Malformed lines are skipped silently so a single bad line does not poison
    /// the whole load.
    func recent(days: Int = 1) -> [SessionLogEntry] {
        var all: [SessionLogEntry] = []
        let calendar = Calendar.current
        let today = Date()
        for offset in 0..<max(days, 1) {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            let url = fileURL(for: day)
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in contents.split(separator: "\n", omittingEmptySubsequences: true) {
                guard let data = line.data(using: .utf8) else { continue }
                if let entry = try? decoder.decode(SessionLogEntry.self, from: data) {
                    all.append(entry)
                }
            }
        }
        return all.sorted(by: { $0.timestamp > $1.timestamp })
    }

    // MARK: - Rotation

    /// Remove session files older than ``retentionDays``. Intended to be
    /// called once at app startup. Best-effort — failures are logged, never
    /// thrown.
    func purgeOld() {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else { return }
        let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date()) ?? Date.distantPast
        for url in urls where url.pathExtension == "jsonl" {
            guard let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { continue }
            if mod < cutoff {
                do {
                    try fm.removeItem(at: url)
                    logger.info("Purged old session log: \(url.lastPathComponent, privacy: .public)")
                } catch {
                    logger.error("Failed to purge \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    // MARK: - Helpers

    private func fileURL(for date: Date) -> URL {
        // Use the user's local calendar so a "day" matches the user's perception.
        // iso8601 sortable yyyy-MM-dd keeps files trivially orderable by ls.
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        let name = f.string(from: date) + ".jsonl"
        return directoryURL.appending(path: name)
    }
}
