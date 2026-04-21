import SwiftUI

/// Status-bar icon view.
///
/// Extracted from ``DevWatchdogApp`` so it can be hosted in the `AppDelegate`'s
/// `NSStatusItem.button` via `NSHostingView`. The `NSHostingView` path is the
/// workaround for FB11857447 / FB12094112 — the known macOS 14/15/16 bug where
/// `MenuBarExtra { … } label:` caches the status-bar snapshot until the user
/// hovers or clicks. With a hosted SwiftUI view inside `NSStatusItem` directly,
/// `@Published` changes on the monitor flow through SwiftUI's normal observation
/// path and the button re-renders immediately.
struct MenuBarLabel: View {
    @ObservedObject var monitor: ProcessMonitor

    var body: some View {
        HStack(spacing: 2) {
            switch monitor.emergencyState {
            case .emergency:
                PulsingEmergencyIcon(indicator: emergencyIndicator(for: monitor.pressure))
                    .accessibilityLabel("DevWatchdog — Emergency Mode active")
            case .elevated:
                ElevatedMenubarIcon()
                    .accessibilityLabel("DevWatchdog — Elevated system pressure")
            case .normal:
                let zombieCount = monitor.zombieProcesses.count
                let suspectCount = monitor.suspectProcesses.count
                if zombieCount > 0 {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .red)
                    Text("\(zombieCount)")
                        .monospacedDigit()
                        .accessibilityLabel("DevWatchdog — \(zombieCount) zombie processes")
                } else if suspectCount > 0 {
                    Image(systemName: "eye.fill")
                        .foregroundStyle(.orange)
                    Text("\(suspectCount)")
                        .monospacedDigit()
                        .accessibilityLabel("DevWatchdog — \(suspectCount) suspect processes")
                } else {
                    Image(systemName: "checkmark.shield.fill")
                        .foregroundStyle(.green)
                        .accessibilityLabel("DevWatchdog — all clear")
                }
            }
        }
    }

    /// Short numeric indicator shown next to the emergency bolt icon.
    /// Prefers the more severe of load factor and memory-pressure fraction
    /// (compressor on Apple Silicon, swap on Intel — whichever dominates).
    private func emergencyIndicator(for snapshot: SystemPressureSnapshot?) -> String? {
        guard let snapshot else { return nil }
        let load = snapshot.loadFactor
        let memFrac = snapshot.memoryUsageFraction
        if memFrac >= 0.8 {
            return String(format: "%.0f%%", memFrac * 100)
        }
        if load > 0 {
            return String(format: "%.1f×", load)
        }
        return nil
    }
}
