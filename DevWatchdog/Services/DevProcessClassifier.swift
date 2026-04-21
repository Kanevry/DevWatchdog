import Foundation

/// Pure, Sendable classifier deciding whether a process is a "dev process" using orthogonal signals.
/// Replaces the wordlist-based inclusion filter used by the legacy and libproc enumerator paths.
///
/// Each signal is independent — classifier returns `.dev` when ANY signal matches, `.notDev` when
/// any hard-exclude signal matches (bundle-ID heuristic in /Applications/), `.unknown` otherwise.
///
/// NOTE: This is the **pre-filter classifier** (decides "enter watch list?").
/// It is distinct from `ProcessSignalsAnalyzer`, which generates post-enumeration
/// badges (orphan confidence, rule match, memory leak) for already-watched processes.
///
/// Addresses: GitLab #36 (G1)
public enum DevProcessClassifier: Sendable {

    /// Input bundle — callers gather what they have and pass it in. Missing fields reduce
    /// classifier confidence but never cause an error. ALL fields are optional.
    public struct Input: Sendable {
        /// Full executable path from proc_pidpath, e.g. "/Users/alice/.local/bin/vitest".
        public let executablePath: String?
        /// Current working directory from proc_pidinfo(PROC_PIDVNODEPATHINFO).
        public let workingDirectory: String?
        /// Parent process name (16-char comm from ppid lookup), e.g. "zsh", "Cursor", "Xcode".
        public let parentProcessName: String?
        /// Bundle identifier when the executable lives under /Applications/, e.g. "com.apple.dt.Xcode".
        public let bundleIdentifier: String?

        public init(
            executablePath: String? = nil,
            workingDirectory: String? = nil,
            parentProcessName: String? = nil,
            bundleIdentifier: String? = nil
        ) {
            self.executablePath = executablePath
            self.workingDirectory = workingDirectory
            self.parentProcessName = parentProcessName
            self.bundleIdentifier = bundleIdentifier
        }
    }

    public enum Verdict: Sendable, Equatable {
        case dev      // at least one positive signal fired, no hard-exclude
        case notDev   // hard-exclude fired (signed-by-non-dev vendor in /Applications/)
        case unknown  // nothing matched — caller falls back to legacy wordlists
    }

    /// Dev user-tool directories (executable-path heuristic). Paths are treated as substrings.
    /// Keep this list tight — ubiquitous paths like /usr/bin/ MUST NOT appear here (too broad).
    public static let devPathSubstrings: [String] = [
        "/node_modules/.bin/",
        "/.pnpm-store/",
        "/.pnpm/",
        "/.volta/",
        "/.nvm/",
        "/.cargo/bin/",
        "/.rustup/",
        "/go/bin/",
        "/.venv/",
        "/.pyenv/",
        "/homebrew/bin/",
        "/usr/local/bin/",                // Homebrew default
        "/opt/homebrew/bin/",              // Apple Silicon Homebrew
        "/Library/Developer/Toolchains/",  // Xcode swift toolchain
        "/DerivedData/",
    ]

    /// Dev-user parent process names — shells and IDEs known to spawn dev tools.
    public static let devParentNames: [String] = [
        "zsh", "bash", "fish",
        "iTerm2", "Warp", "Terminal",
        "Code", "Code Helper", "Code - Insiders",
        "Cursor", "Cursor Helper",
        "Xcode",
    ]

    /// Bundle-ID prefixes that are definitively NOT dev tools (hard-exclude when under /Applications/).
    /// Signed-by-vendor bundles for consumer apps that spawn Electron/node internally.
    public static let nonDevBundlePrefixes: [String] = [
        "com.apple.",          // Native Apple apps — not user dev work
        "com.microsoft.",      // Office, Teams (NOTE: excludes VSCode — see dev-allowlist below)
        "com.google.Chrome",
        "com.spotify.",
        "com.notion.",
        "com.slack.",
        "com.discord",
        "com.tinyspeck.slackmacgap",
        "com.zoom.",
        "us.zoom.",
        "com.figma.",
        "com.agilebits.onepassword",
        "com.linear.",
        "md.obsidian",
        "net.whatsapp.",
        "ru.keepcoder.Telegram",
        "org.whispersystems.signal-desktop",
        "org.mozilla.firefox",
        "com.apple.Safari",
        "company.thebrowser.Browser",         // Arc
        "com.brave.Browser",
    ]

    /// Bundle-ID prefixes that override nonDevBundlePrefixes — dev tools shipped as signed apps.
    /// A process matching both lists is classified as dev (the narrower dev-allowlist wins).
    public static let devBundlePrefixes: [String] = [
        "com.microsoft.VSCode",          // VSCode + Insiders
        "com.todesktop.230313mzl4w4u92", // Cursor (electron app wrapper)
        "com.googlecode.iterm2",
        "com.apple.Terminal",
        "dev.warp.Warp-Stable",
    ]

    public static func classify(_ input: Input) -> Verdict {
        // Hard-exclude FIRST — never classify a consumer Electron app as dev, even if its spawned
        // node process happens to live under a dev-ish working directory.
        if let bundleID = input.bundleIdentifier,
           nonDevBundlePrefixes.contains(where: { bundleID.hasPrefix($0) }),
           !devBundlePrefixes.contains(where: { bundleID.hasPrefix($0) }) {
            return .notDev
        }

        // Positive signals — any ONE firing yields .dev.
        if let path = input.executablePath,
           devPathSubstrings.contains(where: { path.contains($0) }) {
            return .dev
        }
        if let cwd = input.workingDirectory, isInDevRoot(cwd) {
            return .dev
        }
        if let parent = input.parentProcessName,
           devParentNames.contains(where: { parent.caseInsensitiveCompare($0) == .orderedSame }) {
            return .dev
        }

        return .unknown
    }

    /// cwd heuristic: under `~/Projects/`, `~/Developer/`, `~/Code/`, or inside a dev workspace.
    ///
    /// This is a CHEAP substring form — the more precise git-repo form lives in
    /// `ProjectRootResolver` and is used by G2 (post-enrollment project root detection).
    private static func isInDevRoot(_ path: String) -> Bool {
        let devRootSubstrings = [
            "/Projects/",
            "/Developer/",
            "/Code/",
            "/repos/",
            "/src/",
            "/workspace/",
            "/Sites/",
            "/.pnpm/",
            "/node_modules/",
        ]
        return devRootSubstrings.contains(where: { path.contains($0) })
    }
}
