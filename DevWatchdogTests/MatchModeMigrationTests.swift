import XCTest
@testable import DevWatchdog

final class MatchModeMigrationTests: XCTestCase {

    // MARK: - Helpers

    private func makeProcess(command: String) -> DevProcess {
        DevProcess(
            id: 9999,
            user: "testuser",
            cpuPercent: 0,
            memPercent: 0,
            rss: 0,
            command: command,
            startTime: nil,
            parentPID: 1,
            isOrphan: false,
            state: .running
        )
    }

    /// Minimal required fields for ProcessRule JSON — optional fields absent to simulate old rule storage.
    private let minimalRuleBase = """
    {
        "cpuThreshold": 50,
        "runtimeThreshold": 1800,
        "maxRuntime": 3600,
        "action": "warn",
        "isEnabled": true
    }
    """

    // MARK: - Migration: old JSON without matchMode defaults to .substring

    func testOldJSONWithoutMatchModeDecodesToSubstring() throws {
        let oldJSON = """
        {
            "id": "E4A81F4A-8E05-4F0B-9F6F-2A3BCDEF1234",
            "pattern": "vitest",
            "cpuThreshold": 50,
            "runtimeThreshold": 1800,
            "maxRuntime": 3600,
            "action": "warn",
            "isEnabled": true
        }
        """
        let data = oldJSON.data(using: .utf8)!
        let rule = try JSONDecoder().decode(ProcessRule.self, from: data)
        XCTAssertEqual(rule.matchMode, .substring, "old rule without matchMode must default to substring")
        XCTAssertEqual(rule.pattern, "vitest")
    }

    func testOldJSONWithoutMatchModeStillMatchesSubstring() throws {
        let oldJSON = """
        {
            "id": "E4A81F4A-8E05-4F0B-9F6F-2A3BCDEF1235",
            "pattern": "vitest",
            "cpuThreshold": 50,
            "runtimeThreshold": 1800,
            "maxRuntime": 3600,
            "action": "warn",
            "isEnabled": true
        }
        """
        let rule = try JSONDecoder().decode(ProcessRule.self, from: oldJSON.data(using: .utf8)!)
        XCTAssertTrue(rule.matches(makeProcess(command: "/usr/local/bin/node vitest --forks")))
        XCTAssertFalse(rule.matches(makeProcess(command: "/usr/local/bin/jest --worker")))
    }

    // MARK: - New JSON with matchMode: "glob"

    func testNewJSONWithGlobMatchModeDecodes() throws {
        let newJSON = """
        {
            "id": "E4A81F4A-8E05-4F0B-9F6F-2A3BCDEF5678",
            "pattern": "vitest*",
            "matchMode": "glob",
            "cpuThreshold": 50,
            "runtimeThreshold": 1800,
            "maxRuntime": 3600,
            "action": "warn",
            "isEnabled": true
        }
        """
        let rule = try JSONDecoder().decode(ProcessRule.self, from: newJSON.data(using: .utf8)!)
        XCTAssertEqual(rule.matchMode, .glob)
        XCTAssertEqual(rule.pattern, "vitest*")
    }

    func testGlobModeMatchesCorrectly() throws {
        let json = """
        {
            "id": "E4A81F4A-8E05-4F0B-9F6F-2A3BCDEF5679",
            "pattern": "*vitest*",
            "matchMode": "glob",
            "cpuThreshold": 50,
            "runtimeThreshold": 1800,
            "maxRuntime": 3600,
            "action": "warn",
            "isEnabled": true
        }
        """
        let rule = try JSONDecoder().decode(ProcessRule.self, from: json.data(using: .utf8)!)
        XCTAssertTrue(rule.matches(makeProcess(command: "/usr/bin/node vitest --reporter")))
        XCTAssertFalse(rule.matches(makeProcess(command: "/usr/bin/jest --worker")))
    }

    // MARK: - New JSON with matchMode: "regex"

