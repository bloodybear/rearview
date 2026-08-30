#if DEBUG
import AppKit
import XCTest
@testable import Rearview

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

    init(batch: OCRService.RecognitionBatch, gate: TestGate? = nil) {
        self.batch = batch
        self.gate = gate
    }

    func recognize(
        image: CGImage, mode: OCRMode, regionOfInterest: CGRect?,
        includeRejectedAlternatives: Bool, settings: OCRSettings?,
        direction: TranslationDirection
    ) async throws -> OCRService.RecognitionBatch {
        if let gate { await gate.wait() }
        return batch
    }
}

@MainActor
private final class TestTranslationProvider: SessionTranslationProvider {
    var translations: [String: String]
    var gate: TestGate?
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

    func translate(_ source: String) async throws -> String {
        calls.append(source)
        if let gate { await gate.wait() }
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

    override func tearDown() async throws {
        for coordinator in coordinatorsUnderTest.reversed() {
            await coordinator.stop()
        }
        coordinatorsUnderTest.removeAll()
        try await super.tearDown()
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
