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
