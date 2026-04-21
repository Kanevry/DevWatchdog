import SwiftUI

struct SettingsView: View {
    @ObservedObject var config: WatchdogConfig
    /// Optional — supplied by call sites that want to show the live "Aktuelle Werte"
    /// panel on the Emergency tab. Defaults to `nil` so existing call sites
    /// (e.g. `DevWatchdogApp.openSettings()`) continue to compile without change.
    /// Wave 5 coordinator: pass the app's shared `ProcessMonitor` here to enable
    /// the live readout.
    var monitor: ProcessMonitor?
    @StateObject private var insightsEngine: InsightsEngine
    @State private var newRulePattern = ""
    @State private var showingResetConfirmation = false
    @State private var newExcludedApp = ""
    @State private var newInclusionPattern = ""

    init(config: WatchdogConfig, monitor: ProcessMonitor? = nil) {
        self.config = config
        self.monitor = monitor
        let log = monitor?.sessionLog ?? SessionLog()
        _insightsEngine = StateObject(wrappedValue: InsightsEngine(log: log, config: config))
    }

    var body: some View {
        TabView {
            generalTab
                .tabItem {
                    Label("Allgemein", systemImage: "gear")
                }

            rulesTab
                .tabItem {
                    Label("Regeln", systemImage: "list.bullet.rectangle")
                }

            emergencyTab
                .tabItem {
                    Label("Notfall", systemImage: "bolt.shield.fill")
                }

            InsightsView(engine: insightsEngine)
                .tabItem {
                    Label("Insights", systemImage: "lightbulb.fill")
                }

            aboutTab
                .tabItem {
                    Label("Über", systemImage: "info.circle")
                }
        }
        .frame(minWidth: 520, minHeight: 500)
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
                    Text("Auto-Kill aktiv")
                        .fontWeight(.medium)
                }
                Text("Verwaiste Dev-Prozesse werden nach der Grace-Period automatisch beendet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Scan-Intervall") {
                    HStack {
                        Slider(value: $config.scanInterval, in: 10...120, step: 5)
                            .frame(maxWidth: 200)
                        Text("\(Int(config.scanInterval))s")
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                }
                settingsHint(
                    current: config.scanInterval,
                    defaultValue: 30,
                    recommended: SettingsRecommendations.scanInterval,
                    format: { "\(Int($0))s" },
                    recommendationReason: scanIntervalReason
                )

                LabeledContent("Orphan-Timeout") {
                    HStack {
                        Slider(value: $config.orphanTimeout, in: 30...600, step: 10)
                            .frame(maxWidth: 200)
                        Text(formatDuration(config.orphanTimeout))
                            .monospacedDigit()
                            .frame(width: 50, alignment: .trailing)
                    }
                }
                Text("Wie lange ein verwaister Prozess leben darf, bevor er als Zombie markiert wird.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                settingsHint(
                    current: config.orphanTimeout,
                    defaultValue: 120,
                    recommended: SettingsRecommendations.orphanTimeout,
                    format: formatDuration,
                    recommendationReason: nil
                )

                LabeledContent("Grace-Period") {
                    HStack {
                        Slider(value: $config.gracePeriod, in: 10...120, step: 5)
                            .frame(maxWidth: 200)
                        Text("\(Int(config.gracePeriod))s")
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                }
                Text("Warnzeit, bevor ein Zombie beendet wird. Du kannst in dieser Zeit noch eingreifen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                settingsHint(
                    current: config.gracePeriod,
                    defaultValue: 30,
                    recommended: SettingsRecommendations.gracePeriod,
                    format: { "\(Int($0))s" },
                    recommendationReason: nil
                )

                LabeledContent("Catch-all Kill") {
                    HStack {
                        Slider(value: $config.catchAllMaxRuntime, in: 3600...86400, step: 3600)
                            .frame(maxWidth: 200)
                        Text(formatDuration(config.catchAllMaxRuntime))
                            .monospacedDigit()
                            .frame(width: 50, alignment: .trailing)
                    }
                }
                Text("Jeder Dev-Prozess ohne spezifische Regel, der länger läuft, wird beendet. Sicherheitsnetz.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                settingsHint(
                    current: config.catchAllMaxRuntime,
                    defaultValue: 28_800,
                    recommended: SettingsRecommendations.catchAllMaxRuntime,
                    format: formatDuration,
                    recommendationReason: catchAllReason
                )
            } header: {
                HStack {
                    Text("Timing")
                    Spacer()
                    Button("Timing zurücksetzen") {
                        config.scanInterval = 30
                        config.orphanTimeout = 120
                        config.gracePeriod = 30
                        config.catchAllMaxRuntime = 28_800
                    }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                }
            }

            Section("Benachrichtigungen") {
                Toggle("Sound-Benachrichtigung bei kritischen Events", isOn: $config.soundOnCritical)
            }

            Section("System") {
                Toggle("Beim Login starten", isOn: $config.launchAtLogin)
            }

            Section("Ausgeschlossene Apps") {
                Text("Prozesse dieser Apps werden nie als Verdächtige angezeigt.")
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
                    TextField("z.B. /MeineApp.app/", text: $newExcludedApp)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                    Button("Hinzufügen") {
                        guard !newExcludedApp.isEmpty else { return }
                        config.excludedApps.append(newExcludedApp)
                        newExcludedApp = ""
                    }
                    .disabled(newExcludedApp.isEmpty)
                }
            }

