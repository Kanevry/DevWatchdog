import XCTest
@testable import DevWatchdog

@MainActor
final class PanicActionTests: XCTestCase {

    // MARK: - Helpers

    private func makeProcess(
        pid: Int32,
        cpu: Double = 10,
        rssMB: Double = 100
    ) -> DevProcess {
        DevProcess(
            id: pid,
            user: "tester",
            cpuPercent: cpu,
            memPercent: 1.0,
            rss: Int(rssMB * 1024),
            command: "node test-\(pid)",
            startTime: Date().addingTimeInterval(-600),
            parentPID: 1,
            isOrphan: true,
            state: .running
        )
    }

    private func makeSetup(
        softKillPreferred: Bool
    ) -> (PanicAction, ProcessMonitor, FakeProcessTerminator, WatchdogConfig) {
        let fakePressure = FakeSystemPressureSource()
        let terminator = FakeProcessTerminator()
        let monitor = ProcessMonitor(pressureSource: fakePressure, terminator: terminator)
        let config = WatchdogConfig()
        config.softKillPreferred = softKillPreferred
        let action = PanicAction(monitor: monitor, config: config)
        return (action, monitor, terminator, config)
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: "softKillPreferred")
    }

    // MARK: - Tests

    func testHardKillTerminatesAllZombiesAndSuspects() {
        let (action, monitor, terminator, _) = makeSetup(softKillPreferred: false)

        let z1 = makeProcess(pid: 101, rssMB: 200)
        let z2 = makeProcess(pid: 102, rssMB: 300)
        let s1 = makeProcess(pid: 201, rssMB: 150)
        monitor.zombieProcesses = [z1, z2]
        monitor.suspectProcesses = [s1]
        monitor.allProcesses = [z1, z2, s1]

        let result = action.execute()

        XCTAssertEqual(result.strategy, .hardKill)
        XCTAssertEqual(result.killedCount, 3)
        XCTAssertEqual(result.throttledCount, 0)
        XCTAssertEqual(result.freedMemoryMB, 650, accuracy: 0.5)

        // Every process should have received a `.terminate` call.
        let terminatePIDs = terminator.calls.compactMap { call -> Int32? in
            if case .terminate(let pid) = call { return pid }
            return nil
        }
        XCTAssertEqual(Set(terminatePIDs), Set([101, 102, 201]))

        // No throttle calls in hard-kill mode.
        let throttleCount = terminator.calls.filter {
            if case .throttle = $0 { return true } else { return false }
        }.count
        XCTAssertEqual(throttleCount, 0)
    }

    func testSoftKillThrottlesSuspectsAndKillsZombies() {
        let (action, monitor, terminator, _) = makeSetup(softKillPreferred: true)

        let z1 = makeProcess(pid: 501, rssMB: 400)
        let s1 = makeProcess(pid: 601, rssMB: 100)
        let s2 = makeProcess(pid: 602, rssMB: 200)
        monitor.zombieProcesses = [z1]
        monitor.suspectProcesses = [s1, s2]
        monitor.allProcesses = [z1, s1, s2]

        let result = action.execute()

        XCTAssertEqual(result.strategy, .softKill)
        XCTAssertEqual(result.killedCount, 1)
        XCTAssertEqual(result.throttledCount, 2)
        // Only the zombie contributes to freed memory (throttled processes
        // keep their RSS).
        XCTAssertEqual(result.freedMemoryMB, 400, accuracy: 0.5)

        let terminatePIDs = terminator.calls.compactMap { call -> Int32? in
            if case .terminate(let pid) = call { return pid }
            return nil
        }
        XCTAssertEqual(terminatePIDs, [501])

        let throttlePIDs = terminator.calls.compactMap { call -> Int32? in
            if case .throttle(let pid) = call { return pid }
            return nil
        }
        XCTAssertEqual(Set(throttlePIDs), Set([601, 602]))
    }

    func testEmptyQueuesReturnZeroResult() {
        let (action, _, terminator, _) = makeSetup(softKillPreferred: true)

        let result = action.execute()

        XCTAssertEqual(result.killedCount, 0)
        XCTAssertEqual(result.throttledCount, 0)
        XCTAssertEqual(result.freedMemoryMB, 0)
        XCTAssertEqual(result.strategy, .softKill)
        XCTAssertTrue(terminator.calls.isEmpty)
    }

    func testSummaryBodyHardKill() {
        let result = PanicResult(
            killedCount: 4,
            throttledCount: 0,
            freedMemoryMB: 1234,
            strategy: .hardKill
        )
        let body = PanicAction.summaryBody(for: result)
        XCTAssertTrue(body.contains("4"))
        XCTAssertTrue(body.contains("1234"))
    }

    func testSummaryBodySoftKill() {
        let result = PanicResult(
            killedCount: 1,
            throttledCount: 3,
            freedMemoryMB: 200,
            strategy: .softKill
        )
        let body = PanicAction.summaryBody(for: result)
        XCTAssertTrue(body.contains("3 pausiert"))
        XCTAssertTrue(body.contains("1 beendet"))
    }

    func testSummaryBodyEmptyHardKill() {
        let body = PanicAction.summaryBody(for: .empty)
        XCTAssertTrue(body.contains("Keine"))
    }
}
