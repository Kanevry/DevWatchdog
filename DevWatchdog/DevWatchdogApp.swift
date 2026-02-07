import SwiftUI
import UserNotifications

@main
struct DevWatchdogApp: App {
    @StateObject private var processMonitor = ProcessMonitor()
    @StateObject private var config = WatchdogConfig()
    @State private var settingsWindow: NSWindow?

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(monitor: processMonitor, config: config, openSettings: openSettings)
        } label: {
            menuBarLabel
        }
        .menuBarExtraStyle(.window)
    }

    private var menuBarLabel: some View {
        let zombieCount = processMonitor.zombieProcesses.count
        let suspectCount = processMonitor.suspectProcesses.count

        return HStack(spacing: 2) {
            if zombieCount > 0 {
                Image(systemName: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .red)
                Text("\(zombieCount)")
            } else if suspectCount > 0 {
                Image(systemName: "eye.fill")
                    .foregroundStyle(.orange)
                Text("\(suspectCount)")
            } else {
                Image(systemName: "checkmark.shield.fill")
                    .foregroundStyle(.green)
            }
        }
    }

    private func openSettings() {
        if let window = settingsWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }

        let settingsView = SettingsView(config: config)
        let hostingController = NSHostingController(rootView: settingsView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "DevWatchdog Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 520, height: 600))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        settingsWindow = window
    }
}
