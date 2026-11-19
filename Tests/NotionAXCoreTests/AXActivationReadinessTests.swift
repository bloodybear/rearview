import XCTest
@testable import NotionAXCore

final class AXActivationReadinessTests: XCTestCase {
    private func starts(durations: [Double], readyAt: Int? = nil) -> [Double] {
        var now = 0.0, starts: [Double] = []
        for (index, duration) in durations.enumerated() {
            let start = now
            starts.append(start)
            now += duration
            if index == readyAt { break }
            guard let delay = AXActivationReadiness.nextDelay(attemptStarted:start,elapsed:now) else { break }
            now += delay
        }
        return starts
    }
    func testImmediateSuccessDoesNotWait() {
        XCTAssertEqual(starts(durations:[0.01,0.01],readyAt:0),[0])
    }
    func testPersistentMissingDataGetsFinalAttemptAtTwoPointFiveSeconds() {
        XCTAssertEqual(starts(durations:[0.1,0.1,0.1,0.1,0.1]),[0,0.5,1.5,2.5])
    }
    func testSlowFirstCollectionStillGetsFinalRetryAndSkipsMissedSlots() {
        XCTAssertEqual(starts(durations:[3.2,0.1,0.1]),[0,3.2])
        XCTAssertEqual(starts(durations:[0.8,1.2,0.1,0.1]),[0,1.5,2.7])
    }
    func testLaterSuccessStopsBeforeFinalSlot() {
        XCTAssertEqual(starts(durations:[0.1,0.1,0.1],readyAt:1),[0,0.5])
    }
    func testAlreadyExpiredWindowDoesNotStartAnotherRetry() {
        XCTAssertNil(AXActivationReadiness.nextDelay(attemptStarted:4,elapsed:4.1))
    }
    func testOnlyMissingRenderableNativeTextRetries() {
        let missing: [String:Any] = ["text":"日本語", "lineRangeStatus":"marker_range_unavailable"]
        XCTAssertEqual(AXActivationReadiness.reasons(paragraphs:[missing],truncated:false),["marker_range_unavailable"])
        XCTAssertEqual(AXActivationReadiness.reasons(paragraphs:[missing],truncated:true),[])
        for status in ["complete_unverified","marker_string_mismatch","query_limit_reached","unsupported"] {
            XCTAssertEqual(AXActivationReadiness.reasons(paragraphs:[["text":"日本語","lineRangeStatus":status]],truncated:false),[])
        }
        XCTAssertEqual(AXActivationReadiness.reasons(paragraphs:[],truncated:false),[])
        XCTAssertEqual(AXActivationReadiness.reasons(paragraphs:[["text":"\n", "lineRangeStatus":"marker_range_unavailable"]],truncated:false),[])
    }
    func testMathOnlyAndNonrenderingSegmentsDoNotRetryButMissingTextDoes() {
        let math: [String:Any] = ["kind":"math"]
        let text: [String:Any] = ["kind":"text","text":"日本語","lineRangeStatus":"leaf_span_unavailable"]
        XCTAssertEqual(AXActivationReadiness.reasons(paragraphs:[["inlineContent":[math]]],truncated:false),[])
        XCTAssertEqual(AXActivationReadiness.reasons(paragraphs:[["inlineContent":[math,text]]],truncated:false),["leaf_span_unavailable"])
    }
    func testCancellationInterruptsReadinessWait() {
        let cancellation = AXCancellation()
        var now = 0.0
        XCTAssertThrowsError(try AXActivationReadiness.wait(1,cancellation:cancellation,now:{ now },sleep:{ step in
            now += step
            if now >= 0.05 { cancellation.cancel() }
        })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertLessThan(now,0.1)
    }
    func testCancelledWaitDoesNotSleep() {
        let cancellation = AXCancellation()
        cancellation.cancel()
        XCTAssertThrowsError(try AXActivationReadiness.wait(1,cancellation:cancellation,now:{0},sleep:{ _ in
            XCTFail("Cancelled collection must not wait")
        }))
    }

    func testAbsentRendererDiffersFromEmptyDocumentAndNativePanels() {
        XCTAssertTrue(AXActivationReadiness.documentTreeMissing(rows:[["role":"AXWindow"],["role":"AXGroup"]]))
        for role in ["AXWebArea","AXSheet","AXDialog","AXMenu"] {
            XCTAssertFalse(AXActivationReadiness.documentTreeMissing(rows:[["role":"AXWindow"],["role":role]]))
        }
    }

}
