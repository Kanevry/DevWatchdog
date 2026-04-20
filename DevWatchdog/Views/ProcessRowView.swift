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
            // Status indicator
            Circle()
                .fill(isZombie ? .red : .orange)
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
                    if process.isOrphan {
                        Text("orphan")
                            .font(.system(size: 9))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(.red.opacity(0.7)))
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
        return isHovered ? Color.primary.opacity(0.05) : Color.clear
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
