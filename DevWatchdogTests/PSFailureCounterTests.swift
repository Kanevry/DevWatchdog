import XCTest
@testable import DevWatchdog

final class PSFailureCounterTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Reset the shared counter to a clean state before every test.
        // recordSuccess() zeroes the consecutive count and clears _failureSpike.
        PSFailureCounter.shared.recordSuccess()
    }

    // MARK: - Threshold boundary tests

    func testSingleFailureDoesNotTriggerSpike() {
        PSFailureCounter.shared.recordFailure()
        XCTAssertFalse(PSFailureCounter.shared.failureSpike,
            "A single failure must not trigger a spike (threshold is 3)")
    }

    func testTwoConsecutiveFailuresDoNotTriggerSpike() {
        PSFailureCounter.shared.recordFailure()
        PSFailureCounter.shared.recordFailure()
        XCTAssertFalse(PSFailureCounter.shared.failureSpike,
            "Two consecutive failures must not trigger a spike (threshold is 3)")
    }

    func testThreeConsecutiveFailuresTriggerSpike() {
        PSFailureCounter.shared.recordFailure()
        PSFailureCounter.shared.recordFailure()
        PSFailureCounter.shared.recordFailure()
        XCTAssertTrue(PSFailureCounter.shared.failureSpike,
            "Three consecutive failures must trigger the spike")
    }

    func testFourConsecutiveFailuresKeepSpike() {
        PSFailureCounter.shared.recordFailure()
        PSFailureCounter.shared.recordFailure()
        PSFailureCounter.shared.recordFailure()
        PSFailureCounter.shared.recordFailure()
        XCTAssertTrue(PSFailureCounter.shared.failureSpike,
            "Spike must remain true after four consecutive failures")
    }

    // MARK: - Success clears spike

    func testSuccessClearsSpike() {
        PSFailureCounter.shared.recordFailure()
        PSFailureCounter.shared.recordFailure()
        PSFailureCounter.shared.recordFailure()
        XCTAssertTrue(PSFailureCounter.shared.failureSpike,
            "Spike must be true after 3 failures (precondition)")

        PSFailureCounter.shared.recordSuccess()
        XCTAssertFalse(PSFailureCounter.shared.failureSpike,
            "Success must clear the failure spike")
    }

    func testSuccessResetsConsecutiveCountSoTwoMoreFailuresDoNotRetrigger() {
        // Pattern: fail × 2 → success → fail × 2 → still no spike (count was reset to 0).
        PSFailureCounter.shared.recordFailure()
        PSFailureCounter.shared.recordFailure()
        PSFailureCounter.shared.recordSuccess()  // resets consecutive count to 0
        PSFailureCounter.shared.recordFailure()
        PSFailureCounter.shared.recordFailure()
        XCTAssertFalse(PSFailureCounter.shared.failureSpike,
            "Two failures after a success must not trigger the spike (count was reset)")
    }

    func testSuccessInMiddleOfRunRequiresThreeMoreToTrigger() {
        // fail × 2 → success → fail × 3 → spike
        PSFailureCounter.shared.recordFailure()
        PSFailureCounter.shared.recordFailure()
        PSFailureCounter.shared.recordSuccess()
        PSFailureCounter.shared.recordFailure()
        PSFailureCounter.shared.recordFailure()
        PSFailureCounter.shared.recordFailure()
        XCTAssertTrue(PSFailureCounter.shared.failureSpike,
            "Three failures after a success reset must re-trigger the spike")
    }

    // MARK: - Spike persists until cleared

    func testSpikeRemainsUntilSuccess() {
        PSFailureCounter.shared.recordFailure()
        PSFailureCounter.shared.recordFailure()
        PSFailureCounter.shared.recordFailure()

        // Additional failures must not clear the spike.
        PSFailureCounter.shared.recordFailure()
        PSFailureCounter.shared.recordFailure()
        XCTAssertTrue(PSFailureCounter.shared.failureSpike,
            "Spike must remain set across additional failures until recordSuccess() is called")
    }

    // MARK: - Clean state after setUp

    func testInitialStateAfterSetUpHasNoSpike() {
        // setUp calls recordSuccess(), so the counter should be clean.
        XCTAssertFalse(PSFailureCounter.shared.failureSpike,
            "failureSpike must be false at the start of each test (after setUp reset)")
    }

    // MARK: - Thread safety smoke test

    func testConcurrentRecordFailureDoesNotCrash() async {
        // Not a correctness assertion on exact count — just verifying no crash/data race.
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    PSFailureCounter.shared.recordFailure()
                }
            }
        }
        // After at least 10 failures the spike must be set.
        XCTAssertTrue(PSFailureCounter.shared.failureSpike,
            "After 10 concurrent failures the spike must be triggered")
    }
}
