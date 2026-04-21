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
///
/// Memory-backing story:
/// - `swapUsedMB/swapTotalMB` come from `vm.swapusage`. On Apple Silicon this is
///   almost always zero — macOS prefers the in-RAM compressor before touching
///   file-backed swap.
/// - `compressorUsedMB` comes from `host_statistics64(HOST_VM_INFO64)` and is
///   the primary memory-pressure signal on modern Macs.
/// - `physicalMemoryMB` is the machine's total RAM (stable for the session).
/// - `compressionRate` is compressions/sec between two poll samples; >0 means
///   the kernel is actively reclaiming pages.
struct SystemPressureSnapshot: Sendable, Equatable {
    let level: PressureLevel
    let memoryPressure: PressureLevel
    let loadAverage1m: Double
    let ncpu: Int
    let swapUsedMB: Double
    let swapTotalMB: Double
    let compressorUsedMB: Double
    let physicalMemoryMB: Double
    let compressionRate: Double
    let timestamp: Date

    init(
        level: PressureLevel,
        memoryPressure: PressureLevel,
        loadAverage1m: Double,
        ncpu: Int,
        swapUsedMB: Double,
        swapTotalMB: Double,
        compressorUsedMB: Double = 0,
        physicalMemoryMB: Double = 0,
        compressionRate: Double = 0,
        timestamp: Date
    ) {
        self.level = level
        self.memoryPressure = memoryPressure
        self.loadAverage1m = loadAverage1m
        self.ncpu = ncpu
        self.swapUsedMB = swapUsedMB
        self.swapTotalMB = swapTotalMB
        self.compressorUsedMB = compressorUsedMB
        self.physicalMemoryMB = physicalMemoryMB
        self.compressionRate = compressionRate
        self.timestamp = timestamp
    }

    /// Load average normalized by CPU count. 1.0 == fully saturated, >1.0 == overloaded.
    var loadFactor: Double {
        ncpu > 0 ? loadAverage1m / Double(ncpu) : 0
    }

    /// Fraction of swap space currently used (0.0 – 1.0).
    /// Near-zero on Apple Silicon — prefer ``memoryUsageFraction``.
    var swapUsageFraction: Double {
        swapTotalMB > 0 ? swapUsedMB / swapTotalMB : 0
    }

    /// Fraction of physical RAM currently held by the compressor (0.0 – 1.0).
    /// Primary memory-pressure proxy on Apple Silicon.
    var compressorFraction: Double {
        guard physicalMemoryMB > 0 else { return 0 }
        return min(1.0, compressorUsedMB / physicalMemoryMB)
    }

    /// Best single "memory-pressured" proxy: whichever of compressor or swap is
    /// larger. On Apple Silicon this tracks the compressor; on Intel (and edge
    /// cases with configured swap files) it tracks swap usage.
    var memoryUsageFraction: Double {
        max(compressorFraction, swapUsageFraction)
    }
}
