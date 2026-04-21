import XCTest
@testable import DevWatchdog

/// Comprehensive tests for ProjectRootResolver.projectName(for:fileManager:).
///
/// Covers: empty input, no-marker tree, marker at start path, marker in ancestor,
/// leaf-wins for nested repos (deepest marker wins), all 7 marker types,
/// real-repo regression guard, and nonexistent path.
final class ProjectRootResolverTests: XCTestCase {

    // MARK: - Fixture tmpdir

    /// Unique tmpdir created in setUp() and removed in tearDown().
    nonisolated(unsafe) private var tmpDir: URL!

    override func setUp() {
        super.setUp()
        let unique = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectRootResolverTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: unique, withIntermediateDirectories: true)
        tmpDir = unique.standardizedFileURL
    }

    override func tearDown() {
        if let dir = tmpDir {
            try? FileManager.default.removeItem(at: dir)
        }
        tmpDir = nil
        super.tearDown()
    }

    // MARK: - Helpers

    /// Creates a directory (and all parents) under the test tmpdir.
    private func makeDir(_ relativePath: String) throws -> URL {
        let url = tmpDir.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.standardizedFileURL
    }

    /// Creates an empty file (and all parents) at the given URL path.
    private func makeFile(at path: String) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: path, contents: nil)
    }

    // MARK: - 1. Empty path

    func test_projectName_returnsNil_forEmptyPath() {
        let result = ProjectRootResolver.projectName(for: "")
        XCTAssertNil(result, "empty string input must return nil")
    }

    // MARK: - 2. No marker anywhere in the tree

    func test_projectName_returnsNil_whenNoMarkerFound() throws {
        // Build /tmp/.../a/b/c/ with no markers anywhere
        let deepDir = try makeDir("a/b/c")
        let result = ProjectRootResolver.projectName(for: deepDir.path)
        XCTAssertNil(result, "walker must return nil when no marker exists in any ancestor")
    }

    // MARK: - 3. Marker at the start path itself

    func test_projectName_findsMarkerAtStartPath() throws {
        // /tmp/.../MyProject/.git  →  pass "/tmp/.../MyProject"
        let projectDir = try makeDir("MyProject")
        try makeFile(at: projectDir.appendingPathComponent(".git").path)

        let result = ProjectRootResolver.projectName(for: projectDir.path)
        XCTAssertEqual(result, "MyProject", "marker at start path must return that directory's name")
    }

    // MARK: - 4. Marker in an ancestor

    func test_projectName_findsMarkerInAncestor() throws {
        // /tmp/.../MyProject/.git  +  /tmp/.../MyProject/src/nested/deep/
        let projectDir = try makeDir("MyProject")
        try makeFile(at: projectDir.appendingPathComponent(".git").path)
        let deepDir = try makeDir("MyProject/src/nested/deep")

        let result = ProjectRootResolver.projectName(for: deepDir.path)
        XCTAssertEqual(result, "MyProject", "walker must climb ancestors and return the matching directory name")
    }

    // MARK: - 5. Leaf wins for nested repos (deepest marker wins)

    func test_projectName_leafWins_forNestedRepos() throws {
        // /tmp/.../Monorepo/.git          — outer repo root
        // /tmp/.../Monorepo/packages/Web/package.json  — inner package root
        // pass:  /tmp/.../Monorepo/packages/Web/src/
        // expect: "Web" (package.json at Web/ is deeper than .git at Monorepo/)
        let monorepoDir = try makeDir("Monorepo")
        try makeFile(at: monorepoDir.appendingPathComponent(".git").path)

        let webDir = try makeDir("Monorepo/packages/Web")
        try makeFile(at: webDir.appendingPathComponent("package.json").path)

        let srcDir = try makeDir("Monorepo/packages/Web/src")

        let result = ProjectRootResolver.projectName(for: srcDir.path)
        XCTAssertEqual(result, "Web",
            "deepest marker must win: package.json at Web/ beats .git at Monorepo/")
    }

    // MARK: - 6. All 7 marker types are detected

    func test_projectName_multipleMarkerTypes() throws {
        // For each marker type, create a fresh subdirectory, drop the marker, assert detection.
        let markerCases: [(marker: String, dirName: String)] = [
            (".git",          "Proj_git"),
            ("package.json",  "Proj_npm"),
            ("Cargo.toml",    "Proj_rust"),
            ("go.mod",        "Proj_go"),
            ("pyproject.toml","Proj_python"),
            ("Podfile",       "Proj_cocoa"),
            ("Package.swift", "Proj_spm"),
        ]

        for (marker, dirName) in markerCases {
            let projectDir = try makeDir(dirName)
            try makeFile(at: projectDir.appendingPathComponent(marker).path)

            let result = ProjectRootResolver.projectName(for: projectDir.path)
            XCTAssertEqual(result, dirName,
                "marker '\(marker)' must be detected and return project name '\(dirName)'")

            // Clean up so the next iteration's ancestor walk doesn't see leftover markers
            try FileManager.default.removeItem(at: projectDir)
        }
    }

    // MARK: - 7. Real-repo regression guard

    func test_projectName_devwatchdogRepo_returnsDevWatchdog() {
        // The DevWatchdog repo contains a .git directory at its root.
        // This is the canonical regression guard from GitLab #35 G2.
        let repoPath = "/Users/bernhardgoetzendorfer/Projects/Archiv/DevWatchdog"
        let result = ProjectRootResolver.projectName(for: repoPath)
        XCTAssertEqual(result, "DevWatchdog",
            "real repo path must resolve to 'DevWatchdog', not 'Archiv' or nil")
    }

    // MARK: - 8. Nonexistent path

    func test_projectName_nonexistentPath() {
        let result = ProjectRootResolver.projectName(for: "/nonexistent/path/to/nowhere")
        XCTAssertNil(result, "walker must return nil for a path that does not exist on disk")
    }
}
