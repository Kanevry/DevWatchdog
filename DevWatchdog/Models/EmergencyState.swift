import Foundation

/// Overall emergency state derived from system pressure. Drives adaptive scan
/// interval, grace period, and (Wave 4+) triage behavior.
enum EmergencyState: String, Sendable, Codable, CaseIterable {
    case normal
    case elevated
    case emergency

    var displayName: String {
        switch self {
        case .normal:    return "Normal"
        case .elevated:  return "Elevated"
        case .emergency: return "Emergency"
        }
    }

    /// Ordering: .normal < .elevated < .emergency. Used by hysteresis logic to
    /// distinguish upward vs downward transitions.
    var severity: Int {
        switch self {
        case .normal:    return 0
        case .elevated:  return 1
        case .emergency: return 2
        }
    }
}

/// Pure, testable helper that turns ``SystemPressureSnapshot`` values into
/// ``EmergencyState`` decisions and applies hysteresis on downward transitions
/// so the UI / timers don't flap.
///
/// All methods are deterministic for their inputs — no hidden state. The caller
/// owns `lastHighSeenAt` and the current state.
struct EmergencyStateDeriver: Sendable {
    /// CPU core count. Only used for documentation / future heuristics; the
    /// snapshot already exposes `loadFactor` directly.
    let ncpu: Int
    /// `loadFactor` strictly greater than this → emergency (e.g. 2.0).
    let emergencyLoadFactor: Double
    /// `loadFactor` strictly greater than this → elevated (e.g. 1.0).
    let elevatedLoadFactor: Double
    /// Minimum dwell time in the desired (lower) state before a downward
    /// transition is permitted. Prevents flapping around threshold boundaries.
    let cooldownSeconds: TimeInterval

    init(
        ncpu: Int,
        emergencyLoadFactor: Double = 2.0,
        elevatedLoadFactor: Double = 1.0,
        cooldownSeconds: TimeInterval = 30
    ) {
        self.ncpu = ncpu
        self.emergencyLoadFactor = emergencyLoadFactor
        self.elevatedLoadFactor = elevatedLoadFactor
        self.cooldownSeconds = cooldownSeconds
    }

    /// Compute the desired state directly from a pressure snapshot.
    /// Promotes on either overall pressure level OR load factor thresholds.
    func desired(from snapshot: SystemPressureSnapshot) -> EmergencyState {
        let lf = snapshot.loadFactor
        if snapshot.level == .critical || lf > emergencyLoadFactor {
            return .emergency
        }
        if snapshot.level == .elevated || lf > elevatedLoadFactor {
            return .elevated
        }
        return .normal
    }

    /// Apply hysteresis to a `(current, desired)` pair.
    ///
    /// - Upward (desired ≥ current): transition immediately; update
    ///   `lastHighSeenAt` to `now`.
    /// - Downward (desired < current): only transition if `now - lastHighSeenAt`
    ///   exceeds `cooldownSeconds`. Otherwise stay in `current` and preserve
    ///   `lastHighSeenAt`.
    ///
    /// When `lastHighSeenAt` is `nil` and a downward transition is requested,
    /// we transition immediately — treat missing timestamp as "never been high".
    func nextState(
        current: EmergencyState,
        desired: EmergencyState,
        now: Date,
        lastHighSeenAt: Date?
    ) -> (state: EmergencyState, lastHighSeenAt: Date?) {
        if desired.severity >= current.severity {
            // Upward or same: immediate. Refresh the high-water timestamp so a
            // subsequent downward transition has to wait out the cooldown.
            return (desired, now)
        }

        // Downward: enforce cooldown measured from the last time we were at or
        // above `current`.
        guard let seenAt = lastHighSeenAt else {
            // No prior high-water mark — allow transition immediately.
            return (desired, nil)
        }

        if now.timeIntervalSince(seenAt) > cooldownSeconds {
            return (desired, nil)
        }
        // Still cooling down — stay put.
        return (current, seenAt)
    }
}
