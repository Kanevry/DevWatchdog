import SwiftUI

struct MenuBarView: View {
    @ObservedObject var monitor: ProcessMonitor
    @ObservedObject var config: WatchdogConfig
    var panicAction: PanicAction?
    var openSettings: () -> Void

    @State private var showPanicConfirm = false
    @State private var showOnboarding = !UserDefaults.standard.bool(
        forKey: EmergencyOnboardingView.hasSeenKey
    )
    @State private var showSessionLog = false

    /// Threshold above which the Panic button shows a confirmation alert.
    private let panicConfirmThreshold = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            headerSection

            // Emergency banner — only while in .emergency
            if monitor.emergencyState == .emergency {
                EmergencyBannerView(monitor: monitor)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // System pressure meter — whenever a snapshot is available
            if monitor.pressure != nil {
                Divider()
                PressureMeterView(monitor: monitor)
            }

            Divider()

            // Sticky action bar (always visible)
            if !monitor.zombieProcesses.isEmpty || !monitor.suspectProcesses.isEmpty {
                actionBar
                Divider()
            }

            // Process sections (scrollable)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if monitor.zombieProcesses.isEmpty && monitor.suspectProcesses.isEmpty {
                        emptyState
                    } else {
                        if !monitor.zombieProcesses.isEmpty {
                            zombieSection
                        }
                        if !monitor.suspectProcesses.isEmpty {
                            suspectSection
                        }
                    }

