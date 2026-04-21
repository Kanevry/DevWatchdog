import Foundation

/// Hardware-aware recommendation values for ``WatchdogConfig`` sliders.
///
/// These are *suggestions*, not defaults — the UI surfaces them next to each
/// slider so the user can compare their current setting against a machine-
/// appropriate value (e.g. "Empfohlen: 120s für 32 GB RAM"). The defaults in
/// ``WatchdogConfig`` stay generic (tuned for ~16 GB development machines);
/// recommendations scale them up or down based on the measured host.
///
/// Pure value type with no SwiftUI / actor dependencies so the logic can be
/// unit-tested directly.
enum SettingsRecommendations {

    // MARK: - Machine measurements

    /// Physical RAM in gigabytes, measured once per query (cheap). Rounded
    /// down since macOS reports slightly less than the marketed size.
    static var physicalRAMGB: Double {
        Double(ProcessInfo.processInfo.physicalMemory) / (1024.0 * 1024.0 * 1024.0)
    }

    /// Logical core count (includes hyperthreads on Intel; `ncpu` on Apple
    /// Silicon equals performance + efficiency cores).
    static var logicalCoreCount: Int {
        ProcessInfo.processInfo.activeProcessorCount
    }

    // MARK: - Per-setting recommendations

    /// Scan interval recommendation. Smaller machines benefit from slightly
    /// longer intervals (battery), larger machines can afford to relax even
    /// more since long-running dev processes are expected.
    ///
    /// - `<8 GB RAM` → 60 s (still responsive, less battery churn)
    /// - `8–16 GB RAM` → 30 s (current default)
    /// - `>=16 GB RAM` → 120 s (relaxed; tests/watchers legitimately live long)
    static var scanInterval: TimeInterval {
        let ram = physicalRAMGB
        if ram < 8 { return 60 }
        if ram >= 16 { return 120 }
        return 30
    }

    /// Grace period recommendation — the warning window before a zombie is
    /// killed. Stays at 30 s across all hardware; exposed for parity.
    static var gracePeriod: TimeInterval { 30 }

    /// Orphan timeout — how long a dev process may live as an orphan before
    /// it's flagged as zombie. 2 minutes is safe across hardware tiers.
    static var orphanTimeout: TimeInterval { 120 }

    /// Catch-all kill horizon — very long-running dev processes. Scales with
    /// RAM because large-memory machines are typically workstations hosting
    /// e.g. 12+ h vector-DB ingest jobs that *should* be allowed to run.
    ///
    /// - `<16 GB` → 4 h (catch leaked watchers faster)
    /// - `16–32 GB` → 8 h (current default)
    /// - `>32 GB` → 12 h (workstation-scale workloads welcome)
    static var catchAllMaxRuntime: TimeInterval {
        let ram = physicalRAMGB
        if ram < 16 { return 14_400 }
        if ram > 32 { return 43_200 }
        return 28_800
    }

    /// Emergency load factor — multiplier on the core count that constitutes
    /// "system overload". On Apple Silicon the efficiency cores are already
    /// counted, so 1.5× is a safer threshold than the old 2× on Intel.
    ///
    /// - `>=12 cores` (M-Pro / M-Max tier) → 1.3×
    /// - `4–12 cores` (M1/M2/M3 base) → 1.5×
    /// - `<4 cores` (rare) → 2.0× (old default; tiny machines spike easier)
    static var emergencyLoadFactor: Double {
        let cores = logicalCoreCount
        if cores >= 12 { return 1.3 }
        if cores >= 4 { return 1.5 }
        return 2.0
    }
}
