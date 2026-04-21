import SwiftUI
import UserNotifications

@main
struct DevWatchdogApp: App {
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
    }
    @State private var settingsWindow: NSWindow?
    @State private var hasStarted = false

    // Store observer token — nonisolated(unsafe) static because App is a struct
    nonisolated(unsafe) private static var terminationObserver: NSObjectProtocol?

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(
                monitor: processMonitor,
                config: config,
                panicAction: panicAction,
                openSettings: openSettings
            )
                .task { @MainActor in
                    guard !hasStarted else { return }
                    hasStarted = true

                    DWLogger.shared.bootstrap(
                        appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
                        buildNumber: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0",
                        osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                        ncpu: ProcessInfo.processInfo.activeProcessorCount,
                        configSnapshot: [
                            "scanInterval": String(config.scanInterval),
                            "emergencyMode": String(config.emergencyModeEnabled),
                            "orphanTimeout": String(config.orphanTimeout),
                            "gracePeriod": String(config.gracePeriod),
                        ]
                    )

                    processMonitor.start(config: config)

                    // Register the global panic hotkey (⌘⇧⌥P).
                    let action = panicAction
                    panicHotkey.register { @MainActor in
                        action.execute()
                    }

                    let hotkey = panicHotkey
                    Self.terminationObserver = NotificationCenter.default.addObserver(
                        forName: NSApplication.willTerminateNotification,
                        object: nil,
                        queue: .main
                    ) { [weak processMonitor] _ in
                        MainActor.assumeIsolated {
                            processMonitor?.stop()
                            hotkey.unregister()
                        }
                    }
                }
        } label: {
            // Workaround for FB11857447 / FB12094112 (open through macOS 15.x
            // and macOS 26 beta as of April 2026): SwiftUI caches the label
            // snapshot until the menu bar item is hit-tested (hover/click), so
            // @Published changes from `processMonitor` don't propagate until the
            // user interacts. Wrapping in `TimelineView(.periodic)` forces the
            // subtree to re-evaluate on a low-frequency cadence, pulling fresh
            // values from the ObservableObject on each tick.
            //
            // Cadence: 1 s normally, 4 s on Low Power Mode. Higher rates burn
            // energy for no visible benefit (the label only shows counts and
            // state, not per-second numeric changes).
            TimelineView(.periodic(from: .now, by: labelRefreshInterval)) { _ in
                menuBarLabel
            }
        }
        .menuBarExtraStyle(.window)
    }

    /// Low-Power Mode stretches refresh to 4 s; normal runs at 1 Hz.
    /// `TimelineView` re-reads this on each tick, so a toggle of LPM mid-session
    /// takes at most one interval to apply.
    private var labelRefreshInterval: TimeInterval {
        ProcessInfo.processInfo.isLowPowerModeEnabled ? 4.0 : 1.0
    }

    private var menuBarLabel: some View {
        let zombieCount = processMonitor.zombieProcesses.count
        let suspectCount = processMonitor.suspectProcesses.count
        let state = processMonitor.emergencyState
        let pressure = processMonitor.pressure

        return HStack(spacing: 2) {
            switch state {
            case .emergency:
                PulsingEmergencyIcon(indicator: emergencyIndicator(for: pressure))
                    .accessibilityLabel("DevWatchdog — Emergency Mode active")
            case .elevated:
                ElevatedMenubarIcon()
                    .accessibilityLabel("DevWatchdog — Elevated system pressure")
            case .normal:
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

    private func openSettings() {
        if let window = settingsWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }

        let settingsView = SettingsView(config: config, monitor: processMonitor)
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
