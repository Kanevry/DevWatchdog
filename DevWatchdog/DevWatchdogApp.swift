import SwiftUI
import UserNotifications

@main
struct DevWatchdogApp: App {
    /// Owns the status-bar `NSStatusItem`, popover, and termination-observer
    /// lifecycle. Replaces the former `MenuBarExtra` scene — see ``AppDelegate``
    /// for the rationale (FB11857447 stale-label bug + xctest IPC hang under
    /// the `TimelineView(.periodic)` workaround).
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // Shared SystemPressureMonitor instance — powers ProcessMonitor's `pressure`
    // publisher and is available to future Emergency-Mode views via environment.
    @StateObject private var pressureMonitor: SystemPressureMonitor
    @StateObject private var processMonitor: ProcessMonitor
    @StateObject private var config = WatchdogConfig()

    // Panic subsystem — global hotkey + action runner. Instantiated here so
    // they share lifetime with the App and the ProcessMonitor.
    private let panicHotkey = PanicHotkeyManager()
    private let panicAction: PanicAction

    @MainActor
    init() {
        let pressure = SystemPressureMonitor()
        let monitor = ProcessMonitor(pressureSource: pressure)
        let cfg = WatchdogConfig()
        _pressureMonitor = StateObject(wrappedValue: pressure)
        _processMonitor = StateObject(wrappedValue: monitor)
        _config = StateObject(wrappedValue: cfg)
        self.panicAction = PanicAction(monitor: monitor, config: cfg)

        // Hand the same instances to the delegate so its
        // `applicationDidFinishLaunching` can wire up the status bar + popover
        // against the live monitors.
        AppDelegate.prepare(AppDelegate.Bootstrap(
            monitor: monitor,
            config: cfg,
            panicAction: panicAction,
            panicHotkey: panicHotkey,
            openSettings: DevWatchdogApp.makeOpenSettingsCallback(
                config: cfg,
                monitor: monitor
            )
        ))
    }

    /// An LSUIElement app still needs at least one `Scene` to satisfy the
    /// `App` protocol. The `Settings` scene is never surfaced in the UI (no
    /// Dock, no main menu, no `SettingsLink`) — it exists solely as scene
    /// scaffolding. All real UI comes from the status item + popover owned
    /// by ``AppDelegate``.
    var body: some Scene {
        Settings { EmptyView() }
    }

    /// Factory for the "open settings window" callback passed into the
    /// popover. Returns a closure that manages a single reusable NSWindow —
    /// the same behavior the app had under the old `MenuBarExtra` setup, so
    /// clicking the gear button in the popover opens or surfaces the window
    /// without spawning duplicates.
    @MainActor
    private static func makeOpenSettingsCallback(
        config: WatchdogConfig,
        monitor: ProcessMonitor
    ) -> @MainActor () -> Void {
        // `Box` keeps the NSWindow reference alive across closure invocations
        // without using a static var (which would leak across app relaunches
        // in tests and hot-reload scenarios).
        final class Box: @unchecked Sendable {
            var window: NSWindow?
        }
        let box = Box()
        return { @MainActor in
            if let window = box.window, window.isVisible {
                window.makeKeyAndOrderFront(nil)
                NSApp.activate()
                return
            }
            let view = SettingsView(config: config, monitor: monitor)
            let hosting = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: hosting)
            window.title = "DevWatchdog Settings"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 520, height: 600))
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            box.window = window
        }
    }
}
