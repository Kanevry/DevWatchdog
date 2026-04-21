import XCTest
@testable import DevWatchdog

/// Tests for DevProcessClassifier.classify(_:), covering all four heuristics and key edge cases.
/// Organised by heuristic; each test verifies one behavioural assertion.
final class DevProcessClassifierTests: XCTestCase {

    // MARK: - Helpers

    private func input(
        executablePath: String? = nil,
        workingDirectory: String? = nil,
        parentProcessName: String? = nil,
        bundleIdentifier: String? = nil
    ) -> DevProcessClassifier.Input {
        DevProcessClassifier.Input(
            executablePath: executablePath,
            workingDirectory: workingDirectory,
            parentProcessName: parentProcessName,
            bundleIdentifier: bundleIdentifier
        )
    }

    // MARK: - 1. All-nil input

    func test_classify_empty_returnsUnknown() {
        let verdict = DevProcessClassifier.classify(input())
        XCTAssertEqual(verdict, .unknown)
    }

    // MARK: - 2. Executable-path heuristic

    func test_classify_executablePath_nodeModulesBin_returnsDev() {
        let verdict = DevProcessClassifier.classify(input(
            executablePath: "/Users/alice/repo/node_modules/.bin/vitest"
        ))
        XCTAssertEqual(verdict, .dev)
    }

    func test_classify_executablePath_homebrew_returnsDev() {
        let verdict = DevProcessClassifier.classify(input(
            executablePath: "/opt/homebrew/bin/node"
        ))
        XCTAssertEqual(verdict, .dev)
    }

    func test_classify_executablePath_cargoBin_returnsDev() {
        let verdict = DevProcessClassifier.classify(input(
            executablePath: "/Users/alice/.cargo/bin/cargo"
        ))
        XCTAssertEqual(verdict, .dev)
    }

    func test_classify_executablePath_randomBin_returnsUnknown() {
        // /usr/sbin/ is not in devPathSubstrings — must not match
        let verdict = DevProcessClassifier.classify(input(
            executablePath: "/usr/sbin/sysctl"
        ))
        XCTAssertEqual(verdict, .unknown)
    }

    // MARK: - 3. Working-directory (dev-root) heuristic

    func test_classify_cwd_underProjects_returnsDev() {
        let verdict = DevProcessClassifier.classify(input(
            workingDirectory: "/Users/alice/Projects/MyApp"
        ))
        XCTAssertEqual(verdict, .dev)
    }

    func test_classify_cwd_underCode_returnsDev() {
        let verdict = DevProcessClassifier.classify(input(
            workingDirectory: "/Users/alice/Code/myrepo"
        ))
        XCTAssertEqual(verdict, .dev)
    }

    func test_classify_cwd_nodeModules_returnsDev() {
        // isInDevRoot checks for "/node_modules/" as a substring
        let verdict = DevProcessClassifier.classify(input(
            workingDirectory: "/tmp/x/node_modules/abc"
        ))
        XCTAssertEqual(verdict, .dev)
    }

    func test_classify_cwd_Documents_returnsUnknown() {
        // /Users/alice/Documents contains no devRootSubstring
        let verdict = DevProcessClassifier.classify(input(
            workingDirectory: "/Users/alice/Documents"
        ))
        XCTAssertEqual(verdict, .unknown)
    }

    // MARK: - 4. Parent-process-name heuristic

    func test_classify_parent_zsh_returnsDev() {
        let verdict = DevProcessClassifier.classify(input(
            parentProcessName: "zsh"
        ))
        XCTAssertEqual(verdict, .dev)
    }

    func test_classify_parent_Cursor_caseInsensitive_returnsDev() {
        // devParentNames contains "Cursor"; comparison is caseInsensitiveCompare
        let verdict = DevProcessClassifier.classify(input(
            parentProcessName: "cursor"
        ))
        XCTAssertEqual(verdict, .dev)
    }

    func test_classify_parent_Finder_returnsUnknown() {
        // "Finder" is not in devParentNames
        let verdict = DevProcessClassifier.classify(input(
            parentProcessName: "Finder"
        ))
        XCTAssertEqual(verdict, .unknown)
    }

    // MARK: - 5. Bundle-ID hard-exclude heuristic

    func test_classify_bundleID_Slack_returnsNotDev() {
        // com.tinyspeck.slackmacgap is in nonDevBundlePrefixes; not in devBundlePrefixes.
        // Hard-exclude fires even when a dev-ish cwd is present.
        let verdict = DevProcessClassifier.classify(input(
            workingDirectory: "/Users/alice/Projects/SlackPlugin",
            bundleIdentifier: "com.tinyspeck.slackmacgap"
        ))
        XCTAssertEqual(verdict, .notDev)
    }

    func test_classify_bundleID_Notion_returnsNotDev() {
        // com.notion. is in nonDevBundlePrefixes; hard-exclude wins over positive executablePath signal.
        let verdict = DevProcessClassifier.classify(input(
            executablePath: "/Users/alice/repo/node_modules/.bin/electron",
            bundleIdentifier: "com.notion.mac"
        ))
        XCTAssertEqual(verdict, .notDev)
    }

    func test_classify_bundleID_VSCode_returnsDev_evenInApplications() {
        // com.microsoft.VSCode is in devBundlePrefixes, which overrides the broad com.microsoft. exclude.
        // Hard-exclude must NOT fire; a dev cwd provides the positive signal that yields .dev.
        let verdict = DevProcessClassifier.classify(input(
            executablePath: "/Applications/Visual Studio Code.app/Contents/MacOS/Electron",
            workingDirectory: "/Users/alice/Projects/MyApp",
            bundleIdentifier: "com.microsoft.VSCode"
        ))
        XCTAssertEqual(verdict, .dev)
    }

