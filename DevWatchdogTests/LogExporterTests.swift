import XCTest
@testable import DevWatchdog

@MainActor
final class LogExporterTests: XCTestCase {

    // MARK: - encodeAsJSON: empty input

    func testEncodeEmptyEntries() throws {
        let data = LogExporter.encodeAsJSON(entries: [])
        XCTAssertNotNil(data)
        let arr = try JSONSerialization.jsonObject(with: data!) as? [[String: Any]]
        XCTAssertNotNil(arr)
        XCTAssertEqual(arr?.count, 0)
    }

    // MARK: - encodeAsJSON: field presence

    func testEncodeEntryIncludesAllFields() throws {
        let entry = SessionLogEntry(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            kind: .kill,
            message: "Auto-killed vitest",
            pid: 1234,
            processName: "vitest",
            killReason: KillReason(
                ruleID: UUID(),
                rulePattern: "vitest",
                trigger: .maxRuntime,
                thresholdValue: 1800,
                actualValue: 1900,
                unit: "s"
            )
        )
        let data = try XCTUnwrap(LogExporter.encodeAsJSON(entries: [entry]))
        let arr = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(arr.count, 1)
        let first = arr[0]
        XCTAssertEqual(first["kind"] as? String, "kill")
        XCTAssertEqual(first["message"] as? String, "Auto-killed vitest")
        XCTAssertEqual(first["pid"] as? Int, 1234)
        XCTAssertEqual(first["processName"] as? String, "vitest")
        let kr = try XCTUnwrap(first["killReason"] as? [String: Any])
        XCTAssertEqual(kr["trigger"] as? String, "maxRuntime")
        XCTAssertEqual(kr["unit"] as? String, "s")
    }

    func testEncodeEntryWithoutKillReasonHasNullOrMissingKillReason() throws {
        let entry = SessionLogEntry(
            id: UUID(),
            timestamp: Date(),
            kind: .throttle,
            message: "throttled",
            pid: nil,
            processName: nil,
            killReason: nil
        )
        let data = try XCTUnwrap(LogExporter.encodeAsJSON(entries: [entry]))
        let arr = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let first = arr[0]
        // killReason must either be absent or NSNull
        if let value = first["killReason"] {
            XCTAssertTrue(value is NSNull, "killReason with nil should encode as null, got \(value)")
        }
        // If absent that is also acceptable
    }

    func testEncodeMultipleEntries() throws {
        let entries = [
            SessionLogEntry(id: UUID(), timestamp: Date(), kind: .kill,
                            message: "kill", pid: 1, processName: "node", killReason: nil),
            SessionLogEntry(id: UUID(), timestamp: Date(), kind: .throttle,
                            message: "throttle", pid: 2, processName: "tsc", killReason: nil),
            SessionLogEntry(id: UUID(), timestamp: Date(), kind: .resume,
                            message: "resume", pid: 3, processName: "jest", killReason: nil),
        ]
        let data = try XCTUnwrap(LogExporter.encodeAsJSON(entries: entries))
        let arr = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(arr.count, 3)
        XCTAssertEqual(arr[0]["kind"] as? String, "kill")
        XCTAssertEqual(arr[1]["kind"] as? String, "throttle")
        XCTAssertEqual(arr[2]["kind"] as? String, "resume")
    }

    // MARK: - encodeAsJSON: valid JSON output

    func testEncodeIsValidJSON() throws {
        let entries = [
            SessionLogEntry(id: UUID(), timestamp: Date(), kind: .throttle,
                            message: "m", pid: nil, processName: nil, killReason: nil),
            SessionLogEntry(id: UUID(), timestamp: Date(), kind: .resume,
                            message: "n", pid: 42, processName: "foo", killReason: nil),
        ]
        let data = try XCTUnwrap(LogExporter.encodeAsJSON(entries: entries))
        // Must parse without throwing
        _ = try JSONSerialization.jsonObject(with: data)
    }