            Section("Dev-Filter") {
                Text("Nur Prozesse, die mindestens eines dieser Keywords enthalten, werden von DevWatchdog überwacht.")
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
                    TextField("z.B. rollup", text: $newInclusionPattern)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                    Button("Hinzufügen") {
                        guard !newInclusionPattern.isEmpty else { return }
                        config.inclusionPatterns.append(newInclusionPattern)
                        newInclusionPattern = ""
                    }
                    .disabled(newInclusionPattern.isEmpty)
                }
            }

            Section("Entwickler") {
                Toggle("Experimentell — libproc-Scanner", isOn: $config.useLibprocEnumerator)
                Text("Verwendet die native libproc-API statt /bin/ps-Subprozess. Schneller, aber noch in Erprobung. Wirkt ab nächstem Scan.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Experimentell — Signal-Klassifier", isOn: $config.useSignalClassifier)
                Text("Signal-basierter Dev-Prozess-Filter (Pfad, cwd, Parent, Bundle-ID). Ersetzt Wortliste bei klaren Signalen; Wortliste bleibt Fallback für unklare Prozesse. Wirkt nur im libproc-Pfad.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Experimentell — cwd-Projekterkennung", isOn: $config.useCwdProjectDetection)
                Text("Ermittelt Projektnamen via Arbeitsverzeichnis (proc_pidinfo). Behebt falsche Namen bei verschachtelten Repos. Erfordert libproc-Scanner.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Auf Defaults zurücksetzen") {
                    showingResetConfirmation = true
                }
                .alert("Alle Einstellungen zurücksetzen?", isPresented: $showingResetConfirmation) {
                    Button("Zurücksetzen", role: .destructive) {
                        config.resetToDefaults()
                    }
                    Button("Abbrechen", role: .cancel) {}
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Rules Tab

    private var rulesTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Prozessregeln")
                .font(.headline)
            Text("Lege fest, wie DevWatchdog bestimmte Prozess-Patterns behandelt. Verwaiste Prozesse werden immer automatisch beendet (außer Whitelist).")
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
                TextField("Pattern (z.B. next.*dev)", text: $newRulePattern)
                    .textFieldStyle(.roundedBorder)

                Button("Regel hinzufügen") {
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
                        Text("Warnen:")
                            .foregroundStyle(.secondary)
                        TextField("CPU %", value: rule.cpuThreshold, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 50)
                        Text("% CPU")
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 4) {
                        TextField("Sekunden", value: rule.runtimeThreshold, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 60)
                        Text("s (\(formatDuration(rule.wrappedValue.runtimeThreshold)))")
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 4) {
                        Text("Beenden:")
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

            Text(versionString)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Text("Automatisches Aufräumen verwaister Dev-Prozesse unter macOS.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                InfoRow(label: "Autor", value: "Bernhard Götzendorfer")
                InfoRow(label: "Lizenz", value: "MIT")
                InfoRow(label: "GitHub", value: "github.com/Kanevry/DevWatchdog")
            }
            .font(.caption)

            Spacer()
        }
        .padding()
    }

    // MARK: - Settings hint (Default / Recommended)

    /// One-line sub-label below a slider that shows the ship-default and the
    /// hardware-tuned recommendation. Goes blue when the user's current value
    /// equals the recommendation (reassurance), stays neutral otherwise —
    /// does not nag the user about "wrong" settings, just shows the options.
    @ViewBuilder
    private func settingsHint(
        current: Double,
        defaultValue: Double,
        recommended: Double,
        format: (Double) -> String,
        recommendationReason: String?
    ) -> some View {
        let onRecommended = abs(current - recommended) < 0.5
        let onDefault = abs(current - defaultValue) < 0.5
        let recSuffix = recommendationReason.map { " (\($0))" } ?? ""

        HStack(spacing: 8) {
            Text("Standard: \(format(defaultValue))")
                .foregroundColor(onDefault ? .accentColor : .secondary)
            Text("·")
                .foregroundColor(.secondary)
            Text("Empfohlen: \(format(recommended))\(recSuffix)")
                .foregroundColor(onRecommended ? .accentColor : .secondary)
        }
        .font(.caption2)
    }

    /// Dynamic reason string for the scan-interval recommendation, so the
    /// user sees *why* we suggest what we suggest ("für 32 GB RAM").
    private var scanIntervalReason: String {
        let ram = SettingsRecommendations.physicalRAMGB
        if ram < 8 { return "bei <8 GB RAM" }
        if ram >= 16 { return String(format: "bei %.0f GB RAM", ram) }
        return "bei 8–16 GB RAM"
    }

    /// Dynamic reason string for the catch-all recommendation.
    private var catchAllReason: String {
        let ram = SettingsRecommendations.physicalRAMGB
        if ram < 16 { return "kleinere Maschine" }
        if ram > 32 { return "Workstation-Klasse" }
        return "Standard-Dev-Maschine"
    }

    // MARK: - Helpers

    /// Marketing + build version read live from Info.plist (populated from
    /// `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` build settings at build time).
    private var versionString: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let marketing = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "v\(marketing) (build \(build))"
    }

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
