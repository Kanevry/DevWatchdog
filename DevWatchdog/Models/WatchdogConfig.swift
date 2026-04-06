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
    }

    private func saveExcludedApps() {
        if let data = try? JSONEncoder().encode(excludedApps) {
            defaults.set(data, forKey: "excludedApps")
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
