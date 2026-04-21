import Foundation

/// Resolves a filesystem path to its nearest "project root" by walking ancestors,
/// looking for well-known project markers. Leaf-wins for monorepos (deepest marker wins).
///
/// Pure, Sendable, side-effect-free — safe to call from any actor.
///
/// Addresses: GitLab #35 (G2)
public enum ProjectRootResolver: Sendable {

    /// Ordered list of project-root markers. Presence of any one triggers a match.
    /// Ordering does not imply priority — the deepest directory containing ANY marker wins.
    public static let markers: [String] = [
        ".git",
        "package.json",
        "Cargo.toml",
        "go.mod",
        "pyproject.toml",
        "Podfile",
        "Package.swift",
    ]

    /// Walk ancestors of `startPath` and return the deepest directory containing any marker,
    /// represented as its last path component (the project name). Returns nil if no marker found
    /// before reaching the filesystem root.
    ///
    /// For `~/Projects/Archiv/DevWatchdog/` with `.git` in `DevWatchdog/`, returns "DevWatchdog".
    /// For `~/Projects/Archiv/` with `.git` in `Archiv/` AND `~/Projects/Archiv/DevWatchdog/` also
    /// containing `.git`, the deepest match (`DevWatchdog`) wins.
    public static func projectName(for startPath: String, fileManager: FileManager = .default) -> String? {
        guard !startPath.isEmpty else { return nil }

        var current = (startPath as NSString).standardizingPath
        // Ensure we start from a directory — if startPath is a file, climb to parent.
        // (For cwd inputs from proc_pidinfo this will already be a directory, but handle both.)

        let fsRoot = "/"
        while current != fsRoot && !current.isEmpty {
            if hasMarker(in: current, fileManager: fileManager) {
                return (current as NSString).lastPathComponent
            }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current { break }
            current = parent
        }
        return nil
    }

    // MARK: - Private helpers

    private static func hasMarker(in directory: String, fileManager: FileManager) -> Bool {
        for marker in markers {
            let candidate = (directory as NSString).appendingPathComponent(marker)
            if fileManager.fileExists(atPath: candidate) { return true }
        }
        return false
    }
}
