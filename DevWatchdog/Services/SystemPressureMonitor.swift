import Foundation
import Combine
import Darwin
import Dispatch

// MARK: - Protocol

/// A source of ``SystemPressureSnapshot`` values.
///
/// Implementations must be safe to reference from any isolation domain; the
/// publisher delivers values on an unspecified queue, so subscribers that need
/// main-actor isolation should hop explicitly (e.g. via `.receive(on: RunLoop.main)`).
protocol SystemPressureSource: AnyObject, Sendable {
    /// Begin observing system pressure. Idempotent.
    func start() async

    /// Stop observing and release any OS resources (dispatch sources, timers).
    ///
    /// Declared `async` so main-actor-isolated conformers (e.g. the default
    /// ``SystemPressureMonitor``) can satisfy it without cross-isolation races.
    func stop() async

    /// Latest known snapshot. Always returns *some* value — implementations
    /// seed this with a conservative default before any real observation.
    var currentSnapshot: SystemPressureSnapshot { get }

    /// Publisher that emits whenever the snapshot changes. Replays the most
    /// recent value to new subscribers.
    var snapshotPublisher: AnyPublisher<SystemPressureSnapshot, Never> { get }
}

// MARK: - Sysctl helpers (nonisolated, pure)

/// Low-level readers for `sysctlbyname` keys used by the pressure monitor.
/// Kept free-standing + `nonisolated` so they can be called from any actor.
enum SysctlReader {
    /// Number of logical CPU cores reported by the kernel.
    static func ncpu() -> Int {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let result = sysctlbyname("hw.ncpu", &value, &size, nil, 0)
        guard result == 0, value > 0 else { return 1 }
        return Int(value)
    }

    /// 1-minute load average from `vm.loadavg`. Returns 0 on failure.
    static func loadAverage1m() -> Double {
        // struct loadavg { fixpt_t ldavg[3]; long fscale; }
        // fixpt_t is uint32_t on macOS.
        var la = loadavg()
        var size = MemoryLayout<loadavg>.size
        let result = sysctlbyname("vm.loadavg", &la, &size, nil, 0)
        guard result == 0 else { return 0 }
        let scale = Double(la.fscale)
        guard scale > 0 else { return 0 }
        // ldavg is a tuple of 3 fixpt_t — access the first element.
        return Double(la.ldavg.0) / scale
    }

    /// Swap usage in MB (used, total). Returns zeros on failure.
    static func swapUsage() -> (usedMB: Double, totalMB: Double) {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        let result = sysctlbyname("vm.swapusage", &usage, &size, nil, 0)
        guard result == 0 else { return (0, 0) }
        let mb = 1024.0 * 1024.0
        return (Double(usage.xsu_used) / mb, Double(usage.xsu_total) / mb)
    }
}

// MARK: - Pressure derivation (pure)

enum PressureDeriver {
    /// Overall level = worst of memory / load / swap signals.
    static func derive(
        memoryPressure: PressureLevel,
        loadFactor: Double,
        swapUsageFraction: Double
    ) -> PressureLevel {
        if memoryPressure == .critical || loadFactor > 2.0 || swapUsageFraction > 0.90 {
            return .critical
        }
        if memoryPressure == .elevated || loadFactor > 1.0 || swapUsageFraction > 0.60 {
            return .elevated
        }
        return .normal
    }
}

// MARK: - Concrete monitor

/// Real system-pressure observer driven by `DispatchSourceMemoryPressure` plus
/// a 5-second fallback poll for load average and swap usage.
///
/// This class is `@MainActor`-isolated so it can expose `@Published` state for
/// SwiftUI consumers. The Dispatch-driven callbacks hop back to the main actor
/// before mutating state, satisfying Swift 6 strict concurrency.
@MainActor
final class SystemPressureMonitor: ObservableObject, SystemPressureSource {

    // MARK: Published state
    @Published private(set) var snapshot: SystemPressureSnapshot

    // MARK: Internals
    /// Accessible from any actor so `snapshotPublisher` / `currentSnapshot` can
    /// satisfy the `nonisolated` protocol requirements. `CurrentValueSubject`
    /// is internally thread-safe but not formally `Sendable` in Combine's
    /// public headers — we vouch for it with `nonisolated(unsafe)`.
    nonisolated(unsafe) private let subject: CurrentValueSubject<SystemPressureSnapshot, Never>
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var pollTimer: DispatchSourceTimer?
    private let pollQueue: DispatchQueue
    private var memoryPressureLevel: PressureLevel = .normal
    private var isStarted = false

    private static let pollInterval: TimeInterval = 5.0

    init() {
        let initial = SystemPressureSnapshot(
            level: .normal,
            memoryPressure: .normal,
            loadAverage1m: 0,
            ncpu: SysctlReader.ncpu(),
            swapUsedMB: 0,
            swapTotalMB: 0,
            timestamp: Date()
        )
        self.snapshot = initial
        self.subject = CurrentValueSubject(initial)
        self.pollQueue = DispatchQueue(label: "at.kanevry.DevWatchdog.SystemPressureMonitor", qos: .utility)
    }

    // MARK: - SystemPressureSource