                    if !monitor.whitelistedProcesses.isEmpty {
                        whitelistedSection
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: monitor.zombieProcesses.count)
                .animation(.easeInOut(duration: 0.2), value: monitor.suspectProcesses.count)
            }
            .frame(maxHeight: dynamicMaxHeight)

            Divider()

            // Footer actions
            footerSection
        }
        .frame(width: 380)
        .animation(.easeInOut(duration: 0.25), value: monitor.emergencyState)
        .animation(.easeInOut(duration: 0.25), value: monitor.pressure != nil)
        .sheet(isPresented: $showOnboarding) {
            EmergencyOnboardingView(isPresented: $showOnboarding)
        }
        .sheet(isPresented: $showSessionLog) {
            SessionLogView(log: monitor.sessionLog)
                .frame(width: 560, height: 620)
        }
    }

    private var dynamicMaxHeight: CGFloat {
        let processCount = monitor.zombieProcesses.count + monitor.suspectProcesses.count + monitor.whitelistedProcesses.count
        return min(max(CGFloat(processCount) * 44 + 120, 200), 600)
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("DevWatchdog")
                    .font(.headline)
                HStack(spacing: 12) {
                    Label(
                        String(format: "%.0f%% CPU", monitor.totalCPU),
                        systemImage: "cpu"
                    )
                    Label(
                        String(format: "%.0f MB", monitor.totalMemoryMB),
                        systemImage: "memorychip"
                    )
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 8) {
                if hasPanicTargets {
                    panicButton
                }

                VStack(alignment: .trailing, spacing: 2) {
                    emergencyStatePill
                    if let lastScan = monitor.lastScan {
                        Text("vor \(lastScan, style: .relative)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .alert("Panic aktivieren?", isPresented: $showPanicConfirm) {
            Button("Abbrechen", role: .cancel) { }
            Button("Ja, alle beenden", role: .destructive) {
                runPanic()
            }
            .keyboardShortcut(.return, modifiers: [.command])
        } message: {
            Text(panicConfirmMessage)
        }
    }

    // MARK: - Panic Button

    private var panicTargetCount: Int {
        monitor.zombieProcesses.count + monitor.suspectProcesses.count
    }

    private var hasPanicTargets: Bool {
        panicTargetCount > 0
    }

    private var panicConfirmMessage: String {
        let mode = config.softKillPreferred ? "pausiert/beendet" : "beendet"
        return "\(panicTargetCount) Prozesse werden \(mode)."
    }

    private var panicButton: some View {
        Button {
            if panicTargetCount > panicConfirmThreshold {
                showPanicConfirm = true
            } else {
                runPanic()
            }
        } label: {
            Label("Panic", systemImage: "bolt.fill")
                .font(.caption)
                .fontWeight(.semibold)
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
        .controlSize(.small)
        .help("Alle Zombies und Verdächtigen sofort beenden (⌘⇧⌥P).")
        .accessibilityLabel("Panic — \(panicTargetCount) Prozesse beenden")
    }

    private func runPanic() {
        _ = panicAction?.execute()
    }

    // MARK: - Emergency state pill

    @ViewBuilder
    private var emergencyStatePill: some View {
        switch monitor.emergencyState {
        case .emergency:
            // Phase-animator pulses opacity without needing a TimelineView frame loop.
            HStack(spacing: 4) {
                Circle()
                    .fill(.red)
                    .frame(width: 6, height: 6)
                Text("EMERGENCY")
                    .font(.caption2)
                    .fontWeight(.bold)
                    .foregroundStyle(.red)
            }
            .phaseAnimator([0.55, 1.0]) { content, phase in
                content.opacity(phase)
            } animation: { _ in
                .easeInOut(duration: 0.6)
            }
        case .elevated:
            HStack(spacing: 4) {
                Circle()
                    .fill(.orange)
                    .frame(width: 6, height: 6)
                Text("Erhöht")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.orange)
            }
        case .normal:
            HStack(spacing: 4) {
                Circle()
                    .fill(.green)
                    .frame(width: 6, height: 6)
                Text("Auto-Kill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Sticky Action Bar

    private var actionBar: some View {
        VStack(spacing: 6) {
            // Kill All Zombies — always safe (green)
            if !monitor.zombieProcesses.isEmpty {
                let count = monitor.zombieProcesses.count
                let memMB = monitor.zombieProcesses.reduce(0.0) { $0 + $1.memoryMB }

                Button {
                    monitor.killAllZombies()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "trash.fill")
                        VStack(alignment: .leading, spacing: 0) {
                            Text("\(count) Zombie\(count == 1 ? "" : "s") beenden")
                                .fontWeight(.medium)
                            Text("\(String(format: "%.0f", memMB)) MB — verwaist oder abgelaufen, sicher zu beenden")
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.8))
                        }
                        Spacer()
                        Image(systemName: "checkmark.shield.fill")
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green.opacity(0.85))
                .help("Beendet alle Zombie-Prozesse. Das sind verwaiste (ohne Parent) oder Prozesse, die ihre Max-Laufzeit überschritten haben. Immer sicher — niemand benutzt sie.")
            }

            // Kill All Suspects — ampel color based on risk
            if monitor.suspectProcesses.count > 1 {
                let count = monitor.suspectProcesses.count
                let memMB = monitor.suspectProcesses.reduce(0.0) { $0 + $1.memoryMB }
                let maxCPU = monitor.suspectProcesses.map(\.cpuPercent).max() ?? 0
                let riskColor = suspectRiskColor(maxCPU: maxCPU)
                let riskLabel = suspectRiskLabel(maxCPU: maxCPU)
                let riskIcon = suspectRiskIcon(maxCPU: maxCPU)

                Button {
                    monitor.killAllSuspects()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "trash")
                        VStack(alignment: .leading, spacing: 0) {
                            Text("\(count) Verdächtige beenden")
                                .fontWeight(.medium)
                            Text("\(String(format: "%.0f", memMB)) MB — \(riskLabel)")
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.8))
                        }
                        Spacer()
                        Image(systemName: riskIcon)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(riskColor)
                .help(suspectRiskTooltip(maxCPU: maxCPU))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Suspect Risk Assessment

    private func suspectRiskColor(maxCPU: Double) -> Color {
        if maxCPU > 50 { return .red.opacity(0.85) }
        if maxCPU > 1 { return .orange.opacity(0.85) }
        return .green.opacity(0.7)
    }

    private func suspectRiskLabel(maxCPU: Double) -> String {
        if maxCPU > 50 { return "einige aktiv (bis zu \(String(format: "%.0f", maxCPU))% CPU)" }
        if maxCPU > 1 { return "geringe Aktivität, Prüfung empfohlen" }
        return "alle inaktiv, sicher zu beenden"
    }

    private func suspectRiskIcon(maxCPU: Double) -> String {
        if maxCPU > 50 { return "exclamationmark.triangle.fill" }
        if maxCPU > 1 { return "questionmark.circle.fill" }
        return "checkmark.shield.fill"
    }

    private func suspectRiskTooltip(maxCPU: Double) -> String {
        if maxCPU > 50 {
            return "Einige Verdächtige nutzen aktuell CPU (\(String(format: "%.0f", maxCPU))%). Könnte ein laufender Test oder Build sein — Liste vorher prüfen."
        }
        if maxCPU > 1 {
            return "Einige Verdächtige zeigen geringe CPU-Aktivität. Wahrscheinlich sicher, aber Liste auf Bekanntes prüfen."
        }
        return "Alle Verdächtigen sind bei 0% CPU — inaktive Prozesse, sicher zu beenden."
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 32))
                .foregroundStyle(.green)
            Text("Alles sauber")
                .font(.headline)
            Text("Keine Zombie-Prozesse erkannt")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    // MARK: - Zombie Section

    private var zombieSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(
                title: "Zombies",
                count: monitor.zombieProcesses.count,
                color: .red,
                icon: "exclamationmark.triangle.fill"
            )

            let groups = monitor.zombieProcesses.grouped()
            ForEach(groups) { group in
                if group.count == 1 {
                    ProcessRowView(
                        process: group.processes[0],
                        isZombie: true,
                        onKill: { monitor.killProcess(group.processes[0]) },
                        onThrottle: { monitor.throttleProcess(group.processes[0]) },
                        onResume: { monitor.resumeProcess(group.processes[0]) }
                    )
                } else {
                    ProcessGroupRowView(group: group, isZombie: true) { process in
                        monitor.killProcess(process)
                    } onKillGroup: {
                        for process in group.processes {
                            monitor.killProcess(process)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Suspect Section

    private var suspectSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(
                title: "Suspects",
                count: monitor.suspectProcesses.count,
                color: .orange,
                icon: "eye.fill"
            )

            let groups = monitor.suspectProcesses.grouped()
            ForEach(groups) { group in
                if group.count == 1 {
                    ProcessRowView(
                        process: group.processes[0],
                        isZombie: false,
                        onKill: { monitor.killProcess(group.processes[0]) },
                        onThrottle: { monitor.throttleProcess(group.processes[0]) },
                        onResume: { monitor.resumeProcess(group.processes[0]) }
                    )
                } else {
                    ProcessGroupRowView(group: group, isZombie: false) { process in
                        monitor.killProcess(process)
                    } onKillGroup: {
                        for process in group.processes {
                            monitor.killProcess(process)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Whitelisted Section

    private var whitelistedSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(
                title: "Whitelisted",
                count: monitor.whitelistedProcesses.count,
                color: .gray,
                icon: "shield.fill"
            )

            ForEach(monitor.whitelistedProcesses) { process in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(process.processName)
                            .font(.caption)
                        if let project = process.projectName {
                            Text(project)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Text(process.cpuFormatted)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: - Footer

    private var footerSection: some View {
        HStack {
            if monitor.isScanning {
                HStack(spacing: 4) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Scanne…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Button {
                    Task { await monitor.scan() }
                } label: {
                    Label("Jetzt scannen", systemImage: "arrow.clockwise")
                }
            }

            Spacer()

            Button {
                showSessionLog = true
            } label: {
                Label("Log", systemImage: "list.bullet.rectangle")
            }
            .help("Session-Log öffnen — alle Kill/Pause/Resume-Events dieser Session")

            Button {
                openSettings()
            } label: {
                Label("Einstellungen", systemImage: "gear")
            }

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("Beenden", systemImage: "power")
            }
        }
        .buttonStyle(.borderless)
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Helpers

    private func sectionHeader(title: String, count: Int, color: Color, icon: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .foregroundStyle(color)
            Text(title)
                .fontWeight(.semibold)
            Text("(\(count))")
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }
}

// MARK: - Process Group Row

struct ProcessGroupRowView: View {
    let group: ProcessGroup
    let isZombie: Bool
    var onKill: (DevProcess) -> Void
    var onKillGroup: () -> Void

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Group header - clickable to expand/collapse
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 10)

                    Circle()
                        .fill(isZombie ? .red : .orange)
                        .frame(width: 6, height: 6)

                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Text(group.name)
                                .font(.system(.caption, weight: .medium))
                            Text("(\(group.count))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        if let project = group.projectName {
                            Text(project)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 1) {
                        Text(String(format: "%.0f%% CPU", group.totalCPU))
                            .font(.caption2)
                            .foregroundStyle(group.maxCPU >= 50 ? .orange : .secondary)
                        Text(String(format: "%.0f MB", group.totalMemoryMB))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    // Kill group button
                    Button {
                        onKillGroup()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 14))
                    }
                    .buttonStyle(.borderless)
                    .help("Alle \(group.count) \(group.name)-Prozesse beenden")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)

            // Expanded: show individual processes
            if isExpanded {
                ForEach(group.processes) { process in
                    ProcessRowView(process: process, isZombie: isZombie) {
                        onKill(process)
                    }
                    .padding(.leading, 18)
                }
            }
        }
    }
}
