import SwiftUI

struct ProcessRowView: View {
    let process: DevProcess
    let isZombie: Bool
    var onKill: () -> Void
    // TODO: wire onThrottle from MenuBarView to monitor.throttleProcess
    var onThrottle: (() -> Void)? = nil
    // TODO: wire onResume from MenuBarView to monitor.resumeProcess
    var onResume: (() -> Void)? = nil

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            // Status indicator — colored by KillConfidence so a glance down
            // the list immediately separates urgent (red) from review-me
            // (orange) from likely-intentional (yellow/green).
            Circle()
                .fill(statusDotColor)
                .frame(width: 6, height: 6)

            // State icon (leading)
            stateIcon

            // Process info
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(process.processName)
                        .font(.system(.caption, weight: .medium))
                        .foregroundStyle(isPaused ? Color.secondary : Color.primary)
                    if isPaused {
                        Text("(pausiert)")
                            .font(.system(size: 9))
                            .foregroundStyle(.yellow)
                    }
                    // Up to 3 analyzer-derived badges answering "why is this
                    // on the list" (e.g. NEW ORPHAN, IDLE 7m, LEAK 842MB).
                    // Cap at 3 so a busy row does not push CPU% off-screen.
                    ForEach(Array(process.signals.badges.prefix(3).enumerated()), id: \.offset) { _, signal in
                        signalBadge(signal)
                    }
                }

                HStack(spacing: 8) {
                    if let project = process.projectName {
                        Text(project)
                            .foregroundStyle(.secondary)
                    }
                    Text("PID \(process.pid)")
                        .foregroundStyle(.tertiary)
                }
                .font(.caption2)
            }

            Spacer(minLength: 8)

            // Stats (monospaced digits prevent jitter as CPU/memory change)
            VStack(alignment: .trailing, spacing: 1) {
                HStack(spacing: 4) {
                    Text(process.cpuFormatted)
                        .foregroundStyle(cpuColor)
                        .fontWeight(.medium)
                    Text("CPU")
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 4) {
                    Text(process.runtimeFormatted)
                        .foregroundStyle(.secondary)
                    Text(process.memoryFormatted)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption2)
            .monospacedDigit()

            // Action menu (Pause / Resume / Kill)
            Menu {
                // Beenden is first so Enter picks it in a keyboard-driven menu
                Button(role: .destructive) {
                    onKill()
                } label: {
                    Label("Beenden", systemImage: "xmark.circle.fill")
                }
                .keyboardShortcut(.delete, modifiers: [])

                if process.state == .stopped, let onResume {
                    Button {
                        onResume()
                    } label: {
                        Label("Fortsetzen", systemImage: "play.fill")
                    }
                    .keyboardShortcut("r", modifiers: [])
                }

                if process.state == .running, let onThrottle {
                    Button {
                        onThrottle()
                    } label: {
                        Label("Pausieren", systemImage: "pause.fill")
                    }
                    .keyboardShortcut("p", modifiers: [])
                }
            } label: {
                Image(systemName: primaryActionIcon)
                    .foregroundStyle(primaryActionColor)
                    .font(.system(size: 14))
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.borderless)
            .fixedSize()
            .help(primaryActionHelp)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(rowBackground)
        .overlay(alignment: .leading) {
            if isPaused {
                Rectangle()
                    .fill(Color.yellow)
                    .frame(width: 2)
            }
        }
        .onHover { hovering in
            isHovered = hovering
        }
    }

    // MARK: - Derived values

    private var isPaused: Bool {
        process.state == .stopped
    }

    @ViewBuilder
    private var stateIcon: some View {
        switch process.state {
        case .stopped:
            Image(systemName: "pause.circle.fill")
                .foregroundStyle(.yellow)
                .font(.system(size: 11))
                .help("Prozess ist pausiert (SIGSTOP)")
        case .zombie:
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(.red)
                .font(.system(size: 11))
                .help("Unix-Zombie-Prozess")
        case .running, .unknown:
            EmptyView()
        }
    }

    private var rowBackground: Color {
        if isPaused {
            return Color.yellow.opacity(isHovered ? 0.15 : 0.08)
        }
        // High-confidence rows get a subtle red wash so a crowded list still
        // draws the eye to the real zombies. Hover always intensifies.
        let base: Color = {
            switch process.signals.confidence {
            case .high:   return .red
            case .medium: return .orange
            case .low:    return .primary
            }
        }()
        let alpha: Double = {
            switch process.signals.confidence {
            case .high:   return isHovered ? 0.16 : 0.09
            case .medium: return isHovered ? 0.12 : 0.06
            case .low:    return isHovered ? 0.05 : 0.00
            }
        }()
        return base.opacity(alpha)
    }

    /// Leading status dot. Encodes overall kill-confidence at a glance — a
    /// user can scan down the list and only stop on red/orange dots.
    private var statusDotColor: Color {
        // Paused processes: keep the yellow signal so the strip + dot agree.
        if isPaused { return .yellow }
        switch process.signals.confidence {
        case .high:   return .red
        case .medium: return .orange
        case .low:
            // Fall back to legacy zombie-vs-suspect binary when the analyzer
            // hasn't produced a confidence signal yet (first scan, whitelisted
            // process, empty rule set).
            return isZombie ? .red : .orange
        }
    }

    /// Single capsule for a ``ProcessSignal``. Color maps loosely to severity
    /// so the badges read correctly even without the dot — colorblind-friendly
    /// via the label text ("LEAK", "IDLE", "ACTIVE"...) which is always shown.
    @ViewBuilder
    private func signalBadge(_ signal: ProcessSignal) -> some View {
        Text(signal.label)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Capsule().fill(badgeColor(for: signal).opacity(0.75)))
            .help(badgeTooltip(for: signal))
            .lineLimit(1)
    }

    private func badgeColor(for signal: ProcessSignal) -> Color {
        switch signal {
        case .newlyOrphaned, .ruleHardKill, .catchAllExpired: return .red
        case .adoptedByLaunchd, .memoryLeak, .ruleWarn:       return .orange
        case .idle:                                            return Color(red: 0.85, green: 0.65, blue: 0.2)
        case .active:                                          return .green
        case .paused:                                          return .yellow
        }
    }

    private func badgeTooltip(for signal: ProcessSignal) -> String {
        switch signal {
        case .newlyOrphaned:
            return "Elternprozess ist seit dem letzten Scan verschwunden (PPID wechselte auf 1)."
        case .adoptedByLaunchd:
            return "Läuft unter launchd (PID 1). Kann ein legitimer Daemon oder eine abgekoppelte Shell sein."
        case .idle(let minutes):
            return "Kein CPU-Verbrauch, läuft seit \(minutes) min. Guter Kandidat zum Schließen."
        case .active(let percent):
            return "Aktuell \(percent)% CPU — wahrscheinlich ein laufender Build/Test."
        case .memoryLeak(let mb):
            return "Kein CPU-Verbrauch, aber \(mb) MB RSS — klassisches Leak-Muster."
        case .ruleWarn(let pattern):
            return "Regel '\(pattern)' warnt (Schwellen überschritten, aber noch unter Hard-Kill)."
        case .ruleHardKill(let pattern, let trigger):
            return "Regel '\(pattern)' — Hard-Kill-Grenze erreicht (\(trigger))."
        case .catchAllExpired:
            return "Catch-all-Safety-Net: Laufzeit-Obergrenze überschritten."
        case .paused:
            return "Pausiert (SIGSTOP) — wartet auf Resume oder Kill."
        }
    }

    private var primaryActionIcon: String {
        // When paused, surface Resume affordance; otherwise Kill is primary
        process.state == .stopped ? "play.circle.fill" : "xmark.circle.fill"
    }

    private var primaryActionColor: Color {
        if process.state == .stopped {
            return .yellow
        }
        return isHovered ? .red : .secondary
    }

    private var primaryActionHelp: String {
        switch process.state {
        case .stopped:
            return "Klick: Menu (Fortsetzen / Beenden)"
        case .running:
            return "Klick: Menu (Pausieren / Beenden)"
        case .zombie, .unknown:
            return "Klick: Menu (Beenden)"
        }
    }

    private var cpuColor: Color {
        if process.cpuPercent >= 100 { return .red }
        if process.cpuPercent >= 50 { return .orange }
        return .primary
    }
}
