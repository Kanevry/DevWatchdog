import SwiftUI

struct SettingsView: View {
    @ObservedObject var config: WatchdogConfig
    @State private var newRulePattern = ""
    @State private var showingResetConfirmation = false

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

            aboutTab
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .frame(minWidth: 480, minHeight: 500)
        .padding()
    }

    // MARK: - General Tab

    private var generalTab: some View {
        Form {
            Section("Kill Mode") {
                Picker("Mode", selection: $config.killMode) {
                    ForEach(KillMode.allCases, id: \.self) { mode in
                        VStack(alignment: .leading) {
                            Text(mode.displayName)
                            Text(mode.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
            }

            Section("Scan Settings") {
                LabeledContent("Scan interval") {
                    HStack {
                        Slider(value: $config.scanInterval, in: 10...120, step: 5)
                            .frame(maxWidth: 200)
                        Text("\(Int(config.scanInterval))s")
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                }

                if config.killMode == .smart {
                    LabeledContent("Grace period") {
                        HStack {
                            Slider(value: $config.gracePeriod, in: 10...120, step: 5)
                                .frame(maxWidth: 200)
                            Text("\(Int(config.gracePeriod))s")
                                .monospacedDigit()
                                .frame(width: 40, alignment: .trailing)
                        }
                    }
                }
            }

            Section("Thresholds (for processes without specific rules)") {
                LabeledContent("CPU threshold") {
                    HStack {
                        Slider(value: $config.cpuThreshold, in: 10...200, step: 10)
                            .frame(maxWidth: 200)
                        Text("\(Int(config.cpuThreshold))%")
                            .monospacedDigit()
                            .frame(width: 50, alignment: .trailing)
                    }
                }

                LabeledContent("Runtime threshold") {
                    HStack {
                        Slider(value: $config.runtimeThreshold, in: 60...7200, step: 60)
                            .frame(maxWidth: 200)
                        Text(formatDuration(config.runtimeThreshold))
                            .monospacedDigit()
                            .frame(width: 50, alignment: .trailing)
                    }
                }
            }

            Section("Notifications") {
                Toggle("Sound on critical CPU load", isOn: $config.soundOnCritical)
                if config.soundOnCritical {
                    LabeledContent("Critical threshold") {
                        HStack {
                            Slider(value: $config.criticalCPUThreshold, in: 100...2000, step: 50)
                                .frame(maxWidth: 200)
                            Text("\(Int(config.criticalCPUThreshold))%")
                                .monospacedDigit()
                                .frame(width: 60, alignment: .trailing)
                        }
                    }
                }
            }

            Section("System") {
                Toggle("Launch at login", isOn: $config.launchAtLogin)
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
            Text("Define how DevWatchdog handles specific process patterns.")
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
                TextField("Pattern (e.g. vitest.*worker)", text: $newRulePattern)
                    .textFieldStyle(.roundedBorder)

                Button("Add Rule") {
                    guard !newRulePattern.isEmpty else { return }
                    let rule = ProcessRule(
                        id: UUID(),
                        pattern: newRulePattern,
                        cpuThreshold: config.cpuThreshold,
                        runtimeThreshold: config.runtimeThreshold,
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

            if rule.wrappedValue.action != .whitelist && rule.wrappedValue.action != .ignore {
                HStack(spacing: 16) {
                    HStack(spacing: 4) {
                        Text("CPU:")
                            .foregroundStyle(.secondary)
                        TextField("CPU %", value: rule.cpuThreshold, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 60)
                        Text("%")
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 4) {
                        Text("Runtime:")
                            .foregroundStyle(.secondary)
                        TextField("Seconds", value: rule.runtimeThreshold, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 70)
                        Text("s (\(formatDuration(rule.wrappedValue.runtimeThreshold)))")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
            }
        }
        .padding(.vertical, 4)
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

            Text("v1.0.0")
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
