import SwiftUI

/// Modal sheet shown on first launch to explain what Emergency Mode will do,
/// how to pause it, and that every action can be rolled back.
///
/// Wire from a parent view with:
/// ```swift
/// .sheet(isPresented: $showOnboarding) {
///     EmergencyOnboardingView(isPresented: $showOnboarding)
/// }
/// ```
///
/// On dismiss, the view sets `hasSeenEmergencyOnboarding` in UserDefaults
/// so the sheet is never shown again.
struct EmergencyOnboardingView: View {
    @Binding var isPresented: Bool

    /// UserDefaults key for "user has seen the onboarding sheet".
    /// Public so the coordinator can key a `.sheet(isPresented:)` off it.
    static let hasSeenKey = "hasSeenEmergencyOnboarding"

    init(isPresented: Binding<Bool>) {
        self._isPresented = isPresented
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header

            Divider()

            section(
                title: "Was der Emergency Mode tut",
                bullets: [
                    "Erkennt kritischen Memory-Druck oder hohe Last",
                    "Killt Top-Fresser sofort (Grace Period = 0)",
                    "Scannt alle 3 Sekunden statt 30"
                ]
            )

            section(
                title: "Wie du ihn pausierst",
                bullets: [
                    "Einstellungen → Emergency → \"Emergency Mode aktiviert\" ausschalten",
                    "Oder Panic-Hotkey einmal nutzen → Dry-Run-Mode"
                ]
            )

            section(
                title: "Alles kann rückgängig gemacht werden",
                bullets: [
                    "Soft-Kill (SIGSTOP) friert Prozesse ein — \"Fortsetzen\" reaktiviert",
                    "Session-Log zeigt alle Aktionen"
                ]
            )

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Text("Verstanden 🚀")
                        .frame(minWidth: 140)
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
                Spacer()
            }
        }
        .padding(28)
        .frame(width: 500, height: 500)
    }

    // MARK: - Subviews

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 4) {
                Text("Emergency Mode")
                    .font(.title)
                    .bold()
                Text("DevWatchdog reagiert jetzt automatisch bei System-Überlast.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func section(title: String, bullets: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            ForEach(bullets, id: \.self) { b in
                HStack(alignment: .top, spacing: 6) {
                    Text("•")
                    Text(b)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.callout)
            }
        }
    }

    // MARK: - Actions

    private func dismiss() {
        UserDefaults.standard.set(true, forKey: Self.hasSeenKey)
        isPresented = false
    }
}

#Preview {
    EmergencyOnboardingView(isPresented: .constant(true))
}
