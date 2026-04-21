import SwiftUI

/// Compact 3-row meter showing Memory / Last / Swap pressure.
/// Rendered at the top of the MenuBar dropdown whenever a pressure snapshot
/// is available. Keeps itself lightweight — no timers, only reacts to the
/// monitor's published snapshot.
struct PressureMeterView: View {
    @ObservedObject var monitor: ProcessMonitor

    var body: some View {
        if let snapshot = monitor.pressure {
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                // Memory row — colored progress bar
                GridRow {
                    Text("Speicher")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    memoryBar(for: snapshot.memoryPressure)
                    Text(memoryLabel(for: snapshot.memoryPressure))
                        .font(.caption)
                        .foregroundStyle(color(for: snapshot.memoryPressure))
                        .gridColumnAlignment(.trailing)
                }

                // Load row — loadFactor with core count
                GridRow {
                    Text("Last")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        Text(String(format: "%.1f×", snapshot.loadFactor))
                            .font(.caption.monospacedDigit())
                            .fontWeight(.medium)
                            .foregroundStyle(loadColor(for: snapshot.loadFactor))
                        Text("(\(snapshot.ncpu) Kerne)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .gridCellColumns(2)
                }

                // Compressor / swap row — on Apple Silicon the compressor is
                // the active signal; swap stays ~0. Show whichever is higher.
                GridRow {
                    Text(memoryLabelForMetric(snapshot: snapshot))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        Text(memoryMetricText(snapshot: snapshot))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(memoryMetricColor(snapshot: snapshot))
                        // Rate label only makes sense when the row shows "Compressed" — when
                        // the row flips to "Swap" (swap usage dominant), the compressionRate
                        // number is still about the compressor and would mislead.
                        if snapshot.compressionRate >= 100, memoryLabelForMetric(snapshot: snapshot) == "Compressed" {
                            Text(String(format: "↑ %.0f/s", snapshot.compressionRate))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.orange)
                        }
                    }
                    .gridCellColumns(2)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilitySummary(for: snapshot))
        }
    }

    // MARK: - Memory bar

    @ViewBuilder
    private func memoryBar(for level: PressureLevel) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.secondary.opacity(0.15))
                RoundedRectangle(cornerRadius: 3)
                    .fill(color(for: level))
                    .frame(width: geo.size.width * memoryFill(for: level))
            }
        }
        .frame(height: 6)
    }

    private func memoryFill(for level: PressureLevel) -> CGFloat {
        switch level {
        case .normal:   return 0.33
        case .elevated: return 0.66
        case .critical: return 1.0
        }
    }

    private func memoryLabel(for level: PressureLevel) -> String {
        switch level {
        case .normal:   return "normal"
        case .elevated: return "erhöht"
        case .critical: return "kritisch"
        }
    }

    private func color(for level: PressureLevel) -> Color {
        switch level {
        case .normal:   return .green
        case .elevated: return .orange
        case .critical: return .red
        }
    }

    // MARK: - Load color

    private func loadColor(for loadFactor: Double) -> Color {
        if loadFactor > 2 { return .red }
        if loadFactor > 1 { return .orange }
        return .green
    }

    // MARK: - Memory metric (compressor / swap)

    /// Row label. Shows "Compressed" normally; switches to "Swap" if the user
    /// has actual swap usage (rare on M-series) so the underlying number is
    /// unambiguous.
    private func memoryLabelForMetric(snapshot: SystemPressureSnapshot) -> String {
        snapshot.swapUsageFraction > snapshot.compressorFraction ? "Swap" : "Compressed"
    }

    /// Formatted value for whichever metric is active (compressor or swap).
    private func memoryMetricText(snapshot: SystemPressureSnapshot) -> String {
        if snapshot.swapUsageFraction > snapshot.compressorFraction {
            let usedGB = snapshot.swapUsedMB / 1024
            let totalGB = snapshot.swapTotalMB / 1024
            return String(format: "%.1f / %.1f GB", usedGB, totalGB)
        }
        let mb = snapshot.compressorUsedMB
        if mb >= 1024 {
            return String(format: "%.1f GB", mb / 1024)
        }
        return String(format: "%.0f MB", mb)
    }

    private func memoryMetricColor(snapshot: SystemPressureSnapshot) -> Color {
        let fraction = snapshot.memoryUsageFraction
        if fraction >= 0.8 { return .red }
        if fraction >= 0.3 { return .orange }
        return .green
    }

    // MARK: - Accessibility

    private func accessibilitySummary(for snapshot: SystemPressureSnapshot) -> String {
        let mem = memoryLabel(for: snapshot.memoryPressure)
        let load = String(format: "%.1f×", snapshot.loadFactor)
        let label = memoryLabelForMetric(snapshot: snapshot)
        let value = memoryMetricText(snapshot: snapshot)
        return "System-Druck. Memory \(mem). Last \(load) auf \(snapshot.ncpu) Kernen. \(label) \(value)."
    }
}
