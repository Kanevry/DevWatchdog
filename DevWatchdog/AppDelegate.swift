import AppKit
import SwiftUI
import UserNotifications

/// Owns the status-bar item, the popover that renders ``MenuBarView``, and the
/// app's termination observer / panic-hotkey lifecycle. Replaces the previous
/// `MenuBarExtra` scene in ``DevWatchdogApp`` because `MenuBarExtra` caches its
/// label at the menu-bar-server level until the user hovers (FB11857447), and
/// the only documented workaround (`TimelineView(.periodic)`) breaks
/// `xcodebuild test` with a 5.5 min IPC hang. Going straight to `NSStatusItem`
/// with `NSHostingView` is what Ice, Stats, and Multi.app all do.
///
/// State comes from ``DevWatchdogApp`` via ``prepare(_:)`` — the App struct
/// creates `@StateObject` instances in its `init()` and hands the *same
/// instances* to the delegate before AppKit fires `applicationDidFinishLaunching`.
/// This is the cleanest share pattern because `@StateObject` lifetime isn't
/// observable from an `NSApplicationDelegate`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Opaque bundle of everything the delegate needs to drive the UI.
    /// All references keep the App's `@StateObject` instances alive.
    struct Bootstrap {
        let monitor: ProcessMonitor
        let config: WatchdogConfig
        let panicAction: PanicAction
        let panicHotkey: PanicHotkeyManager
        let openSettings: @MainActor () -> Void
    }

    /// Set once by ``DevWatchdogApp.init()`` before AppKit fires
    /// `applicationDidFinishLaunching`. `nonisolated(unsafe)` because `App` is
    /// a value type — we can't stash on an instance — and the assignment runs
    /// on MainActor before anything reads the value on MainActor.
    nonisolated(unsafe) private static var pending: Bootstrap?

    static func prepare(_ bootstrap: Bootstrap) {
        pending = bootstrap
    }

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var terminationObserver: NSObjectProtocol?

    // Strong refs kept so the `@StateObject`-backed instances don't get dropped
    // if the App struct's lifetime differs from the delegate's somehow.
    private var monitor: ProcessMonitor?
    private var config: WatchdogConfig?
    private var panicAction: PanicAction?
    private var panicHotkey: PanicHotkeyManager?

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Tests host the full app; status bar + popover construction is cheap
        // and must not skip — if skipped, any code that *does* reach the
        // delegate in tests would NPE on statusItem. There's no `Settings`
        // scene in tests either, so bootstrap has to run normally.
        guard let boot = Self.pending else { return }
        self.monitor = boot.monitor
        self.config = boot.config
        self.panicAction = boot.panicAction
        self.panicHotkey = boot.panicHotkey

        configureStatusItem(with: boot.monitor)
        configurePopover(
            monitor: boot.monitor,
            config: boot.config,
            panicAction: boot.panicAction,
            openSettings: boot.openSettings
        )

        bootstrapLogger(config: boot.config)

        // Kick off the scan loop + pressure observation.
        boot.monitor.start(config: boot.config)

        // Global ⌘⇧⌥P hotkey for Panic. Independent of any UI element.
        let action = boot.panicAction
        boot.panicHotkey.register { @MainActor in
            action.execute()
        }

        // Graceful shutdown on app termination.
        let monitor = boot.monitor
        let hotkey = boot.panicHotkey
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                monitor.stop()
                hotkey.unregister()
            }
        }
    }

    // MARK: - Status item setup

    private func configureStatusItem(with monitor: ProcessMonitor) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else {
            assertionFailure("NSStatusItem.button returned nil — status bar unavailable?")
            return
        }

        // Put the SwiftUI label directly into the button. NSHostingView observes
        // @Published changes via SwiftUI's normal mechanism, so icon/count/color
        // transitions flow without the MenuBarExtra snapshot-cache bug.
        let label = MenuBarLabel(monitor: monitor)
        let hosting = NSHostingView(rootView: label)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 4),
            hosting.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -4),
            hosting.centerYAnchor.constraint(equalTo: button.centerYAnchor),
        ])

        // Default NSButton fires on .leftMouseDown, which races the popover
        // presentation and causes a flicker. .leftMouseUp gives us clean toggles.
        button.target = self
        button.action = #selector(togglePopover(_:))
        button.sendAction(on: [.leftMouseUp])
        button.setAccessibilityLabel("DevWatchdog")
    }

    // MARK: - Popover setup

    private func configurePopover(
        monitor: ProcessMonitor,
        config: WatchdogConfig,
        panicAction: PanicAction,
        openSettings: @escaping @MainActor () -> Void
    ) {
        popover = NSPopover()
        // `.transient` gives us free outside-click dismissal — no custom
        // NSEvent global monitor needed.
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(
            rootView: MenuBarView(
                monitor: monitor,
                config: config,
                panicAction: panicAction,
                openSettings: openSettings
            )
        )
        // Roughly matches the old MenuBarExtra window. Actual size is dictated
        // by MenuBarView's .frame(width: 380) modifier; this only sets the
        // initial popover size before SwiftUI measures.
        popover.contentSize = NSSize(width: 400, height: 540)
    }

    // MARK: - Popover toggle

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem?.button, let popover else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // Without this, SwiftUI `.keyboardShortcut(...)` modifiers inside
            // the popover don't fire — the popover's content window is not
            // key on present.
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    // MARK: - Logger bootstrap

    private func bootstrapLogger(config: WatchdogConfig) {
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
    }
}
