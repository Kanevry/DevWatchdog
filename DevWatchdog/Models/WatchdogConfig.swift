import Foundation
import ServiceManagement
import Combine

@MainActor
class WatchdogConfig: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var scanInterval: TimeInterval {
        didSet { defaults.set(scanInterval, forKey: "scanInterval") }
    }
    @Published var orphanTimeout: TimeInterval {
        didSet { defaults.set(orphanTimeout, forKey: "orphanTimeout") }
    }
    @Published var gracePeriod: TimeInterval {
        didSet { defaults.set(gracePeriod, forKey: "gracePeriod") }
    }
    @Published var rules: [ProcessRule] {
        didSet { saveRules() }
    }
    @Published var launchAtLogin: Bool {
        didSet {
            defaults.set(launchAtLogin, forKey: "launchAtLogin")
            updateLoginItem()
        }
    }
    @Published var soundOnCritical: Bool {
        didSet { defaults.set(soundOnCritical, forKey: "soundOnCritical") }
    }
    @Published var catchAllMaxRuntime: TimeInterval {
        didSet { defaults.set(catchAllMaxRuntime, forKey: "catchAllMaxRuntime") }
    }
    @Published var excludedApps: [String] {
        didSet { saveExcludedApps() }
    }
    @Published var inclusionPatterns: [String] {
        didSet { saveInclusionPatterns() }
    }

    // MARK: - Emergency Mode (issues #4 / #6)

    /// Master switch for Emergency Mode. When false, `ProcessMonitor` uses
    /// the static `scanInterval` / `gracePeriod` regardless of pressure.
    @Published var emergencyModeEnabled: Bool {
        didSet { defaults.set(emergencyModeEnabled, forKey: "emergencyModeEnabled") }
    }
    /// `loadFactor` above this promotes the emergency state.
    @Published var emergencyLoadFactor: Double {
        didSet { defaults.set(emergencyLoadFactor, forKey: "emergencyLoadFactor") }
    }
    /// `loadFactor` above this promotes the elevated state.
    @Published var elevatedLoadFactor: Double {
        didSet { defaults.set(elevatedLoadFactor, forKey: "elevatedLoadFactor") }
    }
    /// Dwell time required in a lower state before a downward transition is permitted.
    @Published var emergencyCooldown: TimeInterval {
        didSet { defaults.set(emergencyCooldown, forKey: "emergencyCooldown") }
    }
    /// Hint to prefer SIGSTOP+renice over SIGTERM during emergency triage (Wave 4+).
    @Published var softKillPreferred: Bool {
        didSet { defaults.set(softKillPreferred, forKey: "softKillPreferred") }
    }
    /// Minimum process age (seconds) required before emergency promotion to zombie.
    @Published var emergencyMinAgeSeconds: TimeInterval {
        didSet { defaults.set(emergencyMinAgeSeconds, forKey: "emergencyMinAgeSeconds") }
    }
    /// Timeout (seconds) for the ps subprocess before it is killed and treated as a failure.
    @Published var psTimeoutSeconds: TimeInterval {
        didSet { defaults.set(psTimeoutSeconds, forKey: "psTimeoutSeconds") }
    }
    /// Feature flag: use the native libproc enumerator instead of the /bin/ps subprocess.
    /// Opt-in only (default false) during the G5 rollout. Takes effect on the next scan.
    @Published var useLibprocEnumerator: Bool {
        didSet { defaults.set(useLibprocEnumerator, forKey: "useLibprocEnumerator") }
    }
    /// Feature flag: enable cwd-based project detection via proc_pidinfo(PROC_PIDVNODEPATHINFO)
    /// in the libproc enumerator path. Requires `useLibprocEnumerator = true` to take effect
    /// (PSParser path cannot cheaply provide cwd). Opt-in only (default false).
    /// Addresses: GitLab #35 (G2).
    @Published var useCwdProjectDetection: Bool {
        didSet { defaults.set(useCwdProjectDetection, forKey: "useCwdProjectDetection") }
    }
    /// Feature flag: enable the signal-based dev-process classifier
    /// (executable-path, cwd, parent-chain, bundle-ID heuristics) in place of the
    /// wordlist-only inclusion filter. When the classifier returns .unknown, the
    /// legacy wordlist filter still runs as a fallback. Opt-in only (default false).
    /// Addresses: GitLab #36 (G1).
    @Published var useSignalClassifier: Bool {
        didSet { defaults.set(useSignalClassifier, forKey: "useSignalClassifier") }
    }

    static let defaultInclusionPatterns = [
        "node", "vitest", "jest", "tsc", "tsgo", "esbuild", "next", "webpack",
        "turbo", "eslint", "prettier", "mcp", "pnpm", "npm run", "yarn",
        "playwright", "ms-playwright", "percy", "react-email", "bun", "deno", "swc",
    ]

    static let defaultExcludedApps = [
        "/Notion.app/", "/Slack.app/", "/Discord.app/",
        "/Spotify.app/", "/Figma.app/", "/1Password.app/",
        "/Microsoft", "/Linear.app/", "/Obsidian.app/",
        "/WhatsApp.app/", "/Telegram.app/", "/Signal.app/",
        "/zoom.us.app/", "/Google Chrome.app/", "/Firefox.app/",
        "/Safari.app/", "/Arc.app/", "/Brave Browser.app/",
    ]

    init() {
        let d = UserDefaults.standard

        self.scanInterval = d.double(forKey: "scanInterval").nonZero ?? 30
        self.orphanTimeout = d.double(forKey: "orphanTimeout").nonZero ?? 120
        self.gracePeriod = d.double(forKey: "gracePeriod").nonZero ?? 30
        self.catchAllMaxRuntime = d.double(forKey: "catchAllMaxRuntime").nonZero ?? 28800 // 8h
        self.launchAtLogin = d.bool(forKey: "launchAtLogin")
        self.soundOnCritical = d.object(forKey: "soundOnCritical") != nil ? d.bool(forKey: "soundOnCritical") : true

        // Emergency Mode defaults — use object-presence check for bools so an
        // absent key picks up the hard-coded default (mirrors `soundOnCritical`).
        self.emergencyModeEnabled = d.object(forKey: "emergencyModeEnabled") != nil
            ? d.bool(forKey: "emergencyModeEnabled")
            : true
        self.emergencyLoadFactor = d.double(forKey: "emergencyLoadFactor").nonZero ?? 2.0
        self.elevatedLoadFactor = d.double(forKey: "elevatedLoadFactor").nonZero ?? 1.0
        self.emergencyCooldown = d.double(forKey: "emergencyCooldown").nonZero ?? 30
        self.softKillPreferred = d.object(forKey: "softKillPreferred") != nil
            ? d.bool(forKey: "softKillPreferred")
            : true
        self.emergencyMinAgeSeconds = d.double(forKey: "emergencyMinAgeSeconds").nonZero ?? 60
        self.psTimeoutSeconds = d.double(forKey: "psTimeoutSeconds").nonZero ?? 10
        self.useLibprocEnumerator = d.object(forKey: "useLibprocEnumerator") as? Bool ?? false
        self.useCwdProjectDetection = d.object(forKey: "useCwdProjectDetection") as? Bool ?? false
        self.useSignalClassifier    = d.object(forKey: "useSignalClassifier")    as? Bool ?? false

        // Load rules
        if let data = d.data(forKey: "processRules"),
           let decoded = try? JSONDecoder().decode([ProcessRule].self, from: data) {
            self.rules = decoded
        } else {
            self.rules = ProcessRule.defaultRules
        }

        // Load excluded apps
        if let data = d.data(forKey: "excludedApps"),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            self.excludedApps = decoded
        } else {
            self.excludedApps = Self.defaultExcludedApps
        }

        // Load inclusion patterns
        if let data = d.data(forKey: "inclusionPatterns"),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            self.inclusionPatterns = decoded
        } else {
            self.inclusionPatterns = Self.defaultInclusionPatterns
        }
    }

    func isWhitelisted(_ process: DevProcess) -> Bool {
        rules.contains { rule in
            rule.isEnabled && rule.action == .whitelist && rule.matches(process)
        }
    }

    func matchingRule(for process: DevProcess) -> ProcessRule? {
        rules.first { rule in
            rule.isEnabled && rule.matches(process)
        }
    }

    func resetToDefaults() {
        scanInterval = 30
        orphanTimeout = 120
        gracePeriod = 30
        catchAllMaxRuntime = 28800
        rules = ProcessRule.defaultRules
        soundOnCritical = true
        excludedApps = Self.defaultExcludedApps
        inclusionPatterns = Self.defaultInclusionPatterns
        emergencyModeEnabled = true
        emergencyLoadFactor = 2.0
        elevatedLoadFactor = 1.0
        emergencyCooldown = 30
        softKillPreferred = true
        emergencyMinAgeSeconds = 60
        psTimeoutSeconds = 10
        useLibprocEnumerator = false
        useCwdProjectDetection = false
        useSignalClassifier    = false
    }

    private func saveExcludedApps() {
        if let data = try? JSONEncoder().encode(excludedApps) {
            defaults.set(data, forKey: "excludedApps")
        }
    }

    private func saveInclusionPatterns() {
        if let data = try? JSONEncoder().encode(inclusionPatterns) {
            defaults.set(data, forKey: "inclusionPatterns")
        }
    }

    private func saveRules() {
        if let data = try? JSONEncoder().encode(rules) {
            defaults.set(data, forKey: "processRules")
        }
    }

    private func updateLoginItem() {
        if launchAtLogin {
            try? SMAppService.mainApp.register()
        } else {
            try? SMAppService.mainApp.unregister()
        }
    }
}

private extension Double {
    var nonZero: Double? {
        self == 0 ? nil : self
    }
}
