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
            }
            .frame(maxHeight: 400)

            Divider()

            // Footer actions
            footerSection
        }
        .frame(width: 380)
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
                HStack(spacing: 4) {
                    Circle()
                        .fill(.green)
                        .frame(width: 6, height: 6)
                    Text("Auto-Kill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
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
                            Text("Kill \(count) Zombie\(count == 1 ? "" : "s")")
                                .fontWeight(.medium)
                            Text("\(String(format: "%.0f", memMB)) MB — orphaned or expired, safe to kill")
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
                .help("Kills all zombie processes. These are orphaned (no parent) or exceeded their max runtime. Always safe — nobody is using them.")
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
                            Text("Kill \(count) Suspects")
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
        if maxCPU > 50 { return "some active (up to \(String(format: "%.0f", maxCPU))% CPU)" }
        if maxCPU > 1 { return "low activity, review recommended" }
        return "all idle, safe to kill"
    }

    private func suspectRiskIcon(maxCPU: Double) -> String {
        if maxCPU > 50 { return "exclamationmark.triangle.fill" }
        if maxCPU > 1 { return "questionmark.circle.fill" }
        return "checkmark.shield.fill"
    }

    private func suspectRiskTooltip(maxCPU: Double) -> String {
        if maxCPU > 50 {
            return "Some suspects are actively using CPU (\(String(format: "%.0f", maxCPU))%). This could be a running test or build. Review the list before killing."
        }
        if maxCPU > 1 {
            return "Some suspects show low CPU activity. Probably safe, but check the list for anything you recognize."
        }
        return "All suspects are at 0% CPU — idle processes that are safe to kill."
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
