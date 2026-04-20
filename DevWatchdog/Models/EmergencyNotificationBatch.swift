import Foundation

/// Decision about what notifications to emit in response to an emergency-related
/// event (state transition or in-emergency kill). Pure value type — all fields
/// are booleans the caller can act on.
struct EmergencyNotificationDecision: Equatable, Sendable {
    /// Emit the "entering emergency" alert (critical, with sound).
    let sendEntryAlert: Bool
    /// Emit the "emergency ended" summary (info level).
    let sendExitAlert: Bool
    /// Emit a notification for a kill that happened during an active emergency.
    /// Typically `false` — individual kills are batched into the exit summary.
    let sendKillDuringEmergency: Bool
    /// While `true`, callers should suppress per-kill notifications and let the
    /// exit summary aggregate them.
    let suppressIndividualKills: Bool

    static let none = EmergencyNotificationDecision(
        sendEntryAlert: false,
        sendExitAlert: false,
        sendKillDuringEmergency: false,
        suppressIndividualKills: false
    )
}

/// Pure decision table for emergency-aware notification batching.
///
/// Collapses the "what should we notify?" question down to a handful of
/// boolean flags so the live `ProcessMonitor` stays thin and the behaviour
/// is fully unit-testable without any UNUserNotificationCenter involvement.
enum EmergencyNotificationBatcher {
    /// Given an emergency state transition, decide what to send.
    ///
    /// Rules:
    /// - anything → `.emergency`: entry alert, suppress individual kills
    /// - `.emergency` → anything: exit summary, stop suppressing
    /// - all other transitions: quiet (no spam on elevated↔normal)
    static func onStateTransition(
        from: EmergencyState,
        to: EmergencyState
    ) -> EmergencyNotificationDecision {
        let enteringEmergency = (to == .emergency && from != .emergency)
        let exitingEmergency  = (from == .emergency && to != .emergency)

        return EmergencyNotificationDecision(
            sendEntryAlert: enteringEmergency,
            sendExitAlert: exitingEmergency,
            sendKillDuringEmergency: false,
            // We suppress while *in* emergency. On entry that flips on, on exit it flips off.
            suppressIndividualKills: (to == .emergency)
        )
    }

    /// For a kill event occurring during an active emergency period.
    ///
    /// Returns `suppressIndividualKills = true` while in `.emergency` —
    /// the caller should increment a counter instead of sending a toast.
    /// Outside emergency, `sendKillDuringEmergency` reverts to `true` so
    /// the normal batch-kill flow is used.
    ///
    /// `isNewBatch` is accepted to keep the signature future-proof (e.g. for
    /// a "first kill in this emergency" one-shot alert); it does not change
    /// behaviour in v2.1.
    static func onKillDuringEmergency(
        emergencyState: EmergencyState,
        isNewBatch: Bool
    ) -> EmergencyNotificationDecision {
        if emergencyState == .emergency {
            return EmergencyNotificationDecision(
                sendEntryAlert: false,
                sendExitAlert: false,
                sendKillDuringEmergency: false,
                suppressIndividualKills: true
            )
        }
        return EmergencyNotificationDecision(
            sendEntryAlert: false,
            sendExitAlert: false,
            sendKillDuringEmergency: true,
            suppressIndividualKills: false
        )
    }
}