    func testRegexModeDecodes() throws {
        let json = """
        {
            "id": "E4A81F4A-8E05-4F0B-9F6F-2A3BCDEF9999",
            "pattern": "^(vitest|jest).*$",
            "matchMode": "regex",
            "cpuThreshold": 50,
            "runtimeThreshold": 1800,
            "maxRuntime": 3600,
            "action": "warn",
            "isEnabled": true
        }
        """
        let rule = try JSONDecoder().decode(ProcessRule.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(rule.matchMode, .regex)
        XCTAssertEqual(rule.pattern, "^(vitest|jest).*$")
    }

    func testRegexModeMatchesCorrectly() throws {
        let json = """
        {
            "id": "E4A81F4A-8E05-4F0B-9F6F-2A3BCDEF9998",
            "pattern": "(vitest|jest)",
            "matchMode": "regex",
            "cpuThreshold": 50,
            "runtimeThreshold": 1800,
            "maxRuntime": 3600,
            "action": "warn",
            "isEnabled": true
        }
        """
        let rule = try JSONDecoder().decode(ProcessRule.self, from: json.data(using: .utf8)!)
        XCTAssertTrue(rule.matches(makeProcess(command: "/path/to/vitest --forks")))
        XCTAssertTrue(rule.matches(makeProcess(command: "/path/to/jest --worker")))
        XCTAssertFalse(rule.matches(makeProcess(command: "/path/to/mocha")))
    }

    // MARK: - Encode/decode round-trip preserves matchMode

    func testEncodeDecodeRoundTripGlob() throws {
        let rule = try JSONDecoder().decode(ProcessRule.self, from: """
        {
            "id": "E4A81F4A-8E05-4F0B-9F6F-2A3BCDE01111",
            "pattern": "foo*",
            "matchMode": "glob",
            "cpuThreshold": 10,
            "runtimeThreshold": 100,
            "maxRuntime": 200,
            "action": "warn",
            "isEnabled": true
        }
        """.data(using: .utf8)!)
        let encoded = try JSONEncoder().encode(rule)
        let decoded = try JSONDecoder().decode(ProcessRule.self, from: encoded)
        XCTAssertEqual(decoded.matchMode, .glob)
        XCTAssertEqual(decoded.pattern, rule.pattern)
        XCTAssertEqual(decoded.id, rule.id)
    }

    func testEncodeDecodeRoundTripRegex() throws {
        let rule = try JSONDecoder().decode(ProcessRule.self, from: """
        {
            "id": "E4A81F4A-8E05-4F0B-9F6F-2A3BCDE01112",
            "pattern": "^jest.*$",
            "matchMode": "regex",
            "cpuThreshold": 10,
            "runtimeThreshold": 100,
            "maxRuntime": 200,
            "action": "warn",
            "isEnabled": true
        }
        """.data(using: .utf8)!)
        let encoded = try JSONEncoder().encode(rule)
        let decoded = try JSONDecoder().decode(ProcessRule.self, from: encoded)
        XCTAssertEqual(decoded.matchMode, .regex)
        XCTAssertEqual(decoded.pattern, "^jest.*$")
    }

    func testEncodeDecodeRoundTripSubstring() throws {
        let rule = try JSONDecoder().decode(ProcessRule.self, from: """
        {
            "id": "E4A81F4A-8E05-4F0B-9F6F-2A3BCDE01113",
            "pattern": "vitest",
            "matchMode": "substring",
            "cpuThreshold": 10,
            "runtimeThreshold": 100,
            "maxRuntime": 200,
            "action": "warn",
            "isEnabled": true
        }
        """.data(using: .utf8)!)
        let encoded = try JSONEncoder().encode(rule)
        let decoded = try JSONDecoder().decode(ProcessRule.self, from: encoded)
        XCTAssertEqual(decoded.matchMode, .substring)
    }

    // MARK: - Optional fields default correctly in migration scenario

    func testOldJSONWithoutOptionalFieldsDecodesWithDefaults() throws {
        let oldJSON = """
        {
            "id": "E4A81F4A-8E05-4F0B-9F6F-2A3BCDE02000",
            "pattern": "webpack",
            "cpuThreshold": 80,
            "runtimeThreshold": 3600,
            "maxRuntime": 7200,
            "action": "warn",
            "isEnabled": true
        }
        """
        let rule = try JSONDecoder().decode(ProcessRule.self, from: oldJSON.data(using: .utf8)!)
        XCTAssertEqual(rule.matchMode, .substring, "missing matchMode must default to .substring")
        XCTAssertEqual(rule.maxCPUPercent, 0, "missing maxCPUPercent must default to 0")
        XCTAssertEqual(rule.maxRSSMB, 0, "missing maxRSSMB must default to 0")
        XCTAssertFalse(rule.onlyWhenOrphan, "missing onlyWhenOrphan must default to false")
        XCTAssertEqual(rule.thresholdMode, .any, "missing thresholdMode must default to .any")
    }

    // MARK: - Invalid/malformed pattern in regex mode (graceful failure)

    func testRegexModeDoesNotCrashOnMalformedPattern() {
        let rule = try? JSONDecoder().decode(ProcessRule.self, from: """
        {
            "id": "E4A81F4A-8E05-4F0B-9F6F-2A3BCDE02222",
            "pattern": "[unclosed-bracket",
            "matchMode": "regex",
            "cpuThreshold": 10,
            "runtimeThreshold": 100,
            "maxRuntime": 200,
            "action": "warn",
            "isEnabled": true
        }
        """.data(using: .utf8)!)
        XCTAssertNotNil(rule, "decoding a rule with invalid regex pattern must not throw")
        XCTAssertFalse(rule!.matches(makeProcess(command: "anything")),
                       "rule with malformed regex must return false from matches(), not crash")
    }

    func testRegexModeDoesNotCrashOnEmptyPattern() {
        let rule = try? JSONDecoder().decode(ProcessRule.self, from: """
        {
            "id": "E4A81F4A-8E05-4F0B-9F6F-2A3BCDE02223",
            "pattern": "",
            "matchMode": "regex",
            "cpuThreshold": 10,
            "runtimeThreshold": 100,
            "maxRuntime": 200,
            "action": "warn",
            "isEnabled": true
        }
        """.data(using: .utf8)!)
        XCTAssertNotNil(rule)
        XCTAssertFalse(rule!.matches(makeProcess(command: "anything")),
                       "empty pattern must return false in regex mode")
    }

    // MARK: - MatchMode CaseIterable completeness

    func testAllMatchModeCasesAreCoveredByCodable() throws {
        // Verify all 3 known modes round-trip through JSON
        for mode in ProcessRule.MatchMode.allCases {
            let jsonStr = "\"\(mode.rawValue)\""
            let data = jsonStr.data(using: .utf8)!
            let decoded = try JSONDecoder().decode(ProcessRule.MatchMode.self, from: data)
            XCTAssertEqual(decoded, mode, "MatchMode.\(mode) must round-trip via its rawValue")
        }
    }

    func testMatchModeAllCasesCount() {
        // Regression: if a new mode is added, this test will catch missing test coverage
        XCTAssertEqual(ProcessRule.MatchMode.allCases.count, 3,
                       "expected exactly 3 MatchMode cases: substring, glob, regex")
    }

    // MARK: - matchMode coexists with valid action field

    func testGlobMatchModeCoexistsWithWarnAction() throws {
        let json = """
        {
            "id": "E4A81F4A-8E05-4F0B-9F6F-2A3BCDE03000",
            "pattern": "vitest",
            "matchMode": "glob",
            "cpuThreshold": 50,
            "runtimeThreshold": 1800,
            "maxRuntime": 3600,
            "action": "warn",
            "isEnabled": true
        }
        """
        let rule = try JSONDecoder().decode(ProcessRule.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(rule.matchMode, .glob)
        XCTAssertEqual(rule.action, .warn)
    }
}