    func testEncodeProducesUTF8Data() throws {
        let entry = SessionLogEntry(
            id: UUID(), timestamp: Date(), kind: .kill,
            message: "Prozess gekillt", pid: 100, processName: "esbuild", killReason: nil
        )
        let data = try XCTUnwrap(LogExporter.encodeAsJSON(entries: [entry]))
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains("Prozess gekillt"))
    }

    // MARK: - redactSecrets: --password

    func testRedactPasswordEquals() {
        let out = LogExporter.redactSecrets(in: "--password=hunter2 arg")
        XCTAssertEqual(out, "--password=[redacted] arg")
    }

    func testRedactPasswordSpace() {
        let out = LogExporter.redactSecrets(in: "foo --password hunter2 bar")
        XCTAssertEqual(out, "foo --password [redacted] bar")
    }

    // MARK: - redactSecrets: --token

    func testRedactTokenEquals() {
        let out = LogExporter.redactSecrets(in: "--token=abc123")
        XCTAssertEqual(out, "--token=[redacted]")
    }

    func testRedactTokenSpace() {
        let out = LogExporter.redactSecrets(in: "run --token ghp_secretval")
        XCTAssertEqual(out, "run --token [redacted]")
    }

    // MARK: - redactSecrets: --secret

    func testRedactSecretSpace() {
        let out = LogExporter.redactSecrets(in: "--secret my-api-key-data")
        XCTAssertEqual(out, "--secret [redacted]")
    }

    func testRedactSecretEquals() {
        let out = LogExporter.redactSecrets(in: "--secret=supersecret")
        XCTAssertEqual(out, "--secret=[redacted]")
    }

    // MARK: - redactSecrets: --api-key / --apikey

    func testRedactAPIKeyEquals() {
        XCTAssertEqual(LogExporter.redactSecrets(in: "--api-key=xyz"), "--api-key=[redacted]")
    }

    func testRedactApikeyEquals() {
        XCTAssertEqual(LogExporter.redactSecrets(in: "--apikey=xyz"), "--apikey=[redacted]")
    }

    // MARK: - redactSecrets: --auth

    func testRedactAuthEquals() {
        let out = LogExporter.redactSecrets(in: "--auth=Bearer-some-token")
        XCTAssertEqual(out, "--auth=[redacted]")
    }

    func testRedactAuthSpace() {
        let out = LogExporter.redactSecrets(in: "--auth Bearer-some-token")
        XCTAssertEqual(out, "--auth [redacted]")
    }

    // MARK: - redactSecrets: case-insensitive

    func testRedactIsCaseInsensitive() {
        // The regex match is case-insensitive, but the replacement template uses
        // the lowercase flag prefix (--password), so the output prefix is lowercase.
        let out = LogExporter.redactSecrets(in: "--PASSWORD=secret123")
        XCTAssertFalse(out.contains("secret123"), "raw value must not appear after redaction")
        XCTAssertTrue(out.contains("[redacted]"), "redacted marker must appear")
    }

    // MARK: - redactSecrets: safe text unchanged

    func testRedactDoesNotTouchUnrelatedText() {
        let out = LogExporter.redactSecrets(in: "safe command without any secrets")
        XCTAssertEqual(out, "safe command without any secrets")
    }

    func testRedactEmptyStringReturnsEmpty() {
        let out = LogExporter.redactSecrets(in: "")
        XCTAssertEqual(out, "")
    }

    // MARK: - redactSecrets applied during encode

    func testRedactMessageInsideExportEntry() throws {
        let entry = SessionLogEntry(
            id: UUID(),
            timestamp: Date(),
            kind: .kill,
            message: "cmd --password=hunter2 node script.js",
            pid: 1,
            processName: "node --token=xyz123secret",
            killReason: nil
        )
        let data = try XCTUnwrap(LogExporter.encodeAsJSON(entries: [entry]))
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(text.contains("hunter2"), "raw password must not appear in export")
        XCTAssertFalse(text.contains("xyz123secret"), "raw token must not appear in export")
        XCTAssertTrue(text.contains("[redacted]"))
    }

    func testRedactKillReasonPatternIsNotRedacted() throws {
        // rule patterns are stored in killReason.rulePattern, which is not passed through redactSecrets
        let entry = SessionLogEntry(
            id: UUID(),
            timestamp: Date(),
            kind: .kill,
            message: "killed vitest",
            pid: 42,
            processName: "vitest",
            killReason: KillReason(
                ruleID: UUID(),
                rulePattern: "vitest",
                trigger: .maxRuntime,
                thresholdValue: 1800,
                actualValue: 1850,
                unit: "s"
            )
        )
        let data = try XCTUnwrap(LogExporter.encodeAsJSON(entries: [entry]))
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        // rulePattern "vitest" does not look like a secret flag value — should be present
        XCTAssertTrue(text.contains("vitest"))
    }

    // MARK: - copyJSONToPasteboard

    func testCopyJSONToPasteboardReturnsTrueForEmptyEntries() {
        let result = LogExporter.copyJSONToPasteboard(entries: [])
        XCTAssertTrue(result)
    }

    func testCopyJSONToPasteboardWritesValidJSONString() throws {
        let entry = SessionLogEntry(
            id: UUID(), timestamp: Date(), kind: .kill,
            message: "test", pid: 1, processName: "node", killReason: nil
        )
        let result = LogExporter.copyJSONToPasteboard(entries: [entry])
        XCTAssertTrue(result)
        let pbString = try XCTUnwrap(NSPasteboard.general.string(forType: .string))
        let pbData = try XCTUnwrap(pbString.data(using: .utf8))
        // Must be parseable JSON
        _ = try JSONSerialization.jsonObject(with: pbData)
    }
}
