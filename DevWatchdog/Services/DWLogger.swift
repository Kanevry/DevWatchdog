import Foundation
import OSLog

/// Unified logger: writes to Apple Unified Logging (os_log) and a rotating
/// JSON-Lines file under ~/Library/Logs/DevWatchdog/.
public final class DWLogger: @unchecked Sendable {
    public static let shared = DWLogger()

    public enum Category: String, Sendable {
        case monitor, killer, pressure, emergency, rules, ui
    }

    private let subsystem = "at.kanevry.DevWatchdog"
    private let loggers: [Category: Logger]
    private let logDirectoryURL: URL?
    private let fileQueue = DispatchQueue(label: "at.kanevry.DevWatchdog.filelog", qos: .utility)
    private let dateFormatter: DateFormatter
    private let iso8601Formatter: ISO8601DateFormatter

    private init() {
        var map: [Category: Logger] = [:]
        for c in [Category.monitor, .killer, .pressure, .emergency, .rules, .ui] {
            map[c] = Logger(subsystem: "at.kanevry.DevWatchdog", category: c.rawValue)
        }
        self.loggers = map

        let fm = FileManager.default
        let dir = fm.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Logs/DevWatchdog", isDirectory: true)
        self.logDirectoryURL = dir
        if let dir { try? fm.createDirectory(at: dir, withIntermediateDirectories: true) }

        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"
        df.timeZone = TimeZone.current
        self.dateFormatter = df

        self.iso8601Formatter = ISO8601DateFormatter()
        self.iso8601Formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        // Prune old logs at startup (non-blocking).
        fileQueue.async { [weak self] in self?.pruneOldLogsInternal(retentionDays: 14) }
    }

    /// Primary logging entry point.
    public func log(
        _ message: String,
        category: Category,
        level: OSLogType = .info,
        pid: Int32? = nil,
        processName: String? = nil
    ) {
        loggers[category]?.log(level: level, "\(message, privacy: .public)")
        fileQueue.async { [weak self] in
            self?.appendFileLineInternal(
                message: message, category: category, level: level,
                pid: pid, processName: processName
            )
        }
    }

    /// Emits a BOOTSTRAP line with version, OS, CPU count, and a config snapshot.
    /// Call exactly once at app startup.
    public func bootstrap(
        appVersion: String,
        buildNumber: String,
        osVersion: String,
        ncpu: Int,
        configSnapshot: [String: String]
    ) {
        var parts: [String] = [
            "version=\(appVersion)+\(buildNumber)",
            "os=\(osVersion)",
            "ncpu=\(ncpu)",
        ]
        for (k, v) in configSnapshot.sorted(by: { $0.key < $1.key }) {
            parts.append("\(k)=\(v)")
        }
        let msg = "BOOTSTRAP " + parts.joined(separator: " ")
        log(msg, category: .monitor, level: .default)
    }

    // MARK: - Internals (file queue only)

    private func currentLogURL() -> URL? {
        guard let dir = logDirectoryURL else { return nil }
        let stamp = dateFormatter.string(from: Date())
        return dir.appendingPathComponent("session-\(stamp).log")
    }

    private func appendFileLineInternal(
        message: String, category: Category, level: OSLogType,
        pid: Int32?, processName: String?
    ) {
        guard let url = currentLogURL() else { return }
        var obj: [String: Any] = [
            "ts": iso8601Formatter.string(from: Date()),
            "cat": category.rawValue,
            "lvl": Self.levelString(level),
            "msg": message,
        ]
        if let pid { obj["pid"] = Int(pid) }
        if let processName { obj["proc"] = processName }
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return }
        var line = data
        line.append(0x0A) // newline

        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } catch {
                // Swallow — file log must never crash the app.
            }
        }
    }

    private static func levelString(_ level: OSLogType) -> String {
        switch level {
        case .debug: return "debug"
        case .info: return "info"
        case .default: return "default"
        case .error: return "error"
        case .fault: return "fault"
        default: return "info"
        }
    }

    private func pruneOldLogsInternal(retentionDays: Int) {
        guard let dir = logDirectoryURL else { return }
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86400)
        for url in contents where url.pathExtension == "log" {
            if let attrs = try? fm.attributesOfItem(atPath: url.path),
               let mdate = attrs[.modificationDate] as? Date,
               mdate < cutoff {
                try? fm.removeItem(at: url)
            }
        }
    }
}
