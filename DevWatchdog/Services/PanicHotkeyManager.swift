import AppKit
import Carbon.HIToolbox

/// Global hotkey registration for the Panic action.
///
/// AppKit has no public Swift API for global hotkeys, so we use Carbon's
/// `RegisterEventHotKey`. The C callback trampoline recovers `self` via an
/// `Unmanaged` pointer passed through `userData`.
///
/// Default shortcut: ⌘⇧⌥P.
@MainActor
final class PanicHotkeyManager {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    /// Retained callback. Accessed from the Carbon trampoline via
    /// `Unmanaged.passUnretained(self)`; guarded by main-thread dispatch.
    private var handler: (@Sendable @MainActor () -> Void)?

    /// Four-char-code signature used to identify our hotkey registration.
    /// "DWPn" — DevWatchdog Panic.
    private static let signature: OSType = {
        let chars: [UInt8] = [0x44, 0x57, 0x50, 0x6E] // "DWPn"
        return (OSType(chars[0]) << 24) | (OSType(chars[1]) << 16)
             | (OSType(chars[2]) << 8)  | OSType(chars[3])
    }()

    // NOTE: no `deinit`-based cleanup. Swift 6 strict concurrency blocks
    // access to the non-Sendable `EventHandlerRef` / `EventHotKeyRef` from a
    // nonisolated deinit. Lifecycle cleanup happens via `unregister()` wired
    // into `NSApplication.willTerminateNotification` in `DevWatchdogApp`.

    /// Register the global hotkey. Safe to call multiple times — re-registration
    /// tears down the previous hotkey first.
    ///
    /// Default: ⌘⇧⌥P.
    func register(
        keyCode: UInt32 = UInt32(kVK_ANSI_P),
        modifiers: UInt32 = UInt32(cmdKey | shiftKey | optionKey),
        onTrigger: @escaping @Sendable @MainActor () -> Void
    ) {
        unregister()
        self.handler = onTrigger

        // Install an Application-level event handler for kEventHotKeyPressed.
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            panicHotkeyCallback,
            1,
            &eventType,
            selfPtr,
            &eventHandler
        )
        guard installStatus == noErr else {
            NSLog("DevWatchdog: InstallEventHandler failed with status \(installStatus)")
            self.handler = nil
            return
        }

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: 1)
        let registerStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        if registerStatus != noErr {
            NSLog("DevWatchdog: RegisterEventHotKey failed with status \(registerStatus)")
            if let eventHandler {
                RemoveEventHandler(eventHandler)
                self.eventHandler = nil
            }
            self.handler = nil
        }
    }

    /// Tear down any registered hotkey and event handler. Idempotent.
    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
        handler = nil
    }

    /// Called from the Carbon C trampoline on the main run loop.
    fileprivate func fireHandler() {
        // Defensive dispatch: Carbon fires on the main run loop, but we route
        // through MainActor to satisfy Swift 6 isolation checks.
        let handler = self.handler
        Task { @MainActor in
            handler?()
        }
    }
}

// MARK: - C trampoline

/// Carbon requires a plain (`@convention(c)`) function pointer. We recover the
/// `PanicHotkeyManager` instance from `userData` and invoke its handler on the
/// main actor.
private func panicHotkeyCallback(
    nextHandler: EventHandlerCallRef?,
    event: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData else { return OSStatus(eventNotHandledErr) }
    let manager = Unmanaged<PanicHotkeyManager>.fromOpaque(userData).takeUnretainedValue()
    // `fireHandler` is @MainActor; we assume the Carbon event loop fires on main.
    MainActor.assumeIsolated {
        manager.fireHandler()
    }
    return noErr
}
