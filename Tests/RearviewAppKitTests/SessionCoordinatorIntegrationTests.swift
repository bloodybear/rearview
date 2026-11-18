#if DEBUG
import AppKit
import XCTest
@testable import Rearview
@testable import NotionAXCore

private actor TestGate {
    private var hasStarted = false
    private var isReleased = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func wait() async {
        hasStarted = true
        startWaiter?.resume()
        startWaiter = nil
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            releaseWaiter = continuation
        }
    }

    func waitUntilStarted() async {
        guard !hasStarted else { return }
        await withCheckedContinuation { continuation in
            startWaiter = continuation
        }
    }

    func release() {
        isReleased = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private enum TestSessionError: Error {
    case captureStart
    case translation
}

private final class TestCaptureProvider: SessionCaptureProvider, @unchecked Sendable {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    let startError: Error?
    private var onFrame: (@Sendable (CGImage, UInt64, UInt64) -> Void)?

    init(startError: Error? = nil) {
        self.startError = startError
    }

    func start(
        displayID: CGDirectDisplayID, screenFrame: CGRect, backingScale: CGFloat,
        selection: CGRect, target: CaptureTarget, policy: CapturePolicy,
        onFrame: @escaping @Sendable (CGImage, UInt64, UInt64) -> Void
    ) async throws {
        startCount += 1
        if let startError { throw startError }
        self.onFrame = onFrame
    }

    func update(policy: CapturePolicy) async throws {}

    func updateRegion(
        selection: CGRect, screenFrame: CGRect, backingScale: CGFloat,
        displayID: CGDirectDisplayID?
    ) async throws {}

    func updateTarget(displayID: CGDirectDisplayID, target: CaptureTarget) async throws {}

    func stop() async {
        stopCount += 1
        onFrame = nil
    }

    func emit(_ image: CGImage, frameID: UInt64) {
        onFrame?(image, frameID, DispatchTime.now().uptimeNanoseconds)
    }
}

@MainActor
private final class TestTargetResolver: SessionTargetResolver {
    func applications(for selection: CGRect, on screen: NSScreen) async throws -> [CaptureApplication] {
        []
    }

    func resolveTarget(for selection: CGRect, on screen: NSScreen) async throws -> CaptureTargetResolution {
        CaptureTargetResolution(target: .allContent, candidate: nil)
    }
}

private final class TestOCRProvider: SessionOCRProvider, @unchecked Sendable {
    let batch: OCRService.RecognitionBatch
    let gate: TestGate?
    let gatedWidth: Int?

    init(batch: OCRService.RecognitionBatch, gate: TestGate? = nil, gatedWidth: Int? = nil) {
        self.batch = batch
        self.gatedWidth = gatedWidth
        self.gate = gate
    }

    func recognize(
        image: CGImage, mode: OCRMode, regionOfInterest: CGRect?,
        includeRejectedAlternatives: Bool, settings: OCRSettings?,
        direction: TranslationDirection
    ) async throws -> OCRService.RecognitionBatch {
        if let gate, gatedWidth == nil || gatedWidth == image.width { await gate.wait() }
        return batch
    }
}

private actor TestAXProvider: SessionAXProvider {
    var requestID:UUID?
    var calls = 0
    let gate: TestGate?
    let failure: AXExtractionError?
    let snapshot: AXExtractionSnapshot?
    let images: Bool
    let imageCount: Int
    init(gate: TestGate? = nil, failure: AXExtractionError? = nil, snapshot: AXExtractionSnapshot? = nil, images: Bool = false, imageCount: Int = 1) {
        self.gate = gate; self.failure = failure; self.snapshot = snapshot; self.images = images; self.imageCount = imageCount
    }
    func collect(_ request: AXExtractionRequest) async throws -> AXExtractionSnapshot {
        calls += 1
        requestID=request.diagnosticRequestID
        if let gate { await gate.wait() }
        if let failure { throw failure }
        // Intentionally ignores cancellation to test stale-result rejection.
        if images {
            let r=request.selectionRegion
            let regions: [[String:Any]] = (0..<imageCount).map { n in
                let box: [String:Double] = ["x":r.minX+10,"y":r.minY+10,"width":r.width/Double(n+2),"height":r.height/2]
                return ["node":99+n,"status":"selected","box":box,"displayBoxes":[box]]
            }
            var paragraphs = snapshot.map { (try! JSONSerialization.jsonObject(with:$0.paragraphs) as! [String:Any])["units"] as! [[String:Any]] } ?? []
            for index in paragraphs.indices {
                let box: [String:Double] = ["x":r.minX+10,"y":r.minY+10,"width":100,"height":20]
                paragraphs[index]["box"] = box
                if var lines = paragraphs[index]["lineRanges"] as? [[String:Any]] {
                    for line in lines.indices { lines[line]["box"] = box }
                    paragraphs[index]["lineRanges"] = lines
                }
            }
            return try AXExtractionSnapshot(nodes:[],selected:[],paragraphs:paragraphs,metadata:["status":"complete","selectionRegion":["x":r.minX,"y":r.minY,"width":r.width,"height":r.height],"imageRegions":regions])
        }
        if let snapshot { return snapshot }
        return try AXExtractionSnapshot(nodes:[],selected:[],paragraphs:[],metadata:["status":"partial","reason":"injected_limit"])
    }
    func diagnosticSnapshot() async -> AXCollectionDiagnostics? { .init(fields:["requestID":requestID?.uuidString ?? "unknown","stage":"injected-collection","accessibilityTrusted":"true"],queryResults:["AXChildren:-25204":1]) }
    func endSession() async {}
}

private actor RetentionAXProvider: SessionAXProvider {
    var phase=0
    func endSession() async {}
    func collect(_ request:AXExtractionRequest) async throws -> AXExtractionSnapshot {
        phase += 1
        let r=request.selectionRegion
        func rect(_ b:CGRect)->[String:Double] { ["x":b.minX,"y":b.minY,"width":b.width,"height":b.height] }
        let box=rect(CGRect(x:r.minX+10,y:r.minY+10,width:150,height:20))
        let body=phase == 1 || phase == 4
        let panels=(phase == 3 ? [CGRect(x:r.minX+20,y:r.minY,width:20,height:100),CGRect(x:r.minX+70,y:r.minY,width:20,height:100)] : [CGRect(x:r.minX+20,y:r.minY,width:20,height:100)])
        return try AXExtractionSnapshot(nodes:body ? [["id":1,"role":"AXStaticText","value":"日本語","title":"","frame":box]]:[],selected:[],paragraphs:body ? [["node":1,"text":"日本語","box":box,"lineSourceText":"日本語","lineRangeStatus":"complete_unverified","members":[1],"lineRanges":[["text":"日本語","rangeStart":0,"rangeLength":3,"box":box]],"isCodeBlock":false,"protectNonSourceText":false]]:[],metadata:["status":"complete","selectionRegion":rect(r),"documentSurfaces":[["node":0,"url":"https://example.test/page","frame":rect(request.windowFrame),"bodyNodes":body ? [1]:[],"dialogBoxes":body ? []:panels.map(rect)]]])
    }
}

@MainActor
private final class TestTranslationProvider: SessionTranslationProvider {
    var translations: [String: String]
    var gate: TestGate?
    var gatedSources: Set<String>?
    var failingSources: Set<String>
    private(set) var calls: [String] = []

    init(
        translations: [String: String], gate: TestGate? = nil,
        failingSources: Set<String> = []
    ) {
        self.translations = translations
        self.gate = gate
        self.failingSources = failingSources
    }

    func setDirection(_ direction: TranslationDirection) {}

    func setProtectsNonSourceText(_ enabled: Bool) {}

    func translate(_ source: String, options: TranslationRequestOptions) async throws -> String {
        try await translate(source)
    }

    func translate(_ source: String) async throws -> String {
        calls.append(source)
        if let gate, gatedSources == nil || gatedSources!.contains(source) { await gate.wait() }
        if failingSources.contains(source) { throw TestSessionError.translation }
        return translations[source] ?? source
    }
}

@MainActor
private final class TestOutputSink: SessionOutputSink {
    private(set) var frames: [MirrorFrame] = []
    private(set) var statuses: [MirrorProcessingStatus] = []
    private(set) var cancellationCount = 0
    var onDisplay: ((MirrorFrame) -> Void)?

    func display(_ frame: MirrorFrame) {
        frames.append(frame)
        onDisplay?(frame)
    }
    func showProcessingStatus(_ status: MirrorProcessingStatus, frameID: UInt64) {
        statuses.append(status)
    }
    func cancelProcessingStatus() { cancellationCount += 1 }
}

@MainActor
final class SessionCoordinatorIntegrationTests: XCTestCase {
    private var coordinatorsUnderTest: [SessionCoordinator] = []
    private var previousDirection: TranslationDirection = .japaneseToKorean

    override func setUp() async throws {
        try await super.setUp()
        previousDirection = TranslationDirection.load()
        TranslationDirection.japaneseToKorean.save()
    }

    override func tearDown() async throws {
        previousDirection.save()
        for coordinator in coordinatorsUnderTest.reversed() {
            await coordinator.stop()
        }
        coordinatorsUnderTest.removeAll()
        try await super.tearDown()
    }

    func testAXPublishesPartialSnapshotWithoutOCRorTranslation() async throws {
        let capture = TestCaptureProvider(), output = TestOutputSink(), ax = TestAXProvider()
        let ocrGate = TestGate()
        let translator = TestTranslationProvider(translations:[:])
        let coordinator = SessionCoordinator(broker:translator,capture:capture,targetResolver:TestTargetResolver(),
            ocr:TestOCRProvider(batch:makeBatch(lines:[]),gate:ocrGate),ax:ax,outputSink:output,createsOutputWindow:false,translatesAXParagraphs:false)
        coordinatorsUnderTest.append(coordinator)
        let (screen, selection) = try makeScreenAndSelection()
        await coordinator.setTextExtractionMode(.ax)
        try await coordinator.start(screen:screen,selection:selection,captureTarget:.application(
            CaptureApplication(processID:123,bundleIdentifier:"notion.id",name:"Notion",anchorWindowID:42,anchorWindowFrame:screen.frame)))
        coordinator.setRefreshMode(.automatic); coordinator.setPaused(false)
        coordinator.onFailure = { failure in XCTFail("Partial collection must not toast: \(failure)") }
        let done = expectation(description:"AX result")
        coordinator.onAXExtraction = { _, _, _ in done.fulfill() }
        capture.emit(makeImage(gray:40),frameID:1)
        await fulfillment(of:[done],timeout:2)
        let calls = await ax.calls
        XCTAssertEqual(calls,1)
        XCTAssertNotNil(coordinator.latestAXSnapshot)
        XCTAssertEqual(coordinator.latestAXFrame?.frameID,1)
        XCTAssertEqual(output.frames.last?.translatedItems.count,0)
        XCTAssertTrue(translator.calls.isEmpty)
        XCTAssertTrue(output.statuses.contains(.completed(failures:1)))
        let diagnostic=coordinator.diagnosticSnapshot()
        XCTAssertTrue(diagnostic.frames.contains { $0.summary["status"]=="partial" && $0.documents["ax-paragraphs.json"] != nil })
    }

    private func translatedAXFixture() throws -> AXExtractionSnapshot {
        try AXExtractionSnapshot(nodes:[],selected:[],paragraphs:[
            ["node":10,"text":"日本語 English 👩‍💻","box":["x":0,"y":0,"width":100,"height":20],
             "lineSourceText":"日本語 English 👩‍💻","lineRangeStatus":"complete_unverified","members":[11],"lineRanges":[],"isCodeBlock":false,"protectNonSourceText":false]],
            metadata:["status":"partial","reason":"injected_line_failure"])
    }

    func testAXTranslationRetainsPartialExtractionAndOriginalFrame() async throws {
        let capture = TestCaptureProvider(), output = TestOutputSink()
        let broker = TestTranslationProvider(translations:["日本語 English 👩‍💻":"번역 결과"])
        let coordinator = SessionCoordinator(broker:broker,capture:capture,targetResolver:TestTargetResolver(),
            ocr:TestOCRProvider(batch:makeBatch(lines:[]),gate:TestGate()),
            ax:TestAXProvider(snapshot:try translatedAXFixture()),outputSink:output,createsOutputWindow:false,
            initialTranslationDirection:.japaneseToKorean)
        coordinatorsUnderTest.append(coordinator)
        let (screen, selection) = try makeScreenAndSelection()
        await coordinator.setTextExtractionMode(.ax)
        try await coordinator.start(screen:screen,selection:selection,captureTarget:.application(
            CaptureApplication(processID:123,bundleIdentifier:"notion.id",name:"Notion",anchorWindowID:42,anchorWindowFrame:screen.frame)))
        coordinator.setRefreshMode(.automatic); coordinator.setPaused(false)
        let done = expectation(description:"AX translated")
        coordinator.onAXTranslation = { value in
            XCTAssertEqual(value.frame.frameID,1)
            XCTAssertEqual(value.frame.snapshot.status,.partial)
            XCTAssertEqual(value.entries.first?.translation,"번역 결과")
            XCTAssertEqual(value.entries.first?.node,10)
            done.fulfill()
        }
        capture.emit(makeImage(gray:40),frameID:1)
        await fulfillment(of:[done],timeout:2)
        XCTAssertEqual(output.frames.last?.translatedItems.count,0)
        XCTAssertEqual(coordinator.latestAXTranslation?.frame.frameID,1)
        XCTAssertNotNil(output.frames.last?.axArtwork)
        XCTAssertEqual(coordinator.latestAXRenderedFrame?.frameID,1)
        XCTAssertTrue(output.statuses.contains(.completed(failures:1)))
    }

    func testLateAXTranslationIsDiscardedAfterInvalidation() async throws {
        for invalidation in ["stop","mode","direction","pause","target","region"] {
            let gate = TestGate(), capture = TestCaptureProvider(), output = TestOutputSink()
            let coordinator = SessionCoordinator(broker:TestTranslationProvider(translations:[:],gate:gate),capture:capture,
                targetResolver:TestTargetResolver(),ocr:TestOCRProvider(batch:makeBatch(lines:[])),
                ax:TestAXProvider(snapshot:try translatedAXFixture()),outputSink:output,createsOutputWindow:false,
                initialTranslationDirection:.japaneseToKorean)
            coordinatorsUnderTest.append(coordinator)
            let (screen, selection) = try makeScreenAndSelection()
            await coordinator.setTextExtractionMode(.ax)
            try await coordinator.start(screen:screen,selection:selection,captureTarget:.application(
                CaptureApplication(processID:123,bundleIdentifier:"notion.id",name:"Notion",anchorWindowID:42,anchorWindowFrame:screen.frame)))
            coordinator.setRefreshMode(.automatic); coordinator.setPaused(false)
            var published = false
            coordinator.onAXTranslation = { value in
                if value.entries.first?.sourceLanguage == "ja" { published = true }
            }
            capture.emit(makeImage(gray:40),frameID:1)
            await gate.waitUntilStarted()
            switch invalidation {
            case "stop": await coordinator.stop()
            case "mode": await coordinator.setTextExtractionMode(.ocr)
            case "direction": coordinator.setTranslationDirection(.koreanToJapanese)
            case "pause": coordinator.setPaused(true)
            case "target": await coordinator.setApplicationCapture(nil)
            case "region": await coordinator.applySelection(selection.insetBy(dx:2,dy:2),screen:screen,reevaluateTarget:false)
            default: XCTFail("Unknown invalidation")
            }
            await gate.release()
            for _ in 0..<30 { await Task.yield() }
            XCTAssertFalse(published,invalidation)
            if invalidation == "direction" {
                XCTAssertNotEqual(coordinator.latestAXTranslation?.entries.first?.sourceLanguage,"ja")
            } else { XCTAssertNil(coordinator.latestAXTranslation,invalidation) }
        }
    }

    func testNewestPendingFrameRunsAfterAXTranslation() async throws {
        let gate = TestGate(), capture = TestCaptureProvider(), output = TestOutputSink()
        let coordinator = SessionCoordinator(broker:TestTranslationProvider(translations:[:],gate:gate),capture:capture,
            targetResolver:TestTargetResolver(),ocr:TestOCRProvider(batch:makeBatch(lines:[]),gate:TestGate()),
            ax:TestAXProvider(snapshot:try translatedAXFixture()),outputSink:output,createsOutputWindow:false,
            initialTranslationDirection:.japaneseToKorean)
        coordinatorsUnderTest.append(coordinator)
        let (screen, selection) = try makeScreenAndSelection()
        await coordinator.setTextExtractionMode(.ax)
        try await coordinator.start(screen:screen,selection:selection,captureTarget:.application(
            CaptureApplication(processID:123,bundleIdentifier:"notion.id",name:"Notion",anchorWindowID:42,anchorWindowFrame:screen.frame)))
        await coordinator.setCapturePolicy(CapturePolicy(targetFPS:30,realtimeOCRIntervalMilliseconds:100))
        coordinator.setRefreshMode(.automatic); coordinator.setPaused(false)
        let first = expectation(description:"first translated"), latest = expectation(description:"newest translated")
        coordinator.onAXTranslation = { value in
            if value.frame.frameID == 10 { first.fulfill() }
            if value.frame.frameID == 12 { latest.fulfill() }
        }
        let initial = makeImage(width:32,height:24,gray:40)
        let changed = makeImage(width:32,height:24,gray:40,changedPixel:(0,0,255))
        capture.emit(initial,frameID:10)
        await gate.waitUntilStarted()
        capture.emit(changed,frameID:11)
        await gate.release()
        await fulfillment(of:[first],timeout:2)
        try await Task.sleep(for:.milliseconds(120))
        capture.emit(changed,frameID:12)
        await fulfillment(of:[latest],timeout:2)
        XCTAssertEqual(coordinator.latestAXTranslation?.frame.frameID,12)
    }

    func testLateAXResultAfterModeChangeIsDiscarded() async throws {
        let gate = TestGate()
        let delayedAX = TestAXProvider(gate:gate)
        let capture = TestCaptureProvider(), output = TestOutputSink()
        let coordinator = SessionCoordinator(broker:TestTranslationProvider(translations:[:]),capture:capture,
            targetResolver:TestTargetResolver(),ocr:TestOCRProvider(batch:makeBatch(lines:[])),ax:delayedAX,outputSink:output,createsOutputWindow:false)
        coordinatorsUnderTest.append(coordinator)
        let (screen, selection) = try makeScreenAndSelection()
        await coordinator.setTextExtractionMode(.ax)
        try await coordinator.start(screen:screen,selection:selection,captureTarget:.application(
            CaptureApplication(processID:123,bundleIdentifier:"notion.id",name:"Notion",anchorWindowID:42,anchorWindowFrame:screen.frame)))
        coordinator.setRefreshMode(.automatic); coordinator.setPaused(false)
        capture.emit(makeImage(gray:40),frameID:1)
        await gate.waitUntilStarted()
        await coordinator.setTextExtractionMode(.ocr)
        await gate.release()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertNil(coordinator.latestAXSnapshot)
        XCTAssertTrue(output.frames.allSatisfy { $0.axArtwork == nil && $0.translatedItems.isEmpty })
    }

    func testNewestPendingFrameRunsAfterInFlightAXFinishes() async throws {
        let gate = TestGate(), ax = TestAXProvider(gate:gate)
        let capture = TestCaptureProvider(), output = TestOutputSink()
        let coordinator = SessionCoordinator(broker:TestTranslationProvider(translations:[:]),capture:capture,
            targetResolver:TestTargetResolver(),ocr:TestOCRProvider(batch:makeBatch(lines:[])),ax:ax,outputSink:output,createsOutputWindow:false)
        coordinatorsUnderTest.append(coordinator)
        let (screen, selection) = try makeScreenAndSelection()
        await coordinator.setTextExtractionMode(.ax)
        try await coordinator.start(screen:screen,selection:selection,captureTarget:.application(
            CaptureApplication(processID:123,bundleIdentifier:"notion.id",name:"Notion",anchorWindowID:42,anchorWindowFrame:screen.frame)))
        await coordinator.setCapturePolicy(CapturePolicy(targetFPS:30,realtimeOCRIntervalMilliseconds:100))
        coordinator.setRefreshMode(.automatic); coordinator.setPaused(false)
        let first = expectation(description:"first AX"), latest = expectation(description:"newest AX")
        coordinator.onAXExtraction = { _, _, id in
            if id == 10 { first.fulfill() }
        }
        coordinator.onAXTranslation = { value in
            if value.frame.frameID == 12 { latest.fulfill() }
        }
        let firstImage = makeImage(width:32,height:24,gray:40)
        let newestImage = makeImage(width:32,height:24,gray:40,changedPixel:(0,0,255))
        capture.emit(firstImage,frameID:10)
        await gate.waitUntilStarted()
        capture.emit(newestImage,frameID:11)
        await gate.release()
        await fulfillment(of:[first],timeout:2)
        try await Task.sleep(for:.milliseconds(120))
        capture.emit(newestImage,frameID:12)
        await fulfillment(of:[latest],timeout:2)
        XCTAssertEqual(output.frames.last?.frameID,12)
    }

    func testStoppedSessionDiscardsLateAX() async throws {
        let gate = TestGate(), ax = TestAXProvider(gate:gate)
        let capture = TestCaptureProvider(), output = TestOutputSink()
        let coordinator = SessionCoordinator(broker:TestTranslationProvider(translations:[:]),capture:capture,
            targetResolver:TestTargetResolver(),ocr:TestOCRProvider(batch:makeBatch(lines:[])),ax:ax,outputSink:output,createsOutputWindow:false)
        coordinatorsUnderTest.append(coordinator)
        let (screen, selection) = try makeScreenAndSelection()
        await coordinator.setTextExtractionMode(.ax)
        try await coordinator.start(screen:screen,selection:selection,captureTarget:.application(
            CaptureApplication(processID:123,bundleIdentifier:"notion.id",name:"Notion",anchorWindowID:42,anchorWindowFrame:screen.frame)))
        coordinator.setRefreshMode(.automatic); coordinator.setPaused(false)
        capture.emit(makeImage(gray:40),frameID:1)
        await gate.waitUntilStarted()
        await coordinator.stop()
        await gate.release()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertNil(coordinator.latestAXSnapshot)
        XCTAssertTrue(output.frames.allSatisfy { $0.axArtwork == nil && $0.translatedItems.isEmpty })
    }

    func testImageOCRDoesNotBlockAXProgressAndLateImageIsDiscarded() async throws {
        for invalidate in ["stop","mode","target","region"] {
            let gate=TestGate(),capture=TestCaptureProvider(),output=TestOutputSink()
            let coordinator=SessionCoordinator(broker:TestTranslationProvider(translations:[:]),capture:capture,
                targetResolver:TestTargetResolver(),ocr:TestOCRProvider(batch:makeBatch(lines:[makeLine(sourceText:"設定")]),gate:gate),
                ax:TestAXProvider(snapshot:try translatedAXFixture(),images:true),outputSink:output,createsOutputWindow:false)
            coordinatorsUnderTest.append(coordinator)
            let (screen,selection)=try makeScreenAndSelection()
            await coordinator.setTextExtractionMode(.ax)
            try await coordinator.start(screen:screen,selection:selection,mirrorUpdateStyle:.atomic,captureTarget:.application(
                CaptureApplication(processID:123,bundleIdentifier:"notion.id",name:"Notion",anchorWindowID:42,anchorWindowFrame:screen.frame)))
            coordinator.setRefreshMode(.automatic);coordinator.setPaused(false)
            let visible=expectation(description:"AX displayed while OCR waits")
            var displayed=false
            output.onDisplay = { frame in
                if !displayed,frame.axArtwork != nil,frame.imageOCRLayers.isEmpty {
                    displayed=true;visible.fulfill()
                }
            }
            let paragraph=expectation(description:"AX finished while OCR waits")
            coordinator.onAXTranslationProgress = { value in
                if !value.entries.isEmpty { paragraph.fulfill() }
            }
            capture.emit(makeImage(width:320,height:200,gray:40),frameID:41)
            await gate.waitUntilStarted()
            await fulfillment(of:[paragraph,visible],timeout:2)
            coordinator.onAXTranslationProgress=nil
            switch invalidate {
            case "stop": await coordinator.stop()
            case "mode": await coordinator.setTextExtractionMode(.ocr)
            case "target": await coordinator.setApplicationCapture(nil)
            default: await coordinator.applySelection(selection.insetBy(dx:2,dy:2),screen:screen,reevaluateTarget:false)
            }
            await gate.release()
            for _ in 0..<30 { await Task.yield() }
            XCTAssertFalse(output.frames.contains { !$0.imageOCRLayers.isEmpty },invalidate)
        }
    }

    func testPopupBodyReuseAcrossSessionFramesWithoutRetranslationOrSourceFlash() async throws {
        for style in [MirrorUpdateStyle.atomic,.progressive] {
            let capture=TestCaptureProvider(),output=TestOutputSink(),broker=TestTranslationProvider(translations:["日本語":"한국어"])
            let coordinator=SessionCoordinator(broker:broker,capture:capture,targetResolver:TestTargetResolver(),
                ocr:TestOCRProvider(batch:makeBatch(lines:[])),ax:RetentionAXProvider(),outputSink:output,createsOutputWindow:false)
            coordinatorsUnderTest.append(coordinator)
            let (screen,selection)=try makeScreenAndSelection()
            await coordinator.setTextExtractionMode(.ax)
            try await coordinator.start(screen:screen,selection:selection,mirrorUpdateStyle:style,captureTarget:.application(
                CaptureApplication(processID:123,bundleIdentifier:"notion.id",name:"Notion",anchorWindowID:42,anchorWindowFrame:screen.frame)))
            coordinator.setRefreshMode(.manual)
            for phase in 1...4 {
                let done=expectation(description:"retention phase \(phase)")
                coordinator.onAXTranslation = { value in
                    XCTAssertEqual(value.retainedBody != nil,phase == 2 || phase == 3)
                    done.fulfill()
                }
                capture.emit(makeImage(width:320,height:200,gray:40),frameID:UInt64(100+phase))
                for _ in 0..<5 { await Task.yield() }
                let before=output.frames.count
                coordinator.translateImmediately()
                await fulfillment(of:[done],timeout:3)
                XCTAssertFalse(coordinator.latestAXRenderedFrame?.axArtwork?.items.isEmpty ?? true)
                if phase == 2 || phase == 3 {
                    XCTAssertEqual(broker.calls.count,1)
                    XCTAssertTrue(output.frames.dropFirst(before).allSatisfy { $0.axArtwork != nil },"Reused body must not flash the source")
                }
            }
            XCTAssertEqual(broker.calls.count,2)
            await coordinator.stop()
        }
    }

    private func renderableAXFixture() throws -> AXExtractionSnapshot {
        let box: [String:Double] = ["x":0,"y":0,"width":100,"height":20]
        return try AXExtractionSnapshot(nodes:[],selected:[],paragraphs:[
            ["node":10,"text":"日本語","box":box,"lineSourceText":"日本語",
             "lineRangeStatus":"complete_unverified","members":[],
             "lineRanges":[["text":"日本語","rangeStart":0,"rangeLength":3,"box":box]],
             "isCodeBlock":false,"protectNonSourceText":false]],metadata:["status":"complete"])
    }
    func testEachImagePublishesBeforeSlowImageAndRetainsAX() async throws {
        for style in [MirrorUpdateStyle.atomic,.progressive] {
            let gate=TestGate(),capture=TestCaptureProvider(),output=TestOutputSink()
            let coordinator=SessionCoordinator(broker:TestTranslationProvider(translations:["設定":"설정"]),capture:capture,
                targetResolver:TestTargetResolver(),ocr:TestOCRProvider(batch:makeBatch(lines:[makeLine(sourceText:"設定")]),gate:gate,gatedWidth:160),
                ax:TestAXProvider(snapshot:try renderableAXFixture(),images:true,imageCount:2),outputSink:output,createsOutputWindow:false)
            coordinatorsUnderTest.append(coordinator)
            let (screen,selection)=try makeScreenAndSelection()
            await coordinator.setTextExtractionMode(.ax)
            try await coordinator.start(screen:screen,selection:selection,mirrorUpdateStyle:style,captureTarget:.application(
                CaptureApplication(processID:123,bundleIdentifier:"notion.id",name:"Notion",anchorWindowID:42,anchorWindowFrame:screen.frame)))
            coordinator.setRefreshMode(.automatic);coordinator.setPaused(false)
            let first=expectation(description:"fast image and AX visible"),last=expectation(description:"both images complete")
            var observed=false
            output.onDisplay = { frame in
                if !observed,frame.imageOCRLayers.count == 1,frame.axArtwork?.items.isEmpty == false {
                    observed=true; first.fulfill()
                }
            }
            coordinator.onAXTranslation = { value in
                XCTAssertEqual(value.imageOCR.layers.count,2);XCTAssertFalse(value.entries.isEmpty);last.fulfill()
            }
            capture.emit(makeImage(width:320,height:200,gray:40),frameID:61)
            await gate.waitUntilStarted()
            await fulfillment(of:[first],timeout:2)
            await gate.release()
            await fulfillment(of:[last],timeout:2)
            XCTAssertEqual(output.frames.last?.imageOCRLayers.count,2)
        }
    }
    func testAtomicRetainsAXBatchBoundaryWhileProgressivePublishesParagraph() async throws {
        for style in [MirrorUpdateStyle.atomic,.progressive] {
            let gate=TestGate(),capture=TestCaptureProvider(),output=TestOutputSink()
            let broker=TestTranslationProvider(translations:[:],gate:gate);broker.gatedSources=["変更"]
            let original=try renderableAXFixture()
            var rows=(try JSONSerialization.jsonObject(with:original.paragraphs) as! [String:Any])["units"] as! [[String:Any]]
            var second=rows[0];second["node"]=20;second["text"]="変更";second["lineSourceText"]="変更"
            let box=second["box"]!
            second["lineRanges"]=[["text":"変更","rangeStart":0,"rangeLength":2,"box":box]]
            rows.append(second)
            let snapshot=try AXExtractionSnapshot(nodes:[],selected:[],paragraphs:rows,metadata:["status":"complete"])
            let coordinator=SessionCoordinator(broker:broker,capture:capture,targetResolver:TestTargetResolver(),
                ocr:TestOCRProvider(batch:makeBatch(lines:[])),ax:TestAXProvider(snapshot:snapshot,images:true),
                outputSink:output,createsOutputWindow:false)
            coordinatorsUnderTest.append(coordinator)
            let (screen,selection)=try makeScreenAndSelection()
            await coordinator.setTextExtractionMode(.ax)
            try await coordinator.start(screen:screen,selection:selection,mirrorUpdateStyle:style,captureTarget:.application(
                CaptureApplication(processID:123,bundleIdentifier:"notion.id",name:"Notion",anchorWindowID:42,anchorWindowFrame:screen.frame)))
            coordinator.setRefreshMode(.automatic);coordinator.setPaused(false)
            let partial=expectation(description:"partial work completed"),finished=expectation(description:"all paragraphs finished")
            var observed=false,presented: [Int]=[]
            coordinator.onAXTranslationProgress = { value in
                if !observed,value.entries.count == 1,!value.imageOCR.layers.isEmpty { observed=true;partial.fulfill() }
            }
            coordinator.onAXPresentation = { presented.append($0.entries.count) }
            coordinator.onAXTranslation = { value in XCTAssertEqual(value.entries.count,2);finished.fulfill() }
            capture.emit(makeImage(width:320,height:200,gray:40),frameID:63)
            await gate.waitUntilStarted()
            await fulfillment(of:[partial],timeout:2)
            XCTAssertEqual(presented.contains(1),style == .progressive)
            if style == .atomic {
                XCTAssertTrue(output.frames.isEmpty, "Atomic AX must not flash the source while translation is pending")
            } else {
                XCTAssertTrue(output.frames.contains { $0.axArtwork == nil })
            }
            await gate.release()
            await fulfillment(of:[finished],timeout:2)
            XCTAssertEqual(presented.last,2)
            if style == .atomic {
                XCTAssertFalse(output.frames.isEmpty)
                XCTAssertTrue(output.frames.allSatisfy { $0.axArtwork != nil })
            }
        }
    }

    func testImageBeforeAXRemainsVisibleWhenAXCompletes() async throws {
        let gate=TestGate(),capture=TestCaptureProvider(),output=TestOutputSink()
        let coordinator=SessionCoordinator(broker:TestTranslationProvider(translations:[:],gate:gate),capture:capture,
            targetResolver:TestTargetResolver(),ocr:TestOCRProvider(batch:makeBatch(lines:[])),
            ax:TestAXProvider(snapshot:try renderableAXFixture(),images:true),outputSink:output,createsOutputWindow:false)
        coordinatorsUnderTest.append(coordinator)
        let (screen,selection)=try makeScreenAndSelection()
        await coordinator.setTextExtractionMode(.ax)
        try await coordinator.start(screen:screen,selection:selection,captureTarget:.application(
            CaptureApplication(processID:123,bundleIdentifier:"notion.id",name:"Notion",anchorWindowID:42,anchorWindowFrame:screen.frame)))
        coordinator.setRefreshMode(.automatic);coordinator.setPaused(false)
        let image=expectation(description:"image visible before AX"),finished=expectation(description:"AX finished")
        var seen=false
        output.onDisplay = { frame in
            if !seen,!frame.imageOCRLayers.isEmpty { seen=true;XCTAssertTrue(frame.axArtwork?.items.isEmpty == true);image.fulfill() }
        }
        coordinator.onAXTranslation = { _ in finished.fulfill() }
        capture.emit(makeImage(width:320,height:200,gray:40),frameID:62)
        await gate.waitUntilStarted()
        await fulfillment(of:[image],timeout:2)
        await gate.release()
        await fulfillment(of:[finished],timeout:2)
        XCTAssertEqual(output.frames.last?.imageOCRLayers.count,1)
        XCTAssertFalse(output.frames.last?.axArtwork?.items.isEmpty ?? true)
    }

    func testImageOCRPublishesAlongsideAXAndNewestPendingFrameRuns() async throws {
        let gate=TestGate(),capture=TestCaptureProvider(),output=TestOutputSink()
        let coordinator=SessionCoordinator(broker:TestTranslationProvider(translations:["設定":"설정"]),capture:capture,
            targetResolver:TestTargetResolver(),ocr:TestOCRProvider(batch:makeBatch(lines:[makeLine(sourceText:"設定")]),gate:gate),
            ax:TestAXProvider(images:true),outputSink:output,createsOutputWindow:false)
        coordinatorsUnderTest.append(coordinator)
        let (screen,selection)=try makeScreenAndSelection()
        await coordinator.setTextExtractionMode(.ax)
        try await coordinator.start(screen:screen,selection:selection,captureTarget:.application(
            CaptureApplication(processID:123,bundleIdentifier:"notion.id",name:"Notion",anchorWindowID:42,anchorWindowFrame:screen.frame)))
        await coordinator.setCapturePolicy(CapturePolicy(targetFPS:30,realtimeOCRIntervalMilliseconds:100))
        coordinator.setRefreshMode(.automatic);coordinator.setPaused(false)
        let first=expectation(description:"image result"),latest=expectation(description:"new image result")
        coordinator.onAXTranslation = { value in
            XCTAssertEqual(value.imageOCR.layers.first?.items.first?.translatedText,"설정")
            if value.frame.frameID == 50 { first.fulfill() }
            if value.frame.frameID == 52 { latest.fulfill() }
        }
        capture.emit(makeImage(width:32,height:24,gray:40),frameID:50)
        await gate.waitUntilStarted()
        capture.emit(makeImage(width:32,height:24,gray:40,changedPixel:(0,0,255)),frameID:51)
        await gate.release()
        await fulfillment(of:[first],timeout:2)
        try await Task.sleep(for:.milliseconds(120))
        capture.emit(makeImage(width:32,height:24,gray:40,changedPixel:(0,0,255)),frameID:52)
        await fulfillment(of:[latest],timeout:2)
        XCTAssertEqual(output.frames.last?.imageOCRLayers.count,1)
        XCTAssertNotNil(output.frames.last?.axArtwork)
    }

    func testAXRequestedForAllContentStillUsesOCR() async throws {
        let ax = TestAXProvider(), capture = TestCaptureProvider(), output = TestOutputSink()
        let coordinator = SessionCoordinator(broker:TestTranslationProvider(translations:[:]),capture:capture,
            targetResolver:TestTargetResolver(),ocr:TestOCRProvider(batch:makeBatch(lines:[])),ax:ax,outputSink:output,createsOutputWindow:false)
        coordinatorsUnderTest.append(coordinator)
        let (screen, selection) = try makeScreenAndSelection()
        await coordinator.setTextExtractionMode(.ax)
        try await coordinator.start(screen:screen,selection:selection,captureTarget:.allContent)
        coordinator.setRefreshMode(.automatic); coordinator.setPaused(false)
        let done = expectation(description:"OCR result")
        output.onDisplay = { _ in done.fulfill() }
        capture.emit(makeImage(gray:40),frameID:1)
        await fulfillment(of:[done],timeout:2)
        let calls = await ax.calls
        XCTAssertEqual(calls,0)
        XCTAssertNil(coordinator.latestAXSnapshot)
    }

    func testAXRequestedForOtherApplicationStillUsesOCR() async throws {
        let ax = TestAXProvider(), capture = TestCaptureProvider(), output = TestOutputSink()
        let coordinator = SessionCoordinator(broker:TestTranslationProvider(translations:[:]),capture:capture,
            targetResolver:TestTargetResolver(),ocr:TestOCRProvider(batch:makeBatch(lines:[])),ax:ax,outputSink:output,createsOutputWindow:false)
        coordinatorsUnderTest.append(coordinator)
        let (screen, selection) = try makeScreenAndSelection()
        await coordinator.setTextExtractionMode(.ax)
        try await coordinator.start(screen:screen,selection:selection,captureTarget:.application(CaptureApplication(processID:123,bundleIdentifier:"example.editor",name:"Editor")))
        coordinator.setRefreshMode(.automatic); coordinator.setPaused(false)
        let done = expectation(description:"OCR result")
        output.onDisplay = { _ in done.fulfill() }
        capture.emit(makeImage(gray:40),frameID:1)
        await fulfillment(of:[done],timeout:2)
        let calls = await ax.calls
        XCTAssertEqual(calls,0)
        XCTAssertNil(coordinator.latestAXSnapshot)
    }

    func testAXFailuresRemainFailuresWithoutOCRFallback() async throws {
        for error in [AXExtractionError.permissionDenied, .targetTerminated, .windowMappingFailed] {
            let capture = TestCaptureProvider(), output = TestOutputSink(), ax = TestAXProvider(failure:error)
            let translator = TestTranslationProvider(translations:[:])
            let coordinator = SessionCoordinator(broker:translator,capture:capture,targetResolver:TestTargetResolver(),
                ocr:TestOCRProvider(batch:makeBatch(lines:[]),gate:TestGate()),ax:ax,outputSink:output,createsOutputWindow:false)
            coordinatorsUnderTest.append(coordinator)
            let (screen, selection) = try makeScreenAndSelection()
            await coordinator.setTextExtractionMode(.ax)
            try await coordinator.start(screen:screen,selection:selection,captureTarget:.application(
                CaptureApplication(processID:123,bundleIdentifier:"notion.id",name:"Notion",anchorWindowID:42,anchorWindowFrame:screen.frame)))
            coordinator.setRefreshMode(.automatic); coordinator.setPaused(false)
            let failed = expectation(description:"AX failure \(error)")
            coordinator.onAXExtractionError = { actual in XCTAssertEqual(actual as? AXExtractionError,error); failed.fulfill() }
            capture.emit(makeImage(gray:40),frameID:1)
            await fulfillment(of:[failed],timeout:2)
            XCTAssertNil(coordinator.latestAXSnapshot)
            XCTAssertTrue(output.frames.isEmpty, "AX recognition failure must retain the displayed frame, like OCR")
            XCTAssertTrue(output.statuses.contains(.recognitionFailed))
            XCTAssertTrue(translator.calls.isEmpty)
            let diagnostic=coordinator.diagnosticSnapshot()
            XCTAssertNotNil(diagnostic.failed)
            XCTAssertTrue(diagnostic.frames.contains { $0.documents["ax-access.json"] != nil })
            XCTAssertTrue(diagnostic.frames.contains { $0.documents["error-ax.json"] != nil })
            XCTAssertEqual(diagnostic.state["lastFailureStage"],"ax")
            await coordinator.stop()
        }
    }

    func testPipelineTranslatesSourceLineAndPublishesAtomicFrame() async throws {
        let line = makeLine(sourceText: "設定")
        let ocr = TestOCRProvider(batch: makeBatch(lines: [line]))
        let translator = TestTranslationProvider(translations: ["設定": "설정"])
        let capture = TestCaptureProvider()
        let output = TestOutputSink()
        _ = try await makeCoordinator(
            capture: capture, ocr: ocr, translator: translator, output: output
        )

        let frameDisplayed = expectation(description: "frame 1 is displayed")
        output.onDisplay = { frame in
            if frame.frameID == 1 { frameDisplayed.fulfill() }
        }
        capture.emit(makeImage(gray: 40), frameID: 1)
        await fulfillment(of: [frameDisplayed], timeout: 2)

        XCTAssertEqual(output.frames.last?.frameID, 1)
        XCTAssertEqual(output.frames.last?.translatedItems.count, 1)
        XCTAssertEqual(output.frames.last?.translatedItems.first?.translatedText, "설정")
        XCTAssertTrue(output.frames.last?.translatedItems.first?.isTranslated == true)
        XCTAssertEqual(translator.calls, ["設定"])
        XCTAssertTrue(output.statuses.contains { status in
            if case .completed(failures: 0) = status { return true }
            return false
        })

    }

    func testDiagnosticsPreserveOCRFilteringAndTranslationWithoutExtraCalls() async throws {
        let japanese=makeLine(sourceText:"設定"),english=makeLine(sourceText:"English")
        let capture=TestCaptureProvider(),output=TestOutputSink(),translator=TestTranslationProvider(translations:["設定":"설정"])
        let coordinator=try await makeCoordinator(capture:capture,ocr:TestOCRProvider(batch:makeBatch(lines:[japanese,english])),translator:translator,output:output)
        let done=expectation(description:"display")
        output.onDisplay={ _ in done.fulfill() }
        capture.emit(makeImage(width:100,height:100,gray:40),frameID:88)
        await fulfillment(of:[done],timeout:2)
        let snapshot=coordinator.diagnosticSnapshot()
        let record=try XCTUnwrap(snapshot.frames.first { $0.frameID==88 })
        XCTAssertEqual(record.summary["mode"],"ocr")
        XCTAssertNotNil(record.summary["ocrMode"])
        let document=try XCTUnwrap(record.documents.first { $0.key.hasSuffix("-runtime.json") }?.value)
        let text=String(decoding:try document.encode(),as:UTF8.self)
        XCTAssertTrue(text.contains("設定"));XCTAssertTrue(text.contains("English"))
        XCTAssertEqual(translator.calls,["設定"])
        let before=translator.calls
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent("diagnostic-integration-\(UUID())")
        defer { try? FileManager.default.removeItem(at:folder) }
        _=try await Task.detached { try DiagnosticBundleWriter.writeFolder(snapshot,options:.init(),to:folder) }.value
        XCTAssertEqual(translator.calls,before)
        XCTAssertEqual(snapshot.displayed,record.id)
    }

    func testFailedStartStopsCaptureAndLeavesSessionInactive() async throws {
        let capture = TestCaptureProvider(startError: TestSessionError.captureStart)
        let ocr = TestOCRProvider(batch: makeBatch(lines: []))
        let translator = TestTranslationProvider(translations: [:])
        let output = TestOutputSink()
        let coordinator = SessionCoordinator(
            broker: translator, capture: capture, targetResolver: TestTargetResolver(),
            ocr: ocr, outputSink: output, createsOutputWindow: false
        )
        let (screen, selection) = try makeScreenAndSelection()

        do {
            try await coordinator.start(
                screen: screen, selection: selection, mirrorUpdateStyle: .atomic,
                captureTarget: .allContent
            )
            XCTFail("캡처 시작 실패가 전달되어야 합니다.")
        } catch {
            XCTAssertTrue(error is TestSessionError)
        }

        XCTAssertFalse(coordinator.isSessionActive)
        XCTAssertEqual(capture.startCount, 1)
        // start() stops the previous generation first, then cleanupFailedStart
        // stops the failed generation as well.
        XCTAssertEqual(capture.stopCount, 2)
        XCTAssertTrue(output.frames.isEmpty)
        let diagnostic=coordinator.diagnosticSnapshot()
        XCTAssertTrue(diagnostic.frames.isEmpty)
        XCTAssertEqual(diagnostic.state["lastFailureStage"],"capture")
        XCTAssertNotNil(diagnostic.contentEnvironment["error-capture"])
    }

    func testTranslationFailureKeepsSourceOnlyMirrorItem() async throws {
        let line = makeLine(sourceText: "設定")
        let ocr = TestOCRProvider(batch: makeBatch(lines: [line]))
        let translator = TestTranslationProvider(
            translations: [:], failingSources: ["設定"]
        )
        let capture = TestCaptureProvider()
        let output = TestOutputSink()
        _ = try await makeCoordinator(
            capture: capture, ocr: ocr, translator: translator, output: output
        )

        let frameDisplayed = expectation(description: "failed translation frame is displayed")
        output.onDisplay = { frame in
            if frame.frameID == 5 { frameDisplayed.fulfill() }
        }
        capture.emit(makeImage(gray: 160), frameID: 5)
        await fulfillment(of: [frameDisplayed], timeout: 2)

        XCTAssertEqual(output.frames.last?.translatedItems.first?.translatedText, "設定")
        XCTAssertFalse(output.frames.last?.translatedItems.first?.isTranslated == true)
        XCTAssertTrue(output.statuses.contains { status in
            if case .completed(failures: 1) = status { return true }
            return false
        })
    }

    func testManualModeDefersFrameUntilAutomaticResume() async throws {
        let ocr = TestOCRProvider(batch: makeBatch(lines: [makeLine(sourceText: "設定")]))
        let translator = TestTranslationProvider(translations: ["設定": "설정"])
        let capture = TestCaptureProvider()
        let output = TestOutputSink()
        let coordinator = try await makeCoordinator(
            capture: capture, ocr: ocr, translator: translator, output: output
        )

        coordinator.setRefreshMode(.manual)
        capture.emit(makeImage(gray: 200), frameID: 6)
        await Task.yield()
        XCTAssertTrue(output.frames.isEmpty)
        XCTAssertTrue(translator.calls.isEmpty)

        let frameDisplayed = expectation(description: "deferred frame is displayed")
        output.onDisplay = { frame in
            if frame.frameID == 6 { frameDisplayed.fulfill() }
        }
        coordinator.setRefreshMode(.automatic)
        await fulfillment(of: [frameDisplayed], timeout: 2)

        XCTAssertEqual(output.frames.last?.frameID, 6)
        XCTAssertEqual(translator.calls, ["設定"])
    }

    func testStoppedGenerationDiscardsLateOCRResult() async throws {
        let gate = TestGate()
        let ocr = TestOCRProvider(
            batch: makeBatch(lines: [makeLine(sourceText: "設定")]), gate: gate
        )
        let translator = TestTranslationProvider(translations: ["設定": "설정"])
        let capture = TestCaptureProvider()
        let output = TestOutputSink()
        let coordinator = try await makeCoordinator(
            capture: capture, ocr: ocr, translator: translator, output: output
        )

        capture.emit(makeImage(gray: 80), frameID: 2)
        await gate.waitUntilStarted()
        let stopCountBeforeSessionStop = capture.stopCount
        await coordinator.stop()
        await gate.release()

        XCTAssertFalse(coordinator.isSessionActive)
        XCTAssertEqual(capture.stopCount, stopCountBeforeSessionStop + 1)
        XCTAssertTrue(output.frames.isEmpty)
        XCTAssertTrue(translator.calls.isEmpty)
    }

    func testNewestPendingFrameRunsAfterInFlightOCRFinishes() async throws {
        let gate = TestGate()
        let ocr = TestOCRProvider(
            batch: makeBatch(lines: [makeLine(sourceText: "設定")]), gate: gate
        )
        let translator = TestTranslationProvider(translations: ["設定": "설정"])
        let capture = TestCaptureProvider()
        let output = TestOutputSink()
        let coordinator = try await makeCoordinator(
            capture: capture, ocr: ocr, translator: translator, output: output
        )
        await coordinator.setCapturePolicy(
            CapturePolicy(targetFPS: 30, realtimeOCRIntervalMilliseconds: 100)
        )

        let firstImage = makeImage(width: 32, height: 24, gray: 40)
        let newestImage = makeImage(
            width: 32, height: 24, gray: 40, changedPixel: (0, 0, 255)
        )
        let firstFrameDisplayed = expectation(description: "frame 10 is displayed")
        let newestFrameDisplayed = expectation(description: "frame 12 is displayed")
        var didFulfillFirstFrame = false
        var didFulfillNewestFrame = false
        output.onDisplay = { frame in
            if frame.frameID == 10, !didFulfillFirstFrame {
                didFulfillFirstFrame = true
                firstFrameDisplayed.fulfill()
            }
            if frame.frameID == 12, !didFulfillNewestFrame {
                didFulfillNewestFrame = true
                newestFrameDisplayed.fulfill()
            }
        }
        capture.emit(firstImage, frameID: 10)
        await gate.waitUntilStarted()
        capture.emit(newestImage, frameID: 11)
        await gate.release()

        await fulfillment(of: [firstFrameDisplayed], timeout: 2)

        try? await Task.sleep(for: .milliseconds(120))
        // An unchanged follow-up lets the coordinator re-check the pending
        // frame after the realtime interval has elapsed.
        capture.emit(newestImage, frameID: 12)
        await fulfillment(of: [newestFrameDisplayed], timeout: 2)
        XCTAssertEqual(output.frames.last?.frameID, 12)
        XCTAssertGreaterThanOrEqual(translator.calls.count, 2)

    }

    func testPausedContentRevisionDiscardsLateTranslationResult() async throws {
        let translationGate = TestGate()
        let ocr = TestOCRProvider(batch: makeBatch(lines: [makeLine(sourceText: "設定")]))
        let translator = TestTranslationProvider(
            translations: ["設定": "설정"], gate: translationGate
        )
        let capture = TestCaptureProvider()
        let output = TestOutputSink()
        let coordinator = try await makeCoordinator(
            capture: capture, ocr: ocr, translator: translator, output: output
        )

        capture.emit(makeImage(gray: 120), frameID: 3)
        await translationGate.waitUntilStarted()
        coordinator.setPaused(true)
        await translationGate.release()

        XCTAssertTrue(coordinator.isPaused)
        XCTAssertTrue(output.frames.isEmpty)
        XCTAssertEqual(output.cancellationCount, 1)
        XCTAssertEqual(translator.calls, ["設定"])

    }

    func testModeSwitchRefreshesOnceWhileManualOrPaused() async throws {
        for manual in [true, false] {
            let capture = TestCaptureProvider(), output = TestOutputSink(), ax = TestAXProvider()
            let coordinator = SessionCoordinator(broker: TestTranslationProvider(translations: [:]), capture: capture,
                targetResolver: TestTargetResolver(), ocr: TestOCRProvider(batch: makeBatch(lines: [])),
                ax: ax, outputSink: output, createsOutputWindow: false, translatesAXParagraphs: false)
            coordinatorsUnderTest.append(coordinator)
            let (screen, selection) = try makeScreenAndSelection()
            try await coordinator.start(screen: screen, selection: selection, captureTarget: .application(
                CaptureApplication(processID: 123, bundleIdentifier: "notion.id", name: "Notion", anchorWindowID: 42, anchorWindowFrame: screen.frame)))
            coordinator.setRefreshMode(manual ? .manual : .automatic)
            if !manual { coordinator.setPaused(true) }
            capture.emit(makeImage(gray: 40), frameID: 1)
            for _ in 0..<10 { await Task.yield() }
            let done = expectation(description: "one mode refresh")
            done.assertForOverFulfill = true
            coordinator.onAXExtraction = { _, _, _ in done.fulfill() }
            await coordinator.setTextExtractionMode(.ax)
            await fulfillment(of: [done], timeout: 2)
            XCTAssertEqual(coordinator.currentRefreshMode, manual ? .manual : .automatic)
            XCTAssertEqual(coordinator.isPaused, !manual)
            capture.emit(makeImage(gray: 80), frameID: 2)
            try await Task.sleep(for: .milliseconds(100))
            let calls = await ax.calls
            XCTAssertEqual(calls, 1)
            await coordinator.stop()
        }
    }

    func testAXPermissionFailureIsReportedWithoutOCRFallback() async throws {
        let capture = TestCaptureProvider(), ax = TestAXProvider(failure: .permissionDenied)
        let coordinator = SessionCoordinator(broker: TestTranslationProvider(translations: [:]), capture: capture,
            targetResolver: TestTargetResolver(), ocr: TestOCRProvider(batch: makeBatch(lines: [])), ax: ax,
            createsOutputWindow: false, initialTextExtractionMode: .ax)
        coordinatorsUnderTest.append(coordinator)
        let (screen, selection) = try makeScreenAndSelection()
        try await coordinator.start(screen: screen, selection: selection, captureTarget: .application(
            CaptureApplication(processID: 123, bundleIdentifier: "notion.id", name: "Notion", anchorWindowID: 42, anchorWindowFrame: screen.frame)))
        coordinator.setRefreshMode(.automatic); coordinator.setPaused(false)
        let done = expectation(description: "permission notice")
        coordinator.onFailure = { failure in
            XCTAssertEqual(failure.permission, .accessibility)
            done.fulfill()
        }
        capture.emit(makeImage(gray: 40), frameID: 1)
        await fulfillment(of: [done], timeout: 2)
        XCTAssertTrue(coordinator.usesAXExtraction)
    }

    func testModeSwitchBeforeFirstFrameRefreshesWhileManual() async throws {
        let capture = TestCaptureProvider(), output = TestOutputSink(), ax = TestAXProvider()
        let coordinator = SessionCoordinator(broker: TestTranslationProvider(translations: [:]), capture: capture,
            targetResolver: TestTargetResolver(), ocr: TestOCRProvider(batch: makeBatch(lines: [])), ax: ax,
            outputSink: output, createsOutputWindow: false, translatesAXParagraphs: false)
        coordinatorsUnderTest.append(coordinator)
        let (screen, selection) = try makeScreenAndSelection()
        try await coordinator.start(screen: screen, selection: selection, captureTarget: .application(
            CaptureApplication(processID: 123, bundleIdentifier: "notion.id", name: "Notion", anchorWindowID: 42, anchorWindowFrame: screen.frame)))
        coordinator.setRefreshMode(.manual)
        await coordinator.setTextExtractionMode(.ax)
        let done = expectation(description: "first frame refresh")
        coordinator.onAXExtraction = { _, _, _ in done.fulfill() }
        capture.emit(makeImage(gray: 40), frameID: 1)
        await fulfillment(of: [done], timeout: 2)
        XCTAssertEqual(coordinator.currentRefreshMode, .manual)
    }

    func testRapidModeSwitchUsesLatestSelection() async throws {
        let capture = TestCaptureProvider(), output = TestOutputSink(), ax = TestAXProvider()
        let coordinator = SessionCoordinator(broker: TestTranslationProvider(translations: [:]), capture: capture,
            targetResolver: TestTargetResolver(), ocr: TestOCRProvider(batch: makeBatch(lines: [])), ax: ax,
            outputSink: output, createsOutputWindow: false, translatesAXParagraphs: false)
        coordinatorsUnderTest.append(coordinator)
        let (screen, selection) = try makeScreenAndSelection()
        try await coordinator.start(screen: screen, selection: selection, captureTarget: .application(
            CaptureApplication(processID: 123, bundleIdentifier: "notion.id", name: "Notion", anchorWindowID: 42, anchorWindowFrame: screen.frame)))
        coordinator.setRefreshMode(.manual)
        capture.emit(makeImage(gray: 40), frameID: 1)
        for _ in 0..<10 { await Task.yield() }
        let done = expectation(description: "latest mode refresh")
        coordinator.onAXExtraction = { _, _, _ in done.fulfill() }
        let first = Task { await coordinator.setTextExtractionMode(.ax) }
        await Task.yield()
        let second = Task { await coordinator.setTextExtractionMode(.ocr) }
        await Task.yield()
        let third = Task { await coordinator.setTextExtractionMode(.ax) }
        await first.value; await second.value; await third.value
        await fulfillment(of: [done], timeout: 2)
        XCTAssertEqual(coordinator.textExtractionMode, .ax)
        XCTAssertTrue(coordinator.usesAXExtraction)
    }

    private func makeCoordinator(
        capture: TestCaptureProvider,
        ocr: TestOCRProvider,
        translator: TestTranslationProvider,
        output: TestOutputSink
    ) async throws -> SessionCoordinator {
        let (screen, selection) = try makeScreenAndSelection()
        let coordinator = SessionCoordinator(
            broker: translator, capture: capture, targetResolver: TestTargetResolver(),
            ocr: ocr, outputSink: output, createsOutputWindow: false
        )
        try await coordinator.start(
            screen: screen, selection: selection, mirrorUpdateStyle: .atomic,
            captureTarget: .allContent
        )
        coordinatorsUnderTest.append(coordinator)
        coordinator.setRefreshMode(.automatic)
        coordinator.setPaused(false)
        return coordinator
    }

    private func makeScreenAndSelection() throws -> (NSScreen, CGRect) {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        application.finishLaunching()
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            throw XCTSkip("AppKit 화면이 없는 환경에서는 SessionCoordinator 통합 테스트를 실행할 수 없습니다.")
        }
        guard screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] is NSNumber else {
            throw XCTSkip("디스플레이 식별자가 없는 AppKit 화면입니다.")
        }

        let selection = CGRect(
            x: screen.visibleFrame.minX + 20, y: screen.visibleFrame.minY + 20,
            width: min(320, screen.visibleFrame.width - 40),
            height: min(200, screen.visibleFrame.height - 40)
        )
        return (screen, selection)
    }

    private func makeBatch(lines: [RecognizedLine]) -> OCRService.RecognitionBatch {
        OCRService.RecognitionBatch(
            lines: lines, debugItems: [], rawObservationCount: lines.count,
            missingCandidateCount: 0, confidenceRejected: []
        )
    }

    private func makeLine(sourceText: String) -> RecognizedLine {
        RecognizedLine(
            sourceText: sourceText, normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.2),
            confidence: 0.95, background: .lightBackground, foreground: .darkText
        )
    }

    private func makeImage(
        width: Int = 1, height: Int = 1, gray: UInt8, changedPixel: (Int, Int, UInt8)? = nil
    ) -> CGImage {
        var pixels = [UInt8](repeating: gray, count: width * height)
        if let changedPixel,
           changedPixel.0 >= 0, changedPixel.0 < width,
           changedPixel.1 >= 0, changedPixel.1 < height {
            pixels[changedPixel.1 * width + changedPixel.0] = changedPixel.2
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
    }
}
#endif
