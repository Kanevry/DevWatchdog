import SwiftUI

struct SettingsView: View {
    @ObservedObject var config: WatchdogConfig
    /// Optional — supplied by call sites that want to show the live "Aktuelle Werte"
    /// panel on the Emergency tab. Defaults to `nil` so existing call sites
    /// (e.g. `DevWatchdogApp.openSettings()`) continue to compile without change.
    /// Wave 5 coordinator: pass the app's shared `ProcessMonitor` here to enable
    /// the live readout.
    var monitor: ProcessMonitor?
    @State private var newRulePattern = ""
    @State private var showingResetConfirmation = false
    @State private var newExcludedApp = ""
    @State private var newInclusionPattern = ""

    init(config: WatchdogConfig, monitor: ProcessMonitor? = nil) {
        self.config = config
        self.monitor = monitor
    }

    var body: some View {
        TabView {
            generalTab
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            rulesTab
                .tabItem {
                    Label("Rules", systemImage: "list.bullet.rectangle")
                }

            emergencyTab
                .tabItem {
                    Label("Emergency", systemImage: "bolt.shield.fill")
                }

            aboutTab
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .frame(minWidth: 480, minHeight: 500)
        .padding()
    }

    // MARK: - Emergency Tab

    @ViewBuilder
    private var emergencyTab: some View {
        if let monitor {
            EmergencySettingsView(config: config, monitor: monitor)
        } else {
            // No monitor injected — render settings without the live readout.
            EmergencySettingsViewNoLive(config: config)
        }
    }

    // MARK: - General Tab

    private var generalTab: some View {
        Form {
            Section("Auto-Kill") {
                HStack(spacing: 6) {
                    Circle()
                        .fill(.green)
                        .frame(width: 8, height: 8)
                    Text("Auto-Kill active")
                        .fontWeight(.medium)
                }
                Text("Orphaned dev processes are automatically killed after the grace period.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Timing") {
                LabeledContent("Scan interval") {
                    HStack {
                        Slider(value: $config.scanInterval, in: 10...120, step: 5)
                            .frame(maxWidth: 200)
                        Text("\(Int(config.scanInterval))s")
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                }

                LabeledContent("Orphan timeout") {
                    HStack {
                        Slider(value: $config.orphanTimeout, in: 30...600, step: 10)
                            .frame(maxWidth: 200)
                        Text(formatDuration(config.orphanTimeout))
                            .monospacedDigit()
                            .frame(width: 50, alignment: .trailing)
                    }
                }
                Text("How long an orphaned process may live before it's marked as zombie.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledContent("Grace period") {
                    HStack {
                        Slider(value: $config.gracePeriod, in: 10...120, step: 5)
                            .frame(maxWidth: 200)
                        Text("\(Int(config.gracePeriod))s")
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                }
                Text("Warning time before a zombie is killed. You can intervene during this time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledContent("Catch-all kill") {
                    HStack {
                        Slider(value: $config.catchAllMaxRuntime, in: 3600...86400, step: 3600)
                            .frame(maxWidth: 200)
                        Text(formatDuration(config.catchAllMaxRuntime))
                            .monospacedDigit()
                            .frame(width: 50, alignment: .trailing)
                    }
                }
                Text("Any dev process without a specific rule running longer than this is killed. Safety net.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Notifications") {
                Toggle("Sound alerts", isOn: $config.soundOnCritical)
            }

            Section("System") {
                Toggle("Launch at login", isOn: $config.launchAtLogin)
            }

            Section("Excluded Apps") {
                Text("Processes from these apps are never shown as suspects.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(config.excludedApps, id: \.self) { app in
                    HStack {
                        Text(app)
                            .font(.system(.caption, design: .monospaced))
                        Spacer()
                        Button {
                            config.excludedApps.removeAll { $0 == app }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }

                HStack {
                    TextField("e.g. /MyApp.app/", text: $newExcludedApp)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                    Button("Add") {
                        guard !newExcludedApp.isEmpty else { return }
                        config.excludedApps.append(newExcludedApp)
                        newExcludedApp = ""
                    }
                    .disabled(newExcludedApp.isEmpty)
                }
            }

            Section("Dev Filter") {
                Text("Only processes matching at least one of these keywords are tracked by DevWatchdog.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(config.inclusionPatterns, id: \.self) { pattern in
                    HStack {
                        Text(pattern)
                            .font(.system(.caption, design: .monospaced))
                        Spacer()
                        Button {
                            config.inclusionPatterns.removeAll { $0 == pattern }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }

                HStack {
                    TextField("e.g. rollup", text: $newInclusionPattern)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                    Button("Add") {
                        guard !newInclusionPattern.isEmpty else { return }
                        config.inclusionPatterns.append(newInclusionPattern)
                        newInclusionPattern = ""
                    }
                    .disabled(newInclusionPattern.isEmpty)
                }
            }

            Section {
                Button("Reset to Defaults") {
                    showingResetConfirmation = true
                }
                .alert("Reset all settings?", isPresented: $showingResetConfirmation) {
                    Button("Reset", role: .destructive) {
                        config.resetToDefaults()
                    }
                    Button("Cancel", role: .cancel) {}
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Rules Tab

    private var rulesTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Process Rules")
                .font(.headline)
            Text("Define how DevWatchdog handles specific process patterns. Orphaned processes are always auto-killed regardless of rules (unless whitelisted).")
                .font(.caption)
                .foregroundStyle(.secondary)

            List {
                ForEach($config.rules) { $rule in
                    ruleRow(rule: $rule)
                }
                .onDelete(perform: deleteRules)
            }
            .frame(minHeight: 250)

            Divider()

            // Add new rule
            HStack {
                TextField("Pattern (e.g. next.*dev)", text: $newRulePattern)
                    .textFieldStyle(.roundedBorder)

                Button("Add Rule") {
                    guard !newRulePattern.isEmpty else { return }
                    let rule = ProcessRule(
                        id: UUID(),
                        pattern: newRulePattern,
                        cpuThreshold: 50,
                        runtimeThreshold: 1800,
                        maxRuntime: 3600,
                        action: .warn,
                        isEnabled: true
                    )
                    config.rules.append(rule)
                    newRulePattern = ""
                }
                .disabled(newRulePattern.isEmpty)
            }
        }
        .padding()
    }

    private func ruleRow(rule: Binding<ProcessRule>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Toggle(isOn: rule.isEnabled) {
                    Text(rule.wrappedValue.pattern)
                        .font(.system(.body, design: .monospaced))
                        .fontWeight(.medium)
                }

                Spacer()

                Picker("Action", selection: rule.action) {
                    ForEach(ProcessRule.RuleAction.allCases, id: \.self) { action in
                        Text(action.displayName).tag(action)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 180)
            }

            if rule.wrappedValue.action == .warn {
                HStack(spacing: 12) {
                    HStack(spacing: 4) {
                        Text("Warn:")
                            .foregroundStyle(.secondary)
                        TextField("CPU %", value: rule.cpuThreshold, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 50)
                        Text("% CPU")
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 4) {
                        TextField("Seconds", value: rule.runtimeThreshold, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 60)
                        Text("s (\(formatDuration(rule.wrappedValue.runtimeThreshold)))")
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 4) {
                        Text("Kill:")
                            .foregroundStyle(.red)
                        TextField("Max s", value: rule.maxRuntime, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 60)
                        Text("s (\(formatDuration(rule.wrappedValue.maxRuntime)))")
                            .foregroundStyle(.red.opacity(0.7))
                    }
                }
                .font(.caption)

                advancedThresholds(rule: rule)
            }
        }
        .padding(.vertical, 4)
    }

    /// Absolute-threshold editor (issue #5) — CPU%, RSS (MB), and combinator.
    /// Rendered as a disclosure group to keep the row compact by default.
    private func advancedThresholds(rule: Binding<ProcessRule>) -> some View {
        DisclosureGroup("Erweitert (absolute Limits)") {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    HStack(spacing: 4) {
                        Text("Max CPU:")
                            .foregroundStyle(.red)
                        TextField("0", value: rule.maxCPUPercent, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 60)
                            .help("0 = deaktiviert. CPU% über diesem Wert → sofortiger Kill.")
                        Text("%")
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 4) {
                        Text("Max RSS:")
                            .foregroundStyle(.red)
                        TextField("0", value: rule.maxRSSMB, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 70)
                            .help("0 = deaktiviert. RSS (MB) über diesem Wert → sofortiger Kill.")
                        Text("MB")
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                }

                HStack(spacing: 6) {
                    Text("Kombination:")
                        .foregroundStyle(.secondary)
                    Picker("", selection: rule.thresholdMode) {
                        ForEach(ProcessRule.ThresholdMode.allCases, id: \.self) { mode in
                            Text(thresholdModeLabel(mode)).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 260)
                    .help("Any = mind. eine Schwelle ausreicht. All = alle konfigurierten Schwellen müssen überschritten sein.")
                }

                Text("0 = deaktiviert. Gilt zusammen mit „Kill: Max s“ als harte Kill-Limits.")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .padding(.top, 4)
        }
        .font(.caption)
    }

    private func thresholdModeLabel(_ mode: ProcessRule.ThresholdMode) -> String {
        switch mode {
        case .any: return "Mindestens eine (ODER)"
        case .all: return "Alle (UND)"
        }
    }

    private func deleteRules(at offsets: IndexSet) {
        config.rules.remove(atOffsets: offsets)
    }

    // MARK: - About Tab

    private var aboutTab: some View {
        VStack(spacing: 16) {
            appIcon
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 96, height: 96)

            Text("DevWatchdog")
                .font(.title)
                .fontWeight(.bold)

            Text("v2.0.0")
                .foregroundStyle(.secondary)

            Text("Automatic cleanup of zombie Node.js processes on macOS.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                InfoRow(label: "Author", value: "Bernhard Goetzendorfer")
                InfoRow(label: "License", value: "MIT")
                InfoRow(label: "GitHub", value: "github.com/Kanevry/DevWatchdog")
            }
            .font(.caption)

            Spacer()
        }
        .padding()
    }

    // MARK: - Helpers

    /// Load app icon directly from bundle (NSApp.applicationIconImage doesn't work for LSUIElement apps)
    private var appIcon: Image {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let nsImage = NSImage(contentsOf: url) {
            return Image(nsImage: nsImage)
        }
        // Fallback to NSApp icon
        return Image(nsImage: NSApp.applicationIconImage)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        if mins >= 60 {
            return "\(mins / 60)h \(mins % 60)m"
        }
        return "\(mins)m"
    }
}

private struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label + ":")
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .trailing)
            Text(value)
        }
    }
}
