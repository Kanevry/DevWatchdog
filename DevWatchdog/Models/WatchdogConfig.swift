import Foundation
import ServiceManagement
import Combine

enum KillMode: String, CaseIterable {
    case smart = "smart"
    case notificationOnly = "notification_only"
    case aggressive = "aggressive"

    var displayName: String {
        switch self {
        case .smart: return "Smart Auto-Kill"
        case .notificationOnly: return "Notification Only"
        case .aggressive: return "Aggressive Auto-Kill"
        }
    }

    var description: String {
        switch self {
        case .smart: return "Kills orphan zombies after grace period"
        case .notificationOnly: return "Never kills automatically, only warns"
        case .aggressive: return "Kills matching processes immediately"
        }
    }
}

@MainActor
class WatchdogConfig: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var killMode: KillMode {
        didSet { defaults.set(killMode.rawValue, forKey: "killMode") }
    }
    @Published var scanInterval: TimeInterval {
        didSet { defaults.set(scanInterval, forKey: "scanInterval") }
    }
    @Published var gracePeriod: TimeInterval {
        didSet { defaults.set(gracePeriod, forKey: "gracePeriod") }
    }
    @Published var cpuThreshold: Double {
        didSet { defaults.set(cpuThreshold, forKey: "cpuThreshold") }
    }
    @Published var runtimeThreshold: TimeInterval {
        didSet { defaults.set(runtimeThreshold, forKey: "runtimeThreshold") }
    }
    @Published var projectDirectories: [String] {
        didSet { defaults.set(projectDirectories, forKey: "projectDirectories") }
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
    @Published var criticalCPUThreshold: Double {
        didSet { defaults.set(criticalCPUThreshold, forKey: "criticalCPUThreshold") }
    }

    init() {
        let d = UserDefaults.standard

        self.killMode = KillMode(rawValue: d.string(forKey: "killMode") ?? "") ?? .smart
        self.scanInterval = d.double(forKey: "scanInterval").nonZero ?? 30
        self.gracePeriod = d.double(forKey: "gracePeriod").nonZero ?? 30
        self.cpuThreshold = d.double(forKey: "cpuThreshold").nonZero ?? 80
        self.runtimeThreshold = d.double(forKey: "runtimeThreshold").nonZero ?? 900
        self.projectDirectories = d.stringArray(forKey: "projectDirectories") ?? ["~/Projects/"]
        self.launchAtLogin = d.bool(forKey: "launchAtLogin")
        self.soundOnCritical = d.object(forKey: "soundOnCritical") != nil ? d.bool(forKey: "soundOnCritical") : true
        self.criticalCPUThreshold = d.double(forKey: "criticalCPUThreshold").nonZero ?? 500

        // Load rules
        if let data = d.data(forKey: "processRules"),
           let decoded = try? JSONDecoder().decode([ProcessRule].self, from: data) {
            self.rules = decoded
        } else {
            self.rules = ProcessRule.defaultRules
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
        killMode = .smart
        scanInterval = 30
        gracePeriod = 30
        cpuThreshold = 80
        runtimeThreshold = 900
        projectDirectories = ["~/Projects/"]
        rules = ProcessRule.defaultRules
        soundOnCritical = true
        criticalCPUThreshold = 500
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
