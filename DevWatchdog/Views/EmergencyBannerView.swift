import SwiftUI

/// Emergency banner shown at the top of the MenuBar dropdown while the
/// monitor is in ``EmergencyState.emergency``. Subtle pulsing gradient —
/// eye-catching without being distracting.
struct EmergencyBannerView: View {
    @ObservedObject var monitor: ProcessMonitor

    var body: some View {
        // TimelineView gives us a cheap, view-local animation source that
        // doesn't redraw the rest of MenuBarView.
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let phase = pulse(at: context.date)
            HStack(spacing: 10) {
                Image(systemName: "bolt.fill")
                    .symbolRenderingMode(.hierarchical)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                    .opacity(0.85 + 0.15 * phase)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Emergency Mode aktiv")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundStyle(.white)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.9))
                        .monospacedDigit()
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                LinearGradient(
                    colors: [
                        Color.red.opacity(0.85 + 0.1 * phase),
                        Color.orange.opacity(0.75 + 0.1 * phase)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Emergency Mode aktiv. \(subtitle)")
    }

    private var subtitle: String {
        let scan = Int(monitor.effectiveScanInterval.rounded())
        let grace = Int(monitor.effectiveGracePeriod.rounded())
        return "Aggressives Killen · \(scan) s Scan · Grace \(grace) s"
    }

    /// Smooth 0→1 sine wave with ~1.5s period.
    private func pulse(at date: Date) -> Double {
        let t = date.timeIntervalSinceReferenceDate
        return (sin(t * 2 * .pi / 1.5) + 1) / 2
    }
}
