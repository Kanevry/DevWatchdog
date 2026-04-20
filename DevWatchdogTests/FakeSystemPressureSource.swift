import Foundation
import Combine
@testable import DevWatchdog

/// Test double for ``SystemPressureSource``. Lets tests push snapshots
/// synchronously and observe what subscribers receive.
@MainActor
final class FakeSystemPressureSource: SystemPressureSource, ObservableObject {
    @Published var snapshot: SystemPressureSnapshot

    nonisolated(unsafe) private let subject: CurrentValueSubject<SystemPressureSnapshot, Never>

    private(set) var startCount = 0
    private(set) var stopCount = 0

    init(initial: SystemPressureSnapshot = .init(
        level: .normal,
        memoryPressure: .normal,
        loadAverage1m: 0,
        ncpu: 8,
        swapUsedMB: 0,
        swapTotalMB: 1024,
        timestamp: Date()
    )) {
        self.snapshot = initial
        self.subject = CurrentValueSubject(initial)
    }

    // MARK: - SystemPressureSource

    nonisolated var snapshotPublisher: AnyPublisher<SystemPressureSnapshot, Never> {
        subject.eraseToAnyPublisher()
    }

    nonisolated var currentSnapshot: SystemPressureSnapshot {
        subject.value
    }

    func start() async {
        startCount += 1
    }

    func stop() {
        stopCount += 1
    }

    // MARK: - Test affordances

    /// Push a new snapshot — updates both `@Published` state and the Combine subject.
    func emit(_ next: SystemPressureSnapshot) {
        snapshot = next
        subject.send(next)
    }
}
