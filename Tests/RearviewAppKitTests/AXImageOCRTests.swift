#if DEBUG
import AppKit
import XCTest
@preconcurrency import Translation
@testable import Rearview
@testable import NotionAXCore

private actor ImageTestOCR: SessionOCRProvider {
    var calls = 0
    let fails: Bool
    init(fails: Bool = false) { self.fails=fails }
    func recognize(image:CGImage,mode:OCRMode,regionOfInterest:CGRect?,includeRejectedAlternatives:Bool,
                   settings:OCRSettings?,direction:TranslationDirection) async throws -> OCRService.RecognitionBatch {
        calls += 1
        if fails { throw CocoaError(.fileReadUnknown) }
        return .init(lines:[.init(sourceText:"設定",normalizedRect:CGRect(x:0.1,y:0.2,width:0.8,height:0.3),confidence:1,background:.lightBackground,foreground:.darkText),
                           .init(sourceText:"English",normalizedRect:CGRect(x:0.1,y:0.6,width:0.8,height:0.2),confidence:1,background:.lightBackground,foreground:.darkText)],
                     debugItems:[],rawObservationCount:2,missingCandidateCount:0,confidenceRejected:[])
    }
}
private actor ControlledImageOCR: SessionOCRProvider {
    var started: [Int] = []
    var active = 0
    var maximum = 0
    var waiting: [Int:CheckedContinuation<Void,Never>] = [:]
    let failingWidths: Set<Int>
    init(failingWidths:Set<Int> = []) { self.failingWidths = failingWidths }
    func release(_ width:Int) { waiting.removeValue(forKey:width)?.resume() }
    func recognize(image:CGImage,mode:OCRMode,regionOfInterest:CGRect?,includeRejectedAlternatives:Bool,
                   settings:OCRSettings?,direction:TranslationDirection) async throws -> OCRService.RecognitionBatch {
        started.append(image.width); active += 1; maximum = max(maximum,active)
        await withCheckedContinuation { waiting[image.width] = $0 }
        active -= 1
        try Task.checkCancellation()
        if failingWidths.contains(image.width) { throw CocoaError(.fileReadUnknown) }
        return .init(lines:[],debugItems:[],rawObservationCount:0,missingCandidateCount:0,confidenceRejected:[])
    }
    func waitForStarts(_ count:Int) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while started.count < count {
            if ContinuousClock.now > deadline { throw CocoaError(.coderInvalidValue) }
            try await Task.sleep(for:.milliseconds(1))
        }
    }
}
private struct ImageOCRBenchmarkSample: Codable {
    struct Call: Codable, Sendable {
        let width, height, lines: Int
        let start, end: Double
    }
    let translation: String
    let concurrency: Int
    let warmup: Bool
    let renders: Bool
    let firstReady, firstDisplay, allReady, allDisplay: Double
    let maxConcurrentOCR: Int
    let calls: [Call]
    let diagnostics: [AXImageOCRDiagnostic]
}
private actor TimedImageBenchmarkOCR: SessionOCRProvider {
    let service = OCRService()
    let start: ContinuousClock.Instant
    var calls: [ImageOCRBenchmarkSample.Call] = []
    var active = 0
    var maximum = 0
    init(start:ContinuousClock.Instant) { self.start = start }
    func seconds() -> Double {
        let d=(ContinuousClock.now-start).components
        return Double(d.seconds)+Double(d.attoseconds)/1e18
    }
    func recognize(image:CGImage,mode:OCRMode,regionOfInterest:CGRect?,includeRejectedAlternatives:Bool,
                   settings:OCRSettings?,direction:TranslationDirection) async throws -> OCRService.RecognitionBatch {
        let begun=seconds()
        active += 1; maximum=max(maximum,active)
        defer { active -= 1 }
        let value=try await service.recognize(image:image,mode:mode,regionOfInterest:regionOfInterest,
            includeRejectedAlternatives:includeRejectedAlternatives,settings:settings,direction:direction)
        calls.append(.init(width:image.width,height:image.height,lines:value.lines.count,start:begun,end:seconds()))
        return value
    }
}
@MainActor private final class ImageTestBroker: SessionTranslationProvider {
    var calls: [String] = []
    var fails = false
    func setDirection(_ direction:TranslationDirection) {}
    func setProtectsNonSourceText(_ enabled:Bool) {}
    func translate(_ source:String,options:TranslationRequestOptions) async throws -> String { try await translate(source) }
    func translate(_ source:String) async throws -> String {
        calls.append(source)
        if fails { throw CocoaError(.fileReadUnknown) }
        return "설정"
    }
}
@MainActor final class AXImageOCRTests: XCTestCase {
    private let selection = CGRect(x:100,y:200,width:100,height:80)
    private func image(_ gray:CGFloat = 1) -> CGImage {
        let c=CGContext(data:nil,width:200,height:160,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(gray:gray,alpha:1);c.fill(CGRect(x:0,y:0,width:200,height:160));return c.makeImage()!
    }
    private func snapshot(count:Int = 1) throws -> AXExtractionSnapshot {
        let box: [String:Double] = ["x":110,"y":210,"width":60,"height":40]
        return try AXExtractionSnapshot(nodes:[],selected:[],paragraphs:[],metadata:["status":"complete","imageRegions":(0..<count).map {
            ["node":$0,"status":"selected","box":box,"displayBoxes":[box]] as [String:Any]
        }])
    }
    func testOnlyJapaneseTranslatedAndIdenticalPixelsReuseRecognition() async throws {
        let processor=AXImageOCRProcessor(),ocr=ImageTestOCR(),broker=ImageTestBroker(),settings=OCRSettings.defaultProfile(for:.realtime)
        let first=try await processor.process(snapshot:snapshot(count:2),image:image(),selection:selection,ocr:ocr,broker:broker,settings:settings,direction:.japaneseToKorean)
        XCTAssertEqual(first.layers.count,2)
        XCTAssertEqual(Set(first.layers.flatMap { $0.items.map(\.id) }).count,4,"cached OCR IDs must not alias between images")
        let second=try await processor.process(snapshot:snapshot(),image:image(),selection:selection,ocr:ocr,broker:broker,settings:settings,direction:.japaneseToKorean)
        let calls=await ocr.calls; XCTAssertEqual(calls,1)
        XCTAssertTrue(second.diagnostics[0].cacheHit)
        XCTAssertTrue(broker.calls.allSatisfy { $0 == "設定" })
        XCTAssertFalse(second.layers[0].items[1].isTranslated)
        _ = try await processor.process(snapshot:snapshot(),image:image(0),selection:selection,ocr:ocr,broker:broker,settings:settings,direction:.japaneseToKorean)
        processor.reset()
        _ = try await processor.process(snapshot:snapshot(),image:image(0),selection:selection,ocr:ocr,broker:broker,settings:settings,direction:.japaneseToKorean)
        let updated=await ocr.calls;XCTAssertEqual(updated,3)
        let changed=OCRSettings(imageScale:settings.imageScale == 3 ? 1 : 3)
        _ = try await processor.process(snapshot:snapshot(),image:image(0),selection:selection,ocr:ocr,broker:broker,settings:changed,direction:.japaneseToKorean)
        _ = try await processor.process(snapshot:snapshot(),image:image(0),selection:selection,ocr:ocr,broker:broker,settings:changed,direction:.koreanToJapanese)
        let invalidated=await ocr.calls;XCTAssertEqual(invalidated,5)
    }
    func testRetinaCropAndSelectionCoordinatesAndSavedReportRoundTrip() async throws {
        let source=image()
        let result=try await AXImageOCRProcessor().process(snapshot:snapshot(),image:source,selection:selection,ocr:ImageTestOCR(),broker:ImageTestBroker(),settings:.defaultProfile(for:.realtime),direction:.japaneseToKorean)
        let layer=try XCTUnwrap(result.layers.first)
        XCTAssertEqual(layer.image.width,120);XCTAssertEqual(layer.image.height,80)
        XCTAssertEqual(layer.pixelBox,CGRect(x:20,y:60,width:120,height:80))
        let mapped=layer.mappedItems(frameSize:CGSize(width:200,height:160))
        XCTAssertEqual(mapped[0].normalizedRect.minX,0.16,accuracy:0.0001)
        XCTAssertEqual(mapped[0].normalizedRect.minY,0.475,accuracy:0.0001)
        let record=try JSONDecoder().decode(AXImageOCRSavedLayer.self,from:JSONEncoder().encode(AXImageOCRSavedLayer(layer)))
        XCTAssertEqual(record.restore(source:source)?.items.map(\.translatedText),["설정","English"])
        let view=NativeTranslationMirrorView(frame:CGRect(x:0,y:0,width:200,height:160))
        view.setRenderingActive(true)
        let captured=SessionCoordinator.AXTranslatedFrame(frame:.init(snapshot:try snapshot(),image:source,frameID:1,receivedAt:0),entries:[])
        let art=await AXLineRendering.render(captured)
        var frame=MirrorFrame(image:source,translatedItems:mapped,frameID:1);frame.axArtwork=art;frame.imageOCRLayers=[layer]
        view.frameSnapshot=frame
        let composite=try XCTUnwrap(view.compositedImage())
        let bitmap=try XCTUnwrap(composite.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x:5,y:5)).redComponent,1,accuracy:0.01)
        let fragments=view.renderedFragmentsForTesting(mapped[0].id)
        XCTAssertFalse(fragments.isEmpty)
        XCTAssertTrue(fragments.allSatisfy { layer.pixelBox.contains($0.rect) })
        let copied=try XCTUnwrap(view.selectAllTextForTesting())
        XCTAssertTrue(copied.contains("설정"));XCTAssertTrue(copied.contains("English"))
        var matches=0
        view.onSearchCountChange = { count,_ in matches=count }
        view.setSearch(query:"설정",caseSensitive:false,regex:false)
        XCTAssertEqual(matches,1)
        view.setSearch(query:"English",caseSensitive:false,regex:false)
        XCTAssertEqual(matches,1)
    }
    func testImageFailureDoesNotThrowAndTranslationFailurePreservesSelection() async throws {
        let failed=try await AXImageOCRProcessor().process(snapshot:snapshot(),image:image(),selection:selection,ocr:ImageTestOCR(fails:true),broker:ImageTestBroker(),settings:.defaultProfile(for:.realtime),direction:.japaneseToKorean)
        XCTAssertEqual(failed.failures,1);XCTAssertTrue(failed.layers.isEmpty)
        let broker=ImageTestBroker();broker.fails=true
        let result=try await AXImageOCRProcessor().process(snapshot:snapshot(),image:image(),selection:selection,ocr:ImageTestOCR(),broker:broker,settings:.defaultProfile(for:.realtime),direction:.japaneseToKorean)
        XCTAssertEqual(result.failures,1)
        XCTAssertTrue(result.layers[0].items.allSatisfy { !$0.isTranslated })
        XCTAssertEqual(result.layers[0].items[0].translatedText,"設定")
    }
    private func distinctSnapshot() throws -> AXExtractionSnapshot {
        let regions: [[String:Any]] = (1...3).map { n in
            let box: [String:Double] = ["x":110,"y":210,"width":Double(n*10),"height":20]
            return ["node":n,"status":"selected","box":box,"displayBoxes":[box]]
        }
        return try AXExtractionSnapshot(nodes:[],selected:[],paragraphs:[],metadata:["status":"complete","imageRegions":regions])
    }
    func testBoundedParallelCompletionOrderAndFinalSourceOrder() async throws {
        let ocr=ControlledImageOCR(), processor=AXImageOCRProcessor(), broker=ImageTestBroker()
        var completed: [Int] = []
        let task = Task { try await processor.process(snapshot:distinctSnapshot(),image:image(),selection:selection,
            ocr:ocr,broker:broker,settings:.defaultProfile(for:.realtime),direction:.japaneseToKorean,
            onCompletion: { completed.append($0.index) }) }
        try await ocr.waitForStarts(2)
        let initial=await ocr.started; XCTAssertEqual(Set(initial),[20,40])
        await ocr.release(40)
        try await ocr.waitForStarts(3)
        XCTAssertEqual(completed,[1])
        await ocr.release(60)
        while completed.count < 2 { await Task.yield() }
        await ocr.release(20)
        let result=try await task.value
        let maximum=await ocr.maximum; XCTAssertEqual(maximum,2)
        XCTAssertEqual(completed,[1,2,0])
        XCTAssertEqual(result.diagnostics.map(\.node),[1,2,3])
        XCTAssertEqual(result.layers.map { $0.pixelBox.width },[20,40,60])
    }
    func testSimultaneousIdenticalPixelsShareInFlightOCR() async throws {
        let ocr=ControlledImageOCR(),processor=AXImageOCRProcessor(),broker=ImageTestBroker()
        let task=Task { try await processor.process(snapshot:snapshot(count:2),image:image(),selection:selection,
            ocr:ocr,broker:broker,settings:.defaultProfile(for:.realtime),direction:.japaneseToKorean) }
        try await ocr.waitForStarts(1)
        for _ in 0..<100 { await Task.yield() }
        let calls=await ocr.started.count; XCTAssertEqual(calls,1)
        await ocr.release(120)
        let result=try await task.value
        XCTAssertEqual(result.layers.count,2)
        XCTAssertEqual(result.diagnostics.filter(\.cacheHit).count,1)
    }
    func testCancelledFrameDoesNotAdmitQueuedWorkOrPopulateCache() async throws {
        let ocr=ControlledImageOCR(),processor=AXImageOCRProcessor(),broker=ImageTestBroker()
        var completions=0
        let task=Task { try await processor.process(snapshot:distinctSnapshot(),image:image(),selection:selection,
            ocr:ocr,broker:broker,settings:.defaultProfile(for:.realtime),direction:.japaneseToKorean,
            onCompletion: { _ in completions += 1 }) }
        try await ocr.waitForStarts(2)
        task.cancel();processor.reset()
        await ocr.release(20);await ocr.release(40)
        do { _ = try await task.value; XCTFail("expected cancellation") } catch is CancellationError {}
        let starts=await ocr.started.count;XCTAssertEqual(starts,2);XCTAssertEqual(completions,0)
    }
    func testOneFailedImageDoesNotCancelOtherOrQueuedImage() async throws {
        let ocr=ControlledImageOCR(failingWidths:[40]),processor=AXImageOCRProcessor(),broker=ImageTestBroker()
        var completed: [Int] = []
        let task=Task { try await processor.process(snapshot:distinctSnapshot(),image:image(),selection:selection,
            ocr:ocr,broker:broker,settings:.defaultProfile(for:.realtime),direction:.japaneseToKorean,
            onCompletion: { completed.append($0.index) }) }
        try await ocr.waitForStarts(2)
        await ocr.release(40)
        try await ocr.waitForStarts(3)
        XCTAssertEqual(completed,[1])
        await ocr.release(20);await ocr.release(60)
        let result=try await task.value
        XCTAssertEqual(result.failures,1);XCTAssertEqual(result.layers.count,2)
        XCTAssertEqual(result.diagnostics.map(\.status),["complete","failed","complete"])
    }
    func testReplacementFrameWaitsForUncancellableOldOCRPermits() async throws {
        let ocr=ControlledImageOCR(),processor=AXImageOCRProcessor(),broker=ImageTestBroker()
        let old=Task { try await processor.process(snapshot:distinctSnapshot(),image:image(),selection:selection,
            ocr:ocr,broker:broker,settings:.defaultProfile(for:.realtime),direction:.japaneseToKorean) }
        try await ocr.waitForStarts(2)
        old.cancel();processor.reset()
        let replacement=Task { try await processor.process(snapshot:distinctSnapshot(),image:image(),selection:selection,
            ocr:ocr,broker:broker,settings:.defaultProfile(for:.realtime),direction:.japaneseToKorean) }
        for _ in 0..<100 { await Task.yield() }
        let before=await ocr.started.count;XCTAssertEqual(before,2)
        await ocr.release(20);await ocr.release(40)
        do { _ = try await old.value;XCTFail("expected cancellation") } catch is CancellationError {}
        try await ocr.waitForStarts(4)
        await ocr.release(20);await ocr.release(40)
        try await ocr.waitForStarts(5)
        await ocr.release(60)
        let result=try await replacement.value
        let maximum=await ocr.maximum;XCTAssertEqual(maximum,2)
        XCTAssertTrue(result.diagnostics.allSatisfy { !$0.cacheHit })
    }
    func testRealOCRBenchmarkSavedFrame() async throws {
        guard let path = ProcessInfo.processInfo.environment["REARVIEW_IMAGE_OCR_BENCHMARK"] else {
            throw XCTSkip("Explicit saved-frame benchmark only")
        }
        let folder=URL(fileURLWithPath:path)
        func read(_ name:String) throws -> Data { try Data(contentsOf:folder.appendingPathComponent(name)) }
        let snapshot=try AXExtractionSnapshot(nodes:read("rawAx.json"),selected:read("candidate.json"),paragraphs:read("native-paragraphs.json"),metadata:read("metadata.json"))
        let metadata=try JSONSerialization.jsonObject(with:read("metadata.json")) as! [String:Any]
        let r=metadata["selectionRegion"] as! [String:Double]
        let region=CGRect(x:r["x"]!,y:r["y"]!,width:r["width"]!,height:r["height"]!)
        let pixels=try XCTUnwrap(NSBitmapImageRep(data:read("render-source.png"))?.cgImage)
        let jobs=AXImageOCRProcessor.jobs(snapshot:snapshot,image:pixels,selection:region)
        XCTAssertGreaterThanOrEqual(jobs.count,2)
        let captured=SessionCoordinator.AXTranslatedFrame(frame:.init(snapshot:snapshot,image:pixels,frameID:1,receivedAt:0),entries:[])
        let baseArtwork=await AXLineRendering.render(captured)
        let repeats=Int(ProcessInfo.processInfo.environment["REARVIEW_IMAGE_OCR_BENCHMARK_PAIRS"] ?? "8") ?? 8
        let includesTranslation=ProcessInfo.processInfo.environment["REARVIEW_IMAGE_OCR_BENCHMARK_TRANSLATION"] == "1"
        let renders=ProcessInfo.processInfo.environment["REARVIEW_IMAGE_OCR_BENCHMARK_RENDER"] != "0"
        var samples: [ImageOCRBenchmarkSample] = []
        // Both modes get a warm-up. Alternate AB/BA pairs to balance order bias.
        let order=[1,2] + (0..<repeats).flatMap { $0.isMultiple(of:2) ? [1,2] : [2,1] }
        for (iteration,concurrency) in order.enumerated() {
            let broker: any SessionTranslationProvider
            var worker: Task<Void,Never>?
            var translationSession: TranslationSession?
            if includesTranslation {
                guard #available(macOS 26.0, *) else { throw XCTSkip("Installed TranslationSession requires macOS 26") }
                let real=TranslationBroker(direction:.japaneseToKorean,protectsNonSourceText:TranslationTextProtection.load())
                let session: TranslationSession
                if #available(macOS 26.4, *) {
                    session=TranslationSession(installedSource:TranslationDirection.japaneseToKorean.sourceLocale,
                        target:TranslationDirection.japaneseToKorean.targetLocale,preferredStrategy:TranslationStrategyPolicy.preferred())
                } else {
                    session=TranslationSession(installedSource:TranslationDirection.japaneseToKorean.sourceLocale,
                        target:TranslationDirection.japaneseToKorean.targetLocale)
                }
                translationSession=session
                worker=Task { await real.run(session:session) }
                let deadline=ContinuousClock.now + .seconds(15)
                while !real.isReadyForTranslation,real.preparationError == nil,ContinuousClock.now < deadline {
                    try await Task.sleep(for:.milliseconds(10))
                }
                guard real.isReadyForTranslation else {
                    worker?.cancel()
                    XCTFail("Real translation preparation failed: \(real.preparationError ?? "timeout")")
                    return
                }
                broker=real
            } else { broker=ImageTestBroker() }
            defer { worker?.cancel(); if #available(macOS 26.0, *) { translationSession?.cancel() } }
            let view=NativeTranslationMirrorView(frame:CGRect(x:0,y:0,width:pixels.width,height:pixels.height))
            view.setRenderingActive(true)
            let processor=AXImageOCRProcessor(concurrency:concurrency)
            let start=ContinuousClock.now
            func seconds() -> Double {
                let d=(ContinuousClock.now-start).components
                return Double(d.seconds)+Double(d.attoseconds)/1e18
            }
            let timed=TimedImageBenchmarkOCR(start:start)
            var firstReady: Double?,firstDisplay: Double?,allReady=0.0,allDisplay=0.0
            var completed: [Int:AXImageOCRResult] = [:]
            let result=try await processor.process(snapshot:snapshot,image:pixels,selection:region,
                ocr:timed,broker:broker,settings:.defaultProfile(for:.realtime),direction:.japaneseToKorean,
                onCompletion: { value in
                    let ready=seconds();if firstReady == nil { firstReady=ready };allReady=ready
                    if !renders { if firstDisplay == nil { firstDisplay=ready };allDisplay=ready;return }
                    completed[value.index]=value.result
                    let layers=completed.keys.sorted().flatMap { completed[$0]!.layers }
                    var frame=MirrorFrame(image:pixels,translatedItems:layers.flatMap { $0.mappedItems(frameSize:CGSize(width:pixels.width,height:pixels.height)) },frameID:1)
                    frame.axArtwork=baseArtwork;frame.imageOCRLayers=layers
                    view.frameSnapshot=frame
                    XCTAssertNotNil(view.compositedImage())
                    let displayed=seconds();if firstDisplay == nil { firstDisplay=displayed };allDisplay=displayed
                })
            let calls=await timed.calls.sorted { $0.start < $1.start }
            let maximum=await timed.maximum
            samples.append(.init(translation:includesTranslation ? "system_translation" : "immediate_stub",concurrency:concurrency,
                warmup:iteration < 2,renders:renders,firstReady:try XCTUnwrap(firstReady),firstDisplay:try XCTUnwrap(firstDisplay),
                allReady:allReady,allDisplay:allDisplay,maxConcurrentOCR:maximum,calls:calls,diagnostics:result.diagnostics))
            XCTAssertEqual(result.failures,0)
            XCTAssertEqual(calls.count,jobs.count)
            XCTAssertEqual(result.diagnostics.count,jobs.count)
            XCTAssertTrue(result.diagnostics.allSatisfy { !$0.cacheHit })
            XCTAssertLessThanOrEqual(maximum,concurrency)
            print("IMAGE_OCR_BENCHMARK iteration=\(iteration) concurrency=\(concurrency) firstReady=\(firstReady!) firstDisplay=\(firstDisplay!) allReady=\(allReady) allDisplay=\(allDisplay) maximum=\(maximum) regions=\(calls.count)")
        }
        if let output=ProcessInfo.processInfo.environment["REARVIEW_IMAGE_OCR_BENCHMARK_OUTPUT"] {
            let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
            try encoder.encode(samples).write(to:URL(fileURLWithPath:output),options:.atomic)
        }
    }
    func testNoImagesNeverCallsOCR() async throws {
        let ocr=ImageTestOCR()
        let result=try await AXImageOCRProcessor().process(snapshot:snapshot(count:0),image:image(),selection:selection,ocr:ocr,broker:ImageTestBroker(),settings:.defaultProfile(for:.realtime),direction:.japaneseToKorean)
        XCTAssertTrue(result.layers.isEmpty);let calls=await ocr.calls;XCTAssertEqual(calls,0)
    }
}
#endif