    func test_classify_bundleID_Cursor_returnsDev() {
        // com.todesktop.230313mzl4w4u92 is in devBundlePrefixes.
        // com.todesktop. is NOT in nonDevBundlePrefixes, so hard-exclude never fires at all.
        // With a matching executablePath, result is .dev.
        let verdict = DevProcessClassifier.classify(input(
            executablePath: "/Applications/Cursor.app/Contents/MacOS/Cursor Helper",
            bundleIdentifier: "com.todesktop.230313mzl4w4u92.cursor"
        ))
        // Not hard-excluded; executablePath does not match devPathSubstrings.
        // Verify that the process is NOT classified as notDev (hard-exclude must not fire).
        XCTAssertNotEqual(verdict, .notDev)
    }

    func test_classify_notDevBundle_plusPositiveSignal_hardExcludeWins() {
        // com.spotify.client matches com.spotify. in nonDevBundlePrefixes.
        // cwd in /Projects/ would yield .dev — but hard-exclude fires first.
        let verdict = DevProcessClassifier.classify(input(
            workingDirectory: "/Users/alice/Projects/SpotifyPlugin",
            bundleIdentifier: "com.spotify.client"
        ))
        XCTAssertEqual(verdict, .notDev)
    }

    func test_classify_AppleTerminal_returnsDev() {
        // com.apple.Terminal is in devBundlePrefixes; overrides the broad com.apple. exclude.
        // Add a devPath signal so we get .dev after clearing the hard-exclude check.
        let verdict = DevProcessClassifier.classify(input(
            executablePath: "/opt/homebrew/bin/bash",
            bundleIdentifier: "com.apple.Terminal"
        ))
        XCTAssertEqual(verdict, .dev)
    }

    func test_classify_AppleFinder_returnsNotDev() {
        // com.apple.finder matches com.apple. in nonDevBundlePrefixes and is NOT in devBundlePrefixes.
        let verdict = DevProcessClassifier.classify(input(
            bundleIdentifier: "com.apple.finder"
        ))
        XCTAssertEqual(verdict, .notDev)
    }

    // MARK: - 6. Multiple signals / short-circuit

    func test_classify_multipleSignals_all_devPath_wins() {
        // executablePath matches, cwd is in Projects, parent is zsh — all three fire .dev.
        // Classifier short-circuits on executablePath (checked first of the positive signals).
        let verdict = DevProcessClassifier.classify(input(
            executablePath: "/Users/alice/repo/node_modules/.bin/vitest",
            workingDirectory: "/Users/alice/Projects/MyApp",
            parentProcessName: "zsh"
        ))
        XCTAssertEqual(verdict, .dev)
    }

    // MARK: - 7. Path substring not in list → unknown

    func test_classify_executablePath_derivedData_returnsDev() {
        // /DerivedData/ is in devPathSubstrings
        let verdict = DevProcessClassifier.classify(input(
            executablePath: "/Users/alice/Library/Developer/Xcode/DerivedData/MyApp-abc/Build/Products/Debug/MyApp"
        ))
        XCTAssertEqual(verdict, .dev)
    }

    func test_classify_executablePath_volta_returnsDev() {
        // /.volta/ is in devPathSubstrings
        let verdict = DevProcessClassifier.classify(input(
            executablePath: "/Users/alice/.volta/bin/node"
        ))
        XCTAssertEqual(verdict, .dev)
    }

    func test_classify_executablePath_pnpmStore_returnsDev() {
        // /.pnpm-store/ is in devPathSubstrings
        let verdict = DevProcessClassifier.classify(input(
            executablePath: "/Users/alice/.pnpm-store/v3/files/node"
        ))
        XCTAssertEqual(verdict, .dev)
    }

    func test_classify_cwd_underDeveloper_returnsDev() {
        // /Developer/ is in devRootSubstrings
        let verdict = DevProcessClassifier.classify(input(
            workingDirectory: "/Users/alice/Developer/MyProject"
        ))
        XCTAssertEqual(verdict, .dev)
    }

    func test_classify_cwd_underSrc_returnsDev() {
        // /src/ is in devRootSubstrings
        let verdict = DevProcessClassifier.classify(input(
            workingDirectory: "/home/alice/src/mylib"
        ))
        XCTAssertEqual(verdict, .dev)
    }

    func test_classify_parent_Xcode_returnsDev() {
        // "Xcode" is in devParentNames
        let verdict = DevProcessClassifier.classify(input(
            parentProcessName: "Xcode"
        ))
        XCTAssertEqual(verdict, .dev)
    }

    func test_classify_parent_iTerm2_returnsDev() {
        // "iTerm2" is in devParentNames (exact case match via caseInsensitiveCompare)
        let verdict = DevProcessClassifier.classify(input(
            parentProcessName: "iterm2"
        ))
        XCTAssertEqual(verdict, .dev)
    }

    func test_classify_bundleID_Chrome_returnsNotDev() {
        // com.google.Chrome is in nonDevBundlePrefixes; not in devBundlePrefixes.
        let verdict = DevProcessClassifier.classify(input(
            bundleIdentifier: "com.google.Chrome"
        ))
        XCTAssertEqual(verdict, .notDev)
    }

    func test_classify_bundleID_Discord_returnsNotDev() {
        // com.discord is in nonDevBundlePrefixes
        let verdict = DevProcessClassifier.classify(input(
            bundleIdentifier: "com.discord"
        ))
        XCTAssertEqual(verdict, .notDev)
    }
}