    nonisolated var snapshotPublisher: AnyPublisher<SystemPressureSnapshot, Never> {
        subject.eraseToAnyPublisher()
    }

    nonisolated var currentSnapshot: SystemPressureSnapshot {
        subject.value
    }

    func start() async {
        guard !isStarted else { return }
        isStarted = true

        // Build fully non-isolated @Sendable handlers via nonisolated helpers.
        // Rationale: `setEventHandler`'s closure is `@Sendable` and runs on a
        // non-main queue. If the closure is formed inside this `@MainActor`
        // function and captures `[weak self]`, Swift 6.1+ inserts a runtime
        // executor check at closure entry (via `swift_task_isCurrentExecutor`),
        // which calls `dispatch_assert_queue` and crashes the process the
        // first time the handler fires on a background queue.
        //
        // Producing the closures from a `nonisolated static` factory side-steps
        // the inference: the closures never inherit MainActor context and all
        // MainActor hops happen explicitly inside `Task { @MainActor in ... }`.

        // 1. Memory pressure dispatch source.
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical],
            queue: .global(qos: .utility)
        )
        source.setEventHandler(handler: Self.makeMemoryPressureHandler(source: source, owner: self))
        source.resume()
        self.memoryPressureSource = source

        // 2. Fallback poll timer for load + swap.
        let timer = DispatchSource.makeTimerSource(queue: pollQueue)
        timer.schedule(deadline: .now(), repeating: Self.pollInterval, leeway: .milliseconds(250))
        timer.setEventHandler(handler: Self.makePollHandler(owner: self))
        timer.resume()
        self.pollTimer = timer
    }

    // MARK: - Handler factories (nonisolated)

    /// Build the memory-pressure event handler without capturing MainActor `self`
    /// directly. The `source` is captured so we can read `.data` without hopping;
    /// the MainActor hop happens explicitly via `Task { @MainActor in ... }`.
    private nonisolated static func makeMemoryPressureHandler(
        source: DispatchSourceMemoryPressure,
        owner: SystemPressureMonitor
    ) -> @Sendable () -> Void {
        // Capture a weak reference outside the @MainActor function body so the
        // returned closure is a plain nonisolated @Sendable — no inherited
        // isolation, no runtime executor check.
        return { [weak owner, source] in
            let data = source.data
            let level: PressureLevel
            if data.contains(.critical) {
                level = .critical
            } else if data.contains(.warning) {
                level = .elevated
            } else {
                level = .normal
            }
            Task { @MainActor [weak owner] in
                owner?.handleMemoryPressure(level)
            }
        }
    }

    /// Build the poll timer's event handler. The handler reads sysctl values
    /// (all `nonisolated`) and hops back to MainActor via a `Task`.
    private nonisolated static func makePollHandler(
        owner: SystemPressureMonitor
    ) -> @Sendable () -> Void {
        return { [weak owner] in
            let load = SysctlReader.loadAverage1m()
            let swap = SysctlReader.swapUsage()
            let ncpu = SysctlReader.ncpu()
            Task { @MainActor [weak owner] in
                owner?.handlePoll(loadAverage1m: load, swap: swap, ncpu: ncpu)
            }
        }
    }

    func stop() {
        memoryPressureSource?.cancel()
        memoryPressureSource = nil
        pollTimer?.cancel()
        pollTimer = nil
        isStarted = false
    }

    deinit {
        // Dispatch sources retain themselves while active — make sure they're
        // cancelled if the owner forgets to call stop().
        memoryPressureSource?.cancel()
        pollTimer?.cancel()
    }

    // MARK: - Event handlers (MainActor)

    private func handleMemoryPressure(_ level: PressureLevel) {
        memoryPressureLevel = level
        // Refresh with the latest poll data we already have.
        emit(
            memoryPressure: level,
            loadAverage1m: snapshot.loadAverage1m,
            swap: (snapshot.swapUsedMB, snapshot.swapTotalMB),
            ncpu: snapshot.ncpu
        )
    }

    private func handlePoll(
        loadAverage1m: Double,
        swap: (usedMB: Double, totalMB: Double),
        ncpu: Int
    ) {
        emit(
            memoryPressure: memoryPressureLevel,
            loadAverage1m: loadAverage1m,
            swap: swap,
            ncpu: ncpu
        )
    }

    private func emit(
        memoryPressure: PressureLevel,
        loadAverage1m: Double,
        swap: (usedMB: Double, totalMB: Double),
        ncpu: Int
    ) {
        let loadFactor = ncpu > 0 ? loadAverage1m / Double(ncpu) : 0
        let swapFraction = swap.totalMB > 0 ? swap.usedMB / swap.totalMB : 0
        let level = PressureDeriver.derive(
            memoryPressure: memoryPressure,
            loadFactor: loadFactor,
            swapUsageFraction: swapFraction
        )
        let next = SystemPressureSnapshot(
            level: level,
            memoryPressure: memoryPressure,
            loadAverage1m: loadAverage1m,
            ncpu: ncpu,
            swapUsedMB: swap.usedMB,
            swapTotalMB: swap.totalMB,
            timestamp: Date()
        )
        if next != snapshot {
            snapshot = next
            subject.send(next)
        }
    }
}
