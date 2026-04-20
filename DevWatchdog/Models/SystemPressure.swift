import Foundation

/// Coarse-grained system pressure level. Ordered so that higher = more severe.
enum PressureLevel: Int, Sendable, Comparable, Codable {
    case normal = 0
    case elevated = 1
    case critical = 2

    static func < (lhs: PressureLevel, rhs: PressureLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Point-in-time snapshot of the system's resource pressure.
///
/// `level` is the derived overall level (max of inputs). `memoryPressure` reflects
/// the last known macOS memory pressure event. `loadAverage1m` is the 1-minute
/// load average (per-machine; divide by `ncpu` for per-core utilization).
struct SystemPressureSnapshot: Sendable, Equatable {
    let level: PressureLevel
    let memoryPressure: PressureLevel
    let loadAverage1m: Double
    let ncpu: Int
    let swapUsedMB: Double
    let swapTotalMB: Double
    let timestamp: Date

    /// Load average normalized by CPU count. 1.0 == fully saturated, >1.0 == overloaded.
    var loadFactor: Double {
        ncpu > 0 ? loadAverage1m / Double(ncpu) : 0
    }

    /// Fraction of swap space currently used (0.0 – 1.0).
    var swapUsageFraction: Double {
        swapTotalMB > 0 ? swapUsedMB / swapTotalMB : 0
    }
}
