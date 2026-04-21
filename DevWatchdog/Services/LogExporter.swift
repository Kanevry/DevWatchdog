import Foundation
import AppKit

// MARK: - LogExporter

/// Exports ``SessionLog`` entries as JSON, either to the pasteboard or to a
/// user-chosen file via NSSavePanel. Process arguments that look like secrets
/// (passwords, tokens, API keys, etc.) are redacted before export.
enum LogExporter {

    // MARK: Secret redaction

    /// Flag prefixes whose *values* will be redacted from every exported string.
    private static let secretFlagPrefixes = [
        "--password", "--token", "--secret",
        "--api-key", "--apikey", "--auth"
    ]

    /// Redacts secret-like CLI flag values inside `text`.
    ///
    /// Handles both `--flag=value` and `--flag value` styles (case-insensitive).
    static func redactSecrets(in text: String) -> String {
        var result = text
        for prefix in secretFlagPrefixes {
            // "--flag=<value>" → "--flag=[redacted]"
            let eqPattern = "\(NSRegularExpression.escapedPattern(for: prefix))=\\S+"
            if let re = try? NSRegularExpression(pattern: eqPattern, options: [.caseInsensitive]) {
                let range = NSRange(result.startIndex..., in: result)
                result = re.stringByReplacingMatches(
                    in: result, options: [], range: range,
                    withTemplate: "\(prefix)=[redacted]"
                )
            }
            // "--flag <value>" → "--flag [redacted]"
            let spPattern = "\(NSRegularExpression.escapedPattern(for: prefix))\\s+\\S+"
            if let re = try? NSRegularExpression(pattern: spPattern, options: [.caseInsensitive]) {
                let range = NSRange(result.startIndex..., in: result)
                result = re.stringByReplacingMatches(
                    in: result, options: [], range: range,
                    withTemplate: "\(prefix) [redacted]"
                )
            }
        }
        return result
    }

    // MARK: Encoding

    /// Encodes `entries` as pretty-printed JSON `Data`.
    ///
    /// Returns `nil` only if the encoder throws — this should never happen in practice
    /// because all mapped types are `Codable`.
    static func encodeAsJSON(entries: [SessionLogEntry]) -> Data? {
        let exportEntries = entries.map(ExportEntry.init(from:))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(exportEntries)
    }

    // MARK: Copy to pasteboard

    /// Copies the JSON representation of `entries` to the general pasteboard.
    ///
    /// - Returns: `true` when the pasteboard write succeeds.
    @discardableResult
    static func copyJSONToPasteboard(entries: [SessionLogEntry]) -> Bool {
        guard let data = encodeAsJSON(entries: entries),
              let str = String(data: data, encoding: .utf8) else { return false }
        let pb = NSPasteboard.general
        pb.clearContents()
        return pb.setString(str, forType: .string)
    }

    // MARK: Save to file

    /// Presents an `NSSavePanel` and writes JSON to the selected URL.
    ///
    /// - Returns: The saved `URL` on success, or `nil` if the user cancelled or
    ///   an error occurred.
    @MainActor
    static func promptAndSaveJSON(entries: [SessionLogEntry]) async -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"
        panel.nameFieldStringValue = "devwatchdog-\(df.string(from: Date())).json"

        if let desktop = FileManager.default.urls(
            for: .desktopDirectory, in: .userDomainMask
        ).first {
            panel.directoryURL = desktop
        }

        let response = await panel.begin()
        guard response == .OK, let url = panel.url else { return nil }
        guard let data = encodeAsJSON(entries: entries) else { return nil }

        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}

// MARK: - Codable mirror types (private to this file)

/// Codable mirror of ``SessionLogEntry`` used exclusively for JSON export.
/// Keeps ``SessionLogEntry`` itself free of Codable conformance requirements.
private struct ExportEntry: Codable {
    let id: String
    let timestamp: Date
    let kind: String
    let message: String
    let pid: Int32?
    let processName: String?
    let killReason: ExportKillReason?

    init(from entry: SessionLogEntry) {
        self.id = entry.id.uuidString
        self.timestamp = entry.timestamp
        self.kind = entry.kind.rawValue
        self.message = LogExporter.redactSecrets(in: entry.message)
        self.pid = entry.pid
        self.processName = entry.processName.map { LogExporter.redactSecrets(in: $0) }
        self.killReason = entry.killReason.map(ExportKillReason.init(from:))
    }
}

/// Codable mirror of ``KillReason`` for JSON export.
private struct ExportKillReason: Codable {
    let ruleID: String?
    let rulePattern: String?
    let trigger: String
    let thresholdValue: Double
    let actualValue: Double
    let unit: String

    init(from r: KillReason) {
        self.ruleID = r.ruleID?.uuidString
        self.rulePattern = r.rulePattern
        self.trigger = r.trigger.rawValue
        self.thresholdValue = r.thresholdValue
        self.actualValue = r.actualValue
        self.unit = r.unit
    }
}
