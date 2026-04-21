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
            if hasActionBarContent {
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
        .frame(width: 400)
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
                .frame(minWidth: 90, alignment: .trailing)
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
            // Icon-only at rest — Panic is the nuclear option, but granular
            // CTAs in the body do the primary work. Show count as a small
            // badge only when targets are many (≥10) so the button scales
            // from "hint" to "warning" visually.
            HStack(spacing: 3) {
                Image(systemName: "bolt.fill")
                    .font(.caption)
                    .fontWeight(.semibold)
                if panicTargetCount >= 10 {
                    Text("\(panicTargetCount)")
                        .font(.caption2)
                        .fontWeight(.bold)
                        .monospacedDigit()
                }
            }
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
        .controlSize(.small)
        .help("Panic — alle \(panicTargetCount) Zombies und Verdächtigen sofort beenden (⌘⇧⌥P).")
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

            // Suspects split by activity: "idle" (safe — CPU ~0) vs. "active"
            // (a running test/build that a user might still care about). This
            // lets the user end only the idle ones in one click without
            // nuking work-in-progress.
            let split = partitionedSuspects
            if !split.idle.isEmpty && !split.active.isEmpty {
                killSuspectsButton(
                    label: "\(split.idle.count) inaktive Verdächtige beenden",
                    targets: split.idle,
                    tint: .green.opacity(0.8),
                    icon: "checkmark.shield.fill",
                    detail: "\(formatMB(split.idle)) — 0% CPU, sicher zu beenden",
                    helpText: "Beendet nur Verdächtige mit ~0% CPU. Laufende Tests/Builds bleiben unangetastet."
                )
                killSuspectsButton(
                    label: "\(split.active.count) aktive Verdächtige beenden",
                    targets: split.active,
                    tint: activeButtonTint(split.active),
                    icon: "exclamationmark.triangle.fill",
                    detail: "\(formatMB(split.active)) — bis zu \(String(format: "%.0f", maxCPU(split.active)))% CPU — vorsichtig",
                    helpText: "Beendet nur die aktiven Verdächtigen. Prüfe vorher, ob hier ein laufender Test/Build dabei ist."
                )
            } else if !split.idle.isEmpty {
                killSuspectsButton(
                    label: "\(split.idle.count) inaktive Verdächtige beenden",
                    targets: split.idle,
                    tint: .green.opacity(0.8),
                    icon: "checkmark.shield.fill",
                    detail: "\(formatMB(split.idle)) — alle inaktiv, sicher zu beenden",
                    helpText: "Alle Verdächtigen zeigen 0% CPU — sicher zu beenden."
                )
            } else if !split.active.isEmpty, split.active.count > 1 {
                killSuspectsButton(
                    label: "\(split.active.count) Verdächtige beenden",
                    targets: split.active,
                    tint: activeButtonTint(split.active),
                    icon: "exclamationmark.triangle.fill",
                    detail: "\(formatMB(split.active)) — bis zu \(String(format: "%.0f", maxCPU(split.active)))% CPU — vorsichtig",
                    helpText: "Alle Verdächtigen sind aktiv. Prüfe die Liste auf laufende Tests/Builds vor dem Beenden."
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// True if at least one CTA would actually render in the action bar.
    /// Prevents the container from rendering with just padding when we have
    /// exactly one active suspect (which no CTA currently handles — that's
    /// the user's cue to inspect the row and decide manually).
    private var hasActionBarContent: Bool {
        if !monitor.zombieProcesses.isEmpty { return true }
        let split = partitionedSuspects
        if !split.idle.isEmpty { return true }
        if split.active.count > 1 { return true }
        return false
    }

    /// Partition current suspects into "idle" (~0% CPU — safe to batch-kill)
    /// and "active" (still consuming CPU — user may care). Threshold set at
    /// 1% to avoid classifying measurement noise as "active".
    private var partitionedSuspects: (idle: [DevProcess], active: [DevProcess]) {
        let suspects = monitor.suspectProcesses
        let idle = suspects.filter { $0.cpuPercent < 1 }
        let active = suspects.filter { $0.cpuPercent >= 1 }
        return (idle, active)
    }

    private func formatMB(_ list: [DevProcess]) -> String {
        let mb = list.reduce(0.0) { $0 + $1.memoryMB }
        return "\(String(format: "%.0f", mb)) MB"
    }

    private func maxCPU(_ list: [DevProcess]) -> Double {
        list.map(\.cpuPercent).max() ?? 0
    }

    private func activeButtonTint(_ list: [DevProcess]) -> Color {
        maxCPU(list) > 50 ? .red.opacity(0.85) : .orange.opacity(0.85)
    }

    @ViewBuilder
    private func killSuspectsButton(
        label: String,
        targets: [DevProcess],
        tint: Color,
        icon: String,
        detail: String,
        helpText: String
    ) -> some View {
        Button {
            monitor.killSuspects(targets)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "trash")
                VStack(alignment: .leading, spacing: 0) {
                    Text(label)
                        .fontWeight(.medium)
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.8))
                }
                Spacer()
                Image(systemName: icon)
                    .foregroundStyle(.white.opacity(0.7))
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(tint)
        .help(helpText)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 32))
                .foregroundStyle(.green)
            Text(emptyStateTitle)
                .font(.headline)
            Text(emptyStateSubtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .padding(.horizontal, 16)
    }

    private var emptyStateTitle: String {
        switch monitor.emergencyState {
        case .emergency: return "Keine Targets mehr"
        case .elevated:  return "Vorerst sauber"
        case .normal:    return "Alles sauber"
        }
    }

    private var emptyStateSubtitle: String {
        switch monitor.emergencyState {
        case .emergency:
            return "System-Druck noch hoch — Scanner läuft weiter, greift bei neuen Zombies sofort zu."
        case .elevated:
            return "Keine Zombie-Prozesse erkannt. Erhöhter System-Druck wird beobachtet."
        case .normal:
            return "Keine Zombie-Prozesse erkannt"
        }
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
                    ProcessGroupRowView(
                        group: group,
                        isZombie: true,
                        onKill: { process in monitor.killProcess(process) },
                        onKillGroup: {
                            for process in group.processes {
                                monitor.killProcess(process)
                            }
                        },
                        onThrottle: { process in monitor.throttleProcess(process) },
                        onResume: { process in monitor.resumeProcess(process) }
                    )
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
                    ProcessGroupRowView(
                        group: group,
                        isZombie: false,
                        onKill: { process in monitor.killProcess(process) },
                        onKillGroup: {
                            for process in group.processes {
                                monitor.killProcess(process)
                            }
                        },
                        onThrottle: { process in monitor.throttleProcess(process) },
                        onResume: { process in monitor.resumeProcess(process) }
                    )
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
                Label("Protokoll", systemImage: "list.bullet.rectangle")
            }
            .help("Protokoll öffnen — alle Kill/Pause/Resume-Events dieser Session")

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
    var onThrottle: ((DevProcess) -> Void)? = nil
    var onResume: ((DevProcess) -> Void)? = nil

    @State private var isExpanded = false

    private var groupCPUColor: Color {
        let ncpu = Double(ProcessInfo.processInfo.activeProcessorCount)
        guard ncpu > 0 else { return .secondary }
        let fraction = group.maxCPU / (ncpu * 100)
        if fraction >= 0.15 { return .red }
        if fraction >= 0.05 { return .orange }
        return .secondary
    }

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
                            .foregroundStyle(groupCPUColor)
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
                    ProcessRowView(
                        process: process,
                        isZombie: isZombie,
                        onKill: { onKill(process) },
                        onThrottle: onThrottle.map { handler in { handler(process) } },
                        onResume: onResume.map { handler in { handler(process) } }
                    )
                    .padding(.leading, 18)
                }
            }
        }
    }
}
