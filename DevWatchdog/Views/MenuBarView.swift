import SwiftUI

struct MenuBarView: View {
    @ObservedObject var monitor: ProcessMonitor
    @ObservedObject var config: WatchdogConfig
    var openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            headerSection

            Divider()

            // Process sections
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
            }
            .frame(maxHeight: 400)

            Divider()

            // Footer actions
            footerSection
        }
        .frame(width: 380)
        .onAppear {
            monitor.start(config: config)
        }
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

            VStack(alignment: .trailing, spacing: 2) {
                modeIndicator
                if let lastScan = monitor.lastScan {
                    Text("Scanned \(lastScan, style: .relative) ago")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var modeIndicator: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(modeColor)
                .frame(width: 6, height: 6)
            Text(config.killMode.displayName)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var modeColor: Color {
        switch config.killMode {
        case .smart: return .green
        case .notificationOnly: return .blue
        case .aggressive: return .red
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 32))
                .foregroundStyle(.green)
            Text("All clear")
                .font(.headline)
            Text("No zombie processes detected")
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

            ForEach(monitor.zombieProcesses) { process in
                ProcessRowView(process: process, isZombie: true) {
                    monitor.killProcess(process)
                }
            }

            if monitor.zombieProcesses.count > 1 {
                Button {
                    monitor.killAllZombies()
                } label: {
                    Label("Kill All Zombies", systemImage: "trash.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
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

            ForEach(monitor.suspectProcesses) { process in
                ProcessRowView(process: process, isZombie: false) {
                    monitor.killProcess(process)
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
            Button {
                Task { await monitor.scan() }
            } label: {
                Label("Scan Now", systemImage: "arrow.clockwise")
            }
            .disabled(monitor.isScanning)

            Spacer()

            Button {
                openSettings()
            } label: {
                Label("Settings", systemImage: "gear")
            }

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("Quit", systemImage: "power")
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
