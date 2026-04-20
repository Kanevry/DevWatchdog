import SwiftUI

/// Pulsing opacity wrapper used for the menubar bolt during ``EmergencyState.emergency``.
///
/// Keep this isolated in its own view: ``TimelineView(.animation)`` drives a
/// redraw every frame, so we don't want it wrapping unrelated content.
struct PulsingEmergencyIcon: View {
    /// Short label shown next to the icon (e.g. "2.4×" load factor or swap fraction).
    let indicator: String?

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let phase = pulse(at: context.date)
            HStack(spacing: 2) {
                ZStack {
                    Circle()
                        .fill(Color.red.opacity(0.85))
                        .frame(width: 14, height: 14)
                        .opacity(0.7 + 0.3 * phase)
                    Image(systemName: "bolt.fill")
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(.white)
                        .font(.system(size: 9, weight: .bold))
                }
                if let indicator {
                    Text(indicator)
                        .font(.caption2.monospacedDigit())
                        .fontWeight(.semibold)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private func pulse(at date: Date) -> Double {
        let t = date.timeIntervalSinceReferenceDate
        return (sin(t * 2 * .pi / 1.2) + 1) / 2
    }
}

/// Static orange triangle for the elevated state — no animation.
struct ElevatedMenubarIcon: View {
    var body: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, .orange)
    }
}
