import XCTest
@testable import DevWatchdog

@MainActor
final class InclusionPatternsTests: XCTestCase {

    // MARK: - Default inclusion patterns

    func testDefaultInclusionPatternsContains22Entries() {
        XCTAssertEqual(WatchdogConfig.defaultInclusionPatterns.count, 22)
    }

    func testDefaultInclusionPatternsContainsNode() {
        XCTAssertTrue(WatchdogConfig.defaultInclusionPatterns.contains("node"))
    }

    func testDefaultInclusionPatternsContainsVitest() {
        XCTAssertTrue(WatchdogConfig.defaultInclusionPatterns.contains("vitest"))
    }

    func testDefaultInclusionPatternsContainsTsgo() {
        XCTAssertTrue(WatchdogConfig.defaultInclusionPatterns.contains("tsgo"))
    }

    func testDefaultInclusionPatternsContainsBun() {
        XCTAssertTrue(WatchdogConfig.defaultInclusionPatterns.contains("bun"))
    }

    func testDefaultInclusionPatternsContainsDeno() {
        XCTAssertTrue(WatchdogConfig.defaultInclusionPatterns.contains("deno"))
    }

    func testDefaultInclusionPatternsContainsSwc() {
        XCTAssertTrue(WatchdogConfig.defaultInclusionPatterns.contains("swc"))
    }

    func testDefaultInclusionPatternsContainsCoreWebTooling() {
        // Spot-check a representative subset from the 22-item list
        let expected = ["jest", "tsc", "esbuild", "next", "webpack", "turbo",
                        "eslint", "prettier", "mcp", "pnpm", "npm run", "yarn",
                        "playwright", "ms-playwright", "percy", "react-email"]
        for pattern in expected {
            XCTAssertTrue(WatchdogConfig.defaultInclusionPatterns.contains(pattern),
                          "expected '\(pattern)' in defaultInclusionPatterns")
        }
    }

    // MARK: - WatchdogConfig loads defaults when UserDefaults key is absent

    func testConfigLoadsDefaultWhenKeyAbsent() {
        UserDefaults.standard.removeObject(forKey: "inclusionPatterns")
        let c = WatchdogConfig()
        XCTAssertEqual(c.inclusionPatterns, WatchdogConfig.defaultInclusionPatterns)
    }

    // MARK: - WatchdogConfig persists custom patterns

    func testConfigPersistsCustomPatterns() {
        let c = WatchdogConfig()
        c.inclusionPatterns = ["rspack", "rollup", "biome"]
        // didSet encodes to UserDefaults synchronously
        let data = UserDefaults.standard.data(forKey: "inclusionPatterns")
        XCTAssertNotNil(data, "UserDefaults must contain data for 'inclusionPatterns' key after assignment")
        let decoded = try? JSONDecoder().decode([String].self, from: data!)
        XCTAssertEqual(decoded, ["rspack", "rollup", "biome"])
    }

    func testConfigPersistsEmptyPatternList() {
        let c = WatchdogConfig()
        c.inclusionPatterns = []
        let data = UserDefaults.standard.data(forKey: "inclusionPatterns")
        XCTAssertNotNil(data, "UserDefaults must contain data even for an empty list")
        let decoded = try? JSONDecoder().decode([String].self, from: data!)
        XCTAssertEqual(decoded, [])
    }

    func testConfigRoundtripsCustomPatternsOnReload() {
        // Write a custom list, then reload a new WatchdogConfig — it must read back the same values.
        let c1 = WatchdogConfig()
        c1.inclusionPatterns = ["vite", "swc", "rolldown"]

        // New instance reads from same UserDefaults
        let c2 = WatchdogConfig()
        XCTAssertEqual(c2.inclusionPatterns, ["vite", "swc", "rolldown"])

        // Restore defaults so subsequent tests start clean
        UserDefaults.standard.removeObject(forKey: "inclusionPatterns")
    }

    // MARK: - Stage-0 filter: empty patterns lets nothing through

    func testParseProcessListWithEmptyInclusionPatternsProducesNoDevProcesses() {
        // /bin/ps will run; with no inclusion patterns nothing matches Stage-0.
        let result = PSParser.parseProcessList(excludedApps: [], inclusionPatterns: [], timeout: 5)
        XCTAssertTrue(result.isEmpty,
                      "expected no dev processes when inclusionPatterns is empty; got \(result.count)")
    }

    // MARK: - Stage-0 filter: custom patterns are applied without crashing

    func testParseProcessListWithCustomInclusionPatternDoesNotCrash() {
        // We cannot guarantee any particular process is running, but the call
        // must complete without throwing and return a sensible count.
        let candidates = ["launchd", "systemextensiond", "sleep"]
        let result = PSParser.parseProcessList(excludedApps: [], inclusionPatterns: candidates, timeout: 5)
        // Sanity bound — result is zero or more, never millions
        XCTAssertLessThanOrEqual(result.count, 10_000)
    }

    func testParseProcessListWithDefaultPatternsReturnsOnlyMatchingProcesses() {
        // Run with default patterns — every returned process's command must match
        // at least one inclusion pattern (case-insensitive).
        let patterns = WatchdogConfig.defaultInclusionPatterns
        let result = PSParser.parseProcessList(
            excludedApps: [],
            inclusionPatterns: patterns,
            timeout: 5
        )
        for process in result {
            let cmd = process.command.lowercased()
            let matched = patterns.contains { cmd.contains($0.lowercased()) }
            XCTAssertTrue(matched,
                          "process '\(process.command)' should match at least one inclusion pattern")
        }
    }

    // MARK: - Stage-0 filter: case-insensitive matching

    func testParseProcessListInclusionPatternMatchingIsCaseInsensitive() {
        // Pattern "NODE" (uppercase) must still match a process whose command
        // contains "node" (lowercase). We verify by comparing against the result
        // from lowercase patterns — counts must be equal.
        let lowerResult = PSParser.parseProcessList(
            excludedApps: [],
            inclusionPatterns: ["node"],
            timeout: 5
        )
        let upperResult = PSParser.parseProcessList(
            excludedApps: [],
            inclusionPatterns: ["NODE"],
            timeout: 5
        )
        XCTAssertEqual(lowerResult.count, upperResult.count,
                       "inclusion pattern matching must be case-insensitive: 'node' vs 'NODE' should yield same count")
    }
}
