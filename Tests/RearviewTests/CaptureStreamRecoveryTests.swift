import XCTest
import ScreenCaptureKit
@testable import Rearview

private final class RecoveryEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func add(_ value: String) { lock.withLock { storage.append(value) } }
    var values: [String] { lock.withLock { storage } }
}

private actor RecoveryGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

final class CaptureStreamRecoveryTests: XCTestCase, @unchecked Sendable {
    private enum Failure: Error { case interrupted }

    func testDisplayBurstCoalescesIntoOneRestart() async {
        let recovery = CaptureStreamRecovery(delay: .milliseconds(15))
        let restarted = expectation(description: "restarted")
        let events = RecoveryEvents()
        recovery.begin()
        for _ in 0..<10 {
            recovery.request(restart: {
                events.add("restart")
                restarted.fulfill()
            }, failed: { _ in XCTFail("Unexpected failure") })
        }
        await fulfillment(of: [restarted], timeout: 2)
        XCTAssertEqual(events.values, ["restart"])
        recovery.cancel()
    }

    func testTransientFailureRetriesAndRecoversWithoutNotice() async {
        let recovery = CaptureStreamRecovery(delay: .milliseconds(1))
        let restarted = expectation(description: "recovered")
        let events = RecoveryEvents()
        recovery.begin()
        recovery.request(restart: {
            events.add("attempt")
            if events.values.count < 3 { throw Failure.interrupted }
            restarted.fulfill()
        }, failed: { _ in XCTFail("Recovered failures must not toast") })
        await fulfillment(of: [restarted], timeout: 2)
        XCTAssertEqual(events.values.count, 3)
        recovery.cancel()
    }

    func testExhaustedRetriesReportOneFailure() async {
        let recovery = CaptureStreamRecovery(delay: .milliseconds(1))
        let failed = expectation(description: "failed")
        let events = RecoveryEvents()
        recovery.begin()
        recovery.request(restart: {
            events.add("attempt")
            throw Failure.interrupted
        }, failed: { _ in
            events.add("notice")
            failed.fulfill()
        })
        await fulfillment(of: [failed], timeout: 2)
        XCTAssertEqual(events.values, ["attempt", "attempt", "attempt", "notice"])
        recovery.cancel()
    }

    func testUserStopAndPermissionRefusalAreNotRetried() async {
        for code in [SCStreamError.Code.userDeclined, .userStopped, .missingEntitlements] {
            XCTAssertFalse(ScreenCaptureEngine.permitsRecovery(after:
                NSError(domain: SCStreamErrorDomain, code: code.rawValue)))
        }
        XCTAssertTrue(ScreenCaptureEngine.permitsRecovery(after:
            NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.systemStoppedStream.rawValue)))
        let recovery = CaptureStreamRecovery(delay: .milliseconds(1))
        let failed = expectation(description: "permission failure")
        let events = RecoveryEvents()
        recovery.begin()
        recovery.request(restart: {
            events.add("attempt")
            throw NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.userDeclined.rawValue)
        }, shouldRetry: ScreenCaptureEngine.permitsRecovery(after:), failed: { _ in failed.fulfill() })
        await fulfillment(of: [failed], timeout: 2)
        XCTAssertEqual(events.values.count, 1)
        recovery.cancel()
    }

    func testStoppedSessionCannotRestartFromLateNotification() async {
        let recovery = CaptureStreamRecovery(delay: .milliseconds(5))
        let unexpected = expectation(description: "no restart after stop")
        unexpected.isInverted = true
        recovery.begin()
        recovery.request(restart: { unexpected.fulfill() }, failed: { _ in unexpected.fulfill() })
        recovery.cancel()
        recovery.request(restart: { unexpected.fulfill() }, failed: { _ in unexpected.fulfill() })
        await fulfillment(of: [unexpected], timeout: 0.1)
    }

    func testStopWaitsForInFlightRestartAndPreventsResurrection() async throws {
        let queue = CaptureOperationQueue()
        let recovery = CaptureStreamRecovery(delay: .milliseconds(1))
        let gate = RecoveryGate()
        let entered = expectation(description: "restart entered")
        let events = RecoveryEvents()
        recovery.begin()
        recovery.request(restart: {
            try await queue.run {
                events.add("restart entered")
                entered.fulfill()
                await gate.wait() // Models a non-cancellable OS stopCapture call.
                try Task.checkCancellation()
                events.add("start capture")
            }
        }, failed: { _ in XCTFail("Cancelled recovery must not toast") })
        await fulfillment(of: [entered], timeout: 2)
        recovery.cancel()
        let stop = Task { try await queue.run { events.add("stop") } }
        await gate.release()
        try await stop.value
        XCTAssertEqual(events.values, ["restart entered", "stop"])
    }

    func testCleanupRunsEvenWhenCallingTaskWasCancelled() async throws {
        let queue = CaptureOperationQueue()
        let events = RecoveryEvents()
        let gate = RecoveryGate()
        let cleanup = Task {
            await gate.wait()
            try await queue.run(cancellable: false) { events.add("cleaned up") }
        }
        cleanup.cancel()
        await gate.release()
        try await cleanup.value
        XCTAssertEqual(events.values, ["cleaned up"])
    }

    func testRestartUsesLatestSerializedTargetAndRegion() async throws {
        let queue = CaptureOperationQueue()
        let recovery = CaptureStreamRecovery(delay: .milliseconds(15))
        let events = RecoveryEvents()
        let restarted = expectation(description: "restarted")
        recovery.begin()
        recovery.request(restart: {
            try await queue.run {
                events.add("restart with current settings")
                restarted.fulfill()
            }
        }, failed: { _ in XCTFail("Unexpected failure") })
        try await queue.run { events.add("update target and region") }
        await fulfillment(of: [restarted], timeout: 2)
        XCTAssertEqual(events.values, ["update target and region", "restart with current settings"])
        recovery.cancel()
    }
}
