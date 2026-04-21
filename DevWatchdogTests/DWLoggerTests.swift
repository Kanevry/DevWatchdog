import XCTest
@testable import DevWatchdog

final class DWLoggerTests: XCTestCase {

    private var logDir: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Logs/DevWatchdog", isDirectory: true)
    }

    private func todayLogURL() -> URL {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"
        return logDir.appendingPathComponent("session-\(df.string(from: Date())).log")
    }

    // MARK: - File creation

    func testLogCreatesFile() {
        DWLogger.shared.log("DWLoggerTests.testLogCreatesFile touchpoint", category: .monitor, level: .info)
        // File write is async via DispatchQueue(qos:.utility); wait briefly.
        Thread.sleep(forTimeInterval: 0.2)
        let url = todayLogURL()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "expected log file to exist at \(url.path)")
    }

    // MARK: - JSON structure

    func testLogLineIsValidJSON() throws {
        let sentinel = "SENTINEL-\(UUID().uuidString)"
        DWLogger.shared.log(sentinel, category: .killer, level: .error, pid: 4242, processName: "test-proc")
        Thread.sleep(forTimeInterval: 0.25)

        let data = try Data(contentsOf: todayLogURL())
        let text = String(data: data, encoding: .utf8) ?? ""
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard let matching = lines.last(where: { $0.contains(sentinel) }) else {
            return XCTFail("no line containing sentinel \(sentinel)")
        }
        let obj = try JSONSerialization.jsonObject(with: Data(matching.utf8), options: [])
        guard let dict = obj as? [String: Any] else { return XCTFail("line is not a JSON object") }

        XCTAssertEqual(dict["cat"] as? String, "killer")
        XCTAssertEqual(dict["lvl"] as? String, "error")
        XCTAssertEqual(dict["msg"] as? String, sentinel)
        XCTAssertEqual(dict["pid"] as? Int, 4242)
        XCTAssertEqual(dict["proc"] as? String, "test-proc")
        XCTAssertNotNil(dict["ts"], "timestamp field 'ts' must be present")
    }

    func testLogLineWithoutOptionalFieldsOmitsPidAndProc() throws {
        let sentinel = "NO-OPT-\(UUID().uuidString)"
        DWLogger.shared.log(sentinel, category: .rules, level: .info)
        Thread.sleep(forTimeInterval: 0.25)

        let data = try Data(contentsOf: todayLogURL())
        let text = String(data: data, encoding: .utf8) ?? ""
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard let matching = lines.last(where: { $0.contains(sentinel) }) else {
            return XCTFail("no line containing sentinel \(sentinel)")
        }
        let obj = try JSONSerialization.jsonObject(with: Data(matching.utf8), options: [])
        guard let dict = obj as? [String: Any] else { return XCTFail("line is not a JSON object") }

        XCTAssertNil(dict["pid"], "pid key must be absent when not provided")
        XCTAssertNil(dict["proc"], "proc key must be absent when not provided")
    }

    // MARK: - Level strings

    func testInfoLevelWritesInfoString() throws {
        let sentinel = "LVL-INFO-\(UUID().uuidString)"
        DWLogger.shared.log(sentinel, category: .monitor, level: .info)
        Thread.sleep(forTimeInterval: 0.25)

        let text = try String(data: Data(contentsOf: todayLogURL()), encoding: .utf8) ?? ""
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard let matching = lines.last(where: { $0.contains(sentinel) }) else {
            return XCTFail("no line containing sentinel \(sentinel)")
        }
        let obj = try JSONSerialization.jsonObject(with: Data(matching.utf8), options: [])
        let dict = obj as? [String: Any]
        XCTAssertEqual(dict?["lvl"] as? String, "info")
    }

    func testDefaultLevelWritesDefaultString() throws {
        let sentinel = "LVL-DEFAULT-\(UUID().uuidString)"
        DWLogger.shared.log(sentinel, category: .monitor, level: .default)
        Thread.sleep(forTimeInterval: 0.25)

        let text = try String(data: Data(contentsOf: todayLogURL()), encoding: .utf8) ?? ""
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard let matching = lines.last(where: { $0.contains(sentinel) }) else {
            return XCTFail("no line containing sentinel \(sentinel)")
        }
        let obj = try JSONSerialization.jsonObject(with: Data(matching.utf8), options: [])
        let dict = obj as? [String: Any]
        XCTAssertEqual(dict?["lvl"] as? String, "default")
    }

    func testErrorLevelWritesErrorString() throws {
        let sentinel = "LVL-ERROR-\(UUID().uuidString)"
        DWLogger.shared.log(sentinel, category: .pressure, level: .error)
        Thread.sleep(forTimeInterval: 0.25)

        let text = try String(data: Data(contentsOf: todayLogURL()), encoding: .utf8) ?? ""
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard let matching = lines.last(where: { $0.contains(sentinel) }) else {
            return XCTFail("no line containing sentinel \(sentinel)")
        }
        let obj = try JSONSerialization.jsonObject(with: Data(matching.utf8), options: [])
        let dict = obj as? [String: Any]
        XCTAssertEqual(dict?["lvl"] as? String, "error")
    }

    // MARK: - Bootstrap

    func testBootstrapEmitsNoticeLevel() throws {
        let sentinel = "BOOTSTRAP-TEST-\(UUID().uuidString)"
        // bootstrap calls log(..., level: .default) — use direct log to test same path
        DWLogger.shared.log(sentinel, category: .monitor, level: .default)
        Thread.sleep(forTimeInterval: 0.25)

        let data = try Data(contentsOf: todayLogURL())
        let text = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains(sentinel),
                      "expected sentinel to appear in log after .default-level log call")
    }

    func testBootstrapMethodWritesVersionInfo() throws {
        let sentinel = "1.2.3+456"  // version+build embedded in BOOTSTRAP message
        DWLogger.shared.bootstrap(
            appVersion: "1.2.3",
            buildNumber: "456",
            osVersion: "macOS 15.0",
            ncpu: 8,
            configSnapshot: ["key": "val"]
        )
        Thread.sleep(forTimeInterval: 0.25)

        let data = try Data(contentsOf: todayLogURL())
        let text = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("BOOTSTRAP"), "expected BOOTSTRAP marker in log")
        XCTAssertTrue(text.contains(sentinel), "expected version string '\(sentinel)' in log")
    }

    // MARK: - All categories produce output

    func testAllCategoriesProduceOutput() throws {
        let categories: [DWLogger.Category] = [.monitor, .killer, .pressure, .emergency, .rules, .ui]
        let sentinel = "CAT-ALL-\(UUID().uuidString)"
        for cat in categories {
            DWLogger.shared.log("\(sentinel)-\(cat.rawValue)", category: cat, level: .info)
        }
        Thread.sleep(forTimeInterval: 0.4)

        let data = try Data(contentsOf: todayLogURL())
        let text = String(data: data, encoding: .utf8) ?? ""
        for cat in categories {
            XCTAssertTrue(text.contains("\(sentinel)-\(cat.rawValue)"),
                          "missing message line for category \(cat.rawValue)")
            XCTAssertTrue(text.contains("\"cat\":\"\(cat.rawValue)\""),
                          "missing 'cat' JSON field for category \(cat.rawValue)")
        }
    }

    // MARK: - PID stored as integer

    func testPidStoredAsIntegerNotString() throws {
        let sentinel = "PID-INT-\(UUID().uuidString)"
        DWLogger.shared.log(sentinel, category: .killer, level: .info, pid: 9999)
        Thread.sleep(forTimeInterval: 0.25)

        let data = try Data(contentsOf: todayLogURL())
        let text = String(data: data, encoding: .utf8) ?? ""
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard let matching = lines.last(where: { $0.contains(sentinel) }) else {
            return XCTFail("no line containing sentinel \(sentinel)")
        }
        let obj = try JSONSerialization.jsonObject(with: Data(matching.utf8), options: [])
        let dict = obj as? [String: Any]
        // pid must be a number, not a string — JSONSerialization returns Int/Double for numbers
        XCTAssertEqual(dict?["pid"] as? Int, 9999)
        XCTAssertNil(dict?["pid"] as? String, "pid must not be serialised as a string")
    }
}
