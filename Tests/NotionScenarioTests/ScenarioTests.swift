import XCTest
@testable import NotionScenarioCore

final class ScenarioTests: XCTestCase {
    private func step(_ item: String, _ status: String) -> StepResult {
        StepResult(item: item, status: status, detail: "test", durationMs: 1)
    }
    func testRequiredUnsupportedNeverVerified() {
        XCTAssertEqual(RunResult.verdict(required: ["target", "zoom"], steps: [step("target", "verified"), step("zoom", "unsupported")]), "partial")
    }
    func testMissingRequiredNeverVerified() {
        XCTAssertEqual(RunResult.verdict(required: ["target", "scroll"], steps: [step("target", "verified")]), "partial")
    }
    func testFinalDriftNeverVerified() {
        XCTAssertEqual(RunResult.verdict(required: ["target"], steps: [step("target", "verified"), step("finalState", "failed")]), "partial")
    }
    func testWrongTargetFails() {
        XCTAssertEqual(RunResult.verdict(required: ["target"], steps: [step("target", "failed")]), "failed")
    }
    func testCompleteVerified() {
        XCTAssertEqual(RunResult.verdict(required: ["target", "screenshot"], steps: [step("target", "verified"), step("screenshot", "verified")]), "verified")
    }
    func testFrameToleranceAndNegativeCoordinates() throws {
        let a = Rect(CGRect(x: -1024, y: 70, width: 900, height: 700))
        XCTAssertTrue(a.near(Rect(CGRect(x: -1023, y: 70, width: 900, height: 700))))
        XCTAssertFalse(a.near(Rect(CGRect(x: -1000, y: 70, width: 900, height: 700))))
        XCTAssertEqual(try JSONDecoder().decode(Rect.self, from: JSONEncoder().encode(a)), a)
    }
}
