import Foundation
@testable import DevWatchdog

/// Test double for ``ProcessTerminator`` that records every call and
/// returns configurable results. Thread-safe via an internal lock.
final class FakeProcessTerminator: ProcessTerminator, @unchecked Sendable {
    enum Call: Equatable {
        case terminate(Int32)
        case forceKill(Int32)
        case throttle(Int32)
        case resume(Int32)
        case alive(Int32)
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    var calls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return _calls
    }

    // Mutable knobs for tests. Stored behind the lock for Sendable-safety.
    private var _terminateResult: KillResult = .success
    private var _throttleResult: KillResult = .success
    private var _resumeResult: KillResult = .success
    private var _aliveResult: Bool = false

    var terminateResult: KillResult {
        get { lock.lock(); defer { lock.unlock() }; return _terminateResult }
        set { lock.lock(); _terminateResult = newValue; lock.unlock() }
    }

    var throttleResult: KillResult {
        get { lock.lock(); defer { lock.unlock() }; return _throttleResult }
        set { lock.lock(); _throttleResult = newValue; lock.unlock() }
    }

    var resumeResult: KillResult {
        get { lock.lock(); defer { lock.unlock() }; return _resumeResult }
        set { lock.lock(); _resumeResult = newValue; lock.unlock() }
    }

    var aliveResult: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _aliveResult }
        set { lock.lock(); _aliveResult = newValue; lock.unlock() }
    }

    func terminate(pid: Int32) -> KillResult {
        record(.terminate(pid))
        return terminateResult
    }

    func forceKill(pid: Int32) {
        record(.forceKill(pid))
    }

    func throttle(pid: Int32) -> KillResult {
        record(.throttle(pid))
        return throttleResult
    }

    func resume(pid: Int32) -> KillResult {
        record(.resume(pid))
        return resumeResult
    }

    func isProcessAlive(_ pid: Int32) -> Bool {
        record(.alive(pid))
        return aliveResult
    }

    private func record(_ call: Call) {
        lock.lock()
        _calls.append(call)
        lock.unlock()
    }
}
