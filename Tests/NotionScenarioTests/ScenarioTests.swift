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
    func testNotionPageURLExtractsCanonicalPageID() {
        XCTAssertEqual(
            NotionPageURL.id(from: "https://www.notion.so/My-Page-12345678123412341234123456789ABC?pvs=4"),
            "12345678-1234-1234-1234-123456789abc"
        )
        XCTAssertEqual(
            NotionPageURL.id(from: "https://app.notion.com/12345678-1234-1234-1234-123456789abc"),
            "12345678-1234-1234-1234-123456789abc"
        )
        XCTAssertNil(NotionPageURL.id(from: "https://example.com/12345678123412341234123456789abc"))
        XCTAssertNil(NotionPageURL.id(from: "https://www.notion.so/not-a-page"))
    }
    func testFrameToleranceAndNegativeCoordinates() throws {
        let a = Rect(CGRect(x: -1024, y: 70, width: 900, height: 700))
        XCTAssertTrue(a.near(Rect(CGRect(x: -1023, y: 70, width: 900, height: 700))))
        XCTAssertFalse(a.near(Rect(CGRect(x: -1000, y: 70, width: 900, height: 700))))
        XCTAssertEqual(try JSONDecoder().decode(Rect.self, from: JSONEncoder().encode(a)), a)
    }
    func testRegionUsesIndependentPixelScalesAndWindowRelativeOrigin() {
        let window = CGRect(x: -1200, y: 60, width: 1000, height: 700)
        let region = CGRect(x: 100, y: 50, width: 200, height: 100)
        XCTAssertEqual(RegionGeometry.pixels(region: region, window: window, pixelWidth: 2000, pixelHeight: 1400),
                       CGRect(x: 200, y: 100, width: 400, height: 200))
        XCTAssertNil(RegionGeometry.pixels(region: CGRect(x: 900, y: 0, width: 200, height: 100), window: window, pixelWidth: 2000, pixelHeight: 1400))
        XCTAssertNil(RegionGeometry.pixels(region: .zero, window: window, pixelWidth: 2000, pixelHeight: 1400))
    }
    func testV2StateRoundTripsWithoutLosingPreviewOrScrollScope() throws {
        var state = RequestedState()
        state.presentation = PresentationRequest(mode: "side", fixtureId: "rich-document", widthFraction: 0.6)
        state.scrolls = [ViewportScrollRequest(scope: "preview", axis: "y", mode: "anchor", anchor: Anchor(text: "原文"), offset: 80)]
        state.captureRegion = RegionRequest(scope: "preview")
        let decoded = try JSONDecoder().decode(RequestedState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(decoded, state)
        XCTAssertEqual(decoded.scrolls?.first?.scope, "preview")
    }
    func testFailedPreviewOrCropCannotProduceVerifiedRun() {
        let steps = [step("target", "verified"), step("presentation", "failed"), step("screenshot", "verified")]
        XCTAssertEqual(RunResult.verdict(required: ["target", "presentation", "screenshot"], steps: steps), "partial")
        XCTAssertEqual(RunResult.verdict(required: ["target", "captureRegion"], steps: [step("target", "verified")]), "partial")
    }
    func testReplaySafetyBlocksOnlyPersistentPresentationOperations() {
        var scenario = Scenario(id: "x", name: "x", fixtureId: "db", fixtureVersion: "v", state: RequestedState())
        scenario.state.databaseView = "Timeline"
        XCTAssertNotNil(ReplaySafety.rejection(for: scenario, operation: "apply", databaseViewTypes: ["Timeline":"timeline"]))
        XCTAssertNil(ReplaySafety.rejection(for: scenario, operation: "apply", databaseViewTypes: ["Timeline":"table"]))
        XCTAssertNil(ReplaySafety.rejection(for: scenario, operation: "capture", databaseViewTypes: nil))
        scenario.state.databaseView = nil
        scenario.state.scrolls = [ViewportScrollRequest(scope: "database", axis: "x", mode: "end")]
        XCTAssertNotNil(ReplaySafety.rejection(for: scenario, operation: "apply", databaseViewTypes: nil))
        scenario.state.scrolls = nil
        scenario.state.blockDisplays = [BlockDisplayRequest(scope: "main", anchor: Anchor(text: "diagram"), mode: "source")]
        XCTAssertNotNil(ReplaySafety.rejection(for: scenario, operation: "apply", databaseViewTypes: nil))
        XCTAssertNil(ReplaySafety.rejection(for: scenario, operation: "apply", databaseViewTypes: nil, allowPersistentPresentation: true))
        scenario.state.blockDisplays = nil
        scenario.state.databaseView = "Timeline"
        XCTAssertNil(ReplaySafety.rejection(for: scenario, operation: "apply", databaseViewTypes: ["Timeline":"timeline"], allowPersistentPresentation: true))
    }

}
