import SwiftUI

/// Settings tab for Emergency Mode (issue #10).
///
/// Exposes the adaptive-pressure thresholds and kill-strategy preferences stored on
/// ``WatchdogConfig``. When a ``ProcessMonitor`` is supplied, also renders a read-only
/// "Aktuelle Werte" panel reflecting the live pressure snapshot and derived state.
/// When `monitor` is `nil`, the live panel is omitted (e.g. because a future
/// `DevWatchdogApp` wiring hasn't threaded the shared monitor into settings yet).
struct EmergencySettingsView: View {
    @ObservedObject var config: WatchdogConfig
    @ObservedObject var monitor: ProcessMonitor

    var body: some View {
        Form {
            EmergencyModeSections(config: config)
            liveReadoutSection
        }
        .formStyle(.grouped)
    }

    // MARK: - Live readout

    @ViewBuilder
    private var liveReadoutSection: some View {
        Section("Aktuelle Werte") {
            LabeledContent("Emergency-Status") {
                HStack(spacing: 6) {
                    Circle()
                        .fill(stateColor(monitor.emergencyState))
                        .frame(width: 10, height: 10)
                    Text(monitor.emergencyState.displayName)
                        .monospacedDigit()
                }
            }

            if let snapshot = monitor.pressure {
                LabeledContent("Load / Kerne") {
                    Text(String(format: "%.2f / %d  (factor %.2f×)",
                                snapshot.loadAverage1m,
                                snapshot.ncpu,
                                snapshot.loadFactor))
                        .monospacedDigit()
                }

                LabeledContent("Memory Pressure") {
                    Text(pressureDisplayName(snapshot.memoryPressure))
                        .monospacedDigit()
                }

                LabeledContent("Compressed") {
                    Text(compressedText(snapshot: snapshot))
                        .monospacedDigit()
                }

                if snapshot.swapTotalMB > 0 {
                    LabeledContent("Swap") {
                        Text(String(format: "%.1f / %.1f GB",
                                    snapshot.swapUsedMB / 1024,
                                    snapshot.swapTotalMB / 1024))
                            .monospacedDigit()
                    }
                }
            } else {
                Text("Warte auf ersten Pressure-Snapshot …")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func stateColor(_ state: EmergencyState) -> Color {
        switch state {
        case .normal:    return .green
        case .elevated:  return .yellow
        case .emergency: return .red
        }
    }

    private func pressureDisplayName(_ level: PressureLevel) -> String {
        switch level {
        case .normal:   return "normal"
        case .elevated: return "warn"
        case .critical: return "critical"
        }
    }

    /// "X MB" / "Y.Z GB" of compressed pages, plus the total RAM for context
    /// so the reader can form a mental fraction without doing the math.
    private func compressedText(snapshot: SystemPressureSnapshot) -> String {
        let mb = snapshot.compressorUsedMB
        let fracPct = snapshot.compressorFraction * 100
        let rateSuffix = snapshot.compressionRate >= 100
            ? String(format: "  ↑ %.0f/s", snapshot.compressionRate)
            : ""
        if mb >= 1024 {
            return String(format: "%.1f GB (%.0f%%)%@", mb / 1024, fracPct, rateSuffix)
        }
        return String(format: "%.0f MB (%.0f%%)%@", mb, fracPct, rateSuffix)
    }
}

/// Variant used when no ``ProcessMonitor`` has been injected — same controls,
/// but without the live "Aktuelle Werte" panel. Keeps the main
/// ``EmergencySettingsView`` signature a simple non-optional
/// `@ObservedObject`, which plays nicest with SwiftUI's diffing.
struct EmergencySettingsViewNoLive: View {
    @ObservedObject var config: WatchdogConfig

    var body: some View {
        Form {
            EmergencyModeSections(config: config)
            Section {
                Text("Live-Werte nicht verfügbar — Monitor nicht injiziert.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Shared form sections

/// Shared settings controls for both live and live-less variants.
private struct EmergencyModeSections: View {
    @ObservedObject var config: WatchdogConfig

    var body: some View {
        Section("Emergency Mode") {
            Toggle("Emergency Mode aktiviert", isOn: $config.emergencyModeEnabled)
                .help("Passt Scan-Intervall und Grace-Period automatisch an System-Druck an.")
            Text("Drosselt die Regeln automatisch bei System-Druck.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section("Auslöse-Schwellen") {
            LabeledContent("Load-Faktor für Emergency") {
                HStack {
                    Slider(value: $config.emergencyLoadFactor, in: 1.0...5.0, step: 0.1)
                        .frame(maxWidth: 200)
                    Text(String(format: "%.1f×", config.emergencyLoadFactor))
                        .monospacedDigit()
                        .frame(width: 50, alignment: .trailing)
                }
            }
            .disabled(!config.emergencyModeEnabled)
            Text("Multiplikator relativ zu Anzahl CPU-Kerne — überschritten → Emergency-Zustand.")
                .font(.caption)
                .foregroundStyle(.secondary)

            LabeledContent("Load-Faktor für Elevated") {
                HStack {
                    Slider(value: $config.elevatedLoadFactor, in: 0.5...2.0, step: 0.1)
                        .frame(maxWidth: 200)
                    Text(String(format: "%.1f×", config.elevatedLoadFactor))
                        .monospacedDigit()
                        .frame(width: 50, alignment: .trailing)
                }
            }
            .disabled(!config.emergencyModeEnabled)

            LabeledContent("Cooldown (Sekunden)") {
                Stepper(
                    value: $config.emergencyCooldown,
                    in: 5...300,
                    step: 5
                ) {
                    Text("\(Int(config.emergencyCooldown)) s")
                        .monospacedDigit()
                }
                .frame(maxWidth: 200)
            }
            .disabled(!config.emergencyModeEnabled)
            Text("Wie lange nach Druck-Ende, bevor Emergency deaktiviert wird.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section("Kill-Strategie") {
            Toggle("Soft-Kill bevorzugen (SIGSTOP/renice vor SIGKILL)", isOn: $config.softKillPreferred)
                .help("Reversibler Schritt — Prozess kann mit Fortsetzen weiterlaufen.")
            Text("Reversibler Schritt — Prozess kann mit Fortsetzen weiterlaufen.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
