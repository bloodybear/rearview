import ApplicationServices
import Security

import NotionAXCore
import AppKit
import os

protocol SessionCaptureProvider: AnyObject, Sendable {
    func start(
        displayID: CGDirectDisplayID, screenFrame: CGRect, backingScale: CGFloat,
        selection: CGRect, target: CaptureTarget, policy: CapturePolicy,
        onFrame: @escaping @Sendable (CGImage, UInt64, UInt64) -> Void
    ) async throws
    func update(policy: CapturePolicy) async throws
    func updateRegion(
        selection: CGRect, screenFrame: CGRect, backingScale: CGFloat,
        displayID: CGDirectDisplayID?
    ) async throws
    func updateTarget(displayID: CGDirectDisplayID, target: CaptureTarget) async throws
    func stop() async
}

@MainActor
protocol SessionTargetResolver: AnyObject {
    func applications(for selection: CGRect, on screen: NSScreen) async throws -> [CaptureApplication]
    func resolveTarget(for selection: CGRect, on screen: NSScreen) async throws -> CaptureTargetResolution
}

protocol SessionOCRProvider: AnyObject, Sendable {
    func recognize(
        image: CGImage, mode: OCRMode, regionOfInterest: CGRect?,
        includeRejectedAlternatives: Bool, settings: OCRSettings?,
        direction: TranslationDirection
    ) async throws -> OCRService.RecognitionBatch
}

@MainActor
protocol SessionTranslationProvider: AnyObject, Sendable {
    func setDirection(_ direction: TranslationDirection)
    func setProtectsNonSourceText(_ enabled: Bool)
    func translate(_ source: String) async throws -> String
    func translate(_ source: String, options: TranslationRequestOptions) async throws -> String
}

@MainActor
protocol SessionOutputSink: AnyObject {
    func display(_ frame: MirrorFrame)
    func showProcessingStatus(_ status: MirrorProcessingStatus, frameID: UInt64)
    func cancelProcessingStatus()
}

extension ScreenCaptureEngine: SessionCaptureProvider {}
extension CaptureApplicationPicker: SessionTargetResolver {}
extension OCRService: SessionOCRProvider {}
extension TranslationBroker: SessionTranslationProvider {}

enum RefinementOCRDecision: Equatable {
    case skipHighConfidence
    case fullFrameFallback
    case lowConfidenceROI
}

struct LatestValueLatch<Value> {
    private(set) var value: Value?

    mutating func store(_ newValue: Value) { value = newValue }

    mutating func take(when ready: Bool) -> Value? {
        guard ready, let value else { return nil }
        self.value = nil
        return value
    }

    mutating func clear() { value = nil }
}

func decideRefinementOCR(observationCount: Int, japaneseLines: [RecognizedLine], policy: RefinementOCRPolicy) -> RefinementOCRDecision {
    if policy.alwaysRun { return .lowConfidenceROI }
    if observationCount == 0 { return .fullFrameFallback }
    if japaneseLines.isEmpty { return .fullFrameFallback }
    return japaneseLines.contains(where: { $0.confidence < policy.confidenceThreshold })
        ? .lowConfidenceROI : .skipHighConfidence
}

@MainActor
final class SessionCoordinator {
    private static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map { $0.uint32Value }
    }

    private struct FrameEnvelope {
        let image: CGImage
        let id: UInt64
        let receivedAt: UInt64
    }

    private struct TranslationResult: Sendable {
        let line: RecognizedLine
        let translated: String
    }

    private struct WindowTrackingAnchor {
        let processID: pid_t
        let windowID: CGWindowID
        let insets: WindowTrackingInsets?
        var lastKnownWindowFrame: CGRect
        var missingSince: ContinuousClock.Instant?
    }

    private enum TrackedWindowLookup {
        case visible(CGRect)
        case unavailable
        case queryFailed
    }

    let diagnostics = DiagnosticRecorder()
    private let broker: any SessionTranslationProvider
    private let capture: any SessionCaptureProvider
    private let targetResolver: any SessionTargetResolver
    private let ax: any SessionAXProvider
    private(set) var textExtractionMode: TextExtractionMode = .ocr
    struct AXFrameSnapshot: @unchecked Sendable {
        let snapshot: AXExtractionSnapshot
        let image: CGImage
        let frameID: UInt64
        let receivedAt: UInt64
        var scrollAnchorRequestID: UUID? = nil
    }
    struct AXTranslatedFrame: Sendable {
        let frame: AXFrameSnapshot
        let entries: [AXParagraphTranslation]
        var retainedBody: AXBodyReuse? = nil
        var bodyReuseDiagnostic: AXBodyReuseDiagnostic? = nil
        var imageOCR = AXImageOCRResult()
    }
    private let imageOCRProcessor = AXImageOCRProcessor()
    private let bodyRetention = AXBodyRetention()
    private enum AXWorkResult: Sendable {
        case paragraph(Int, AXParagraphTranslation)
        case images(AXImageOCRProcessor.Completion)
    }
    private(set) var latestAXRenderedFrame: MirrorFrame?
    private(set) var latestAXTranslation: AXTranslatedFrame?
    var onAXTranslation: ((AXTranslatedFrame) -> Void)?
    var onAXPresentation: ((AXTranslatedFrame) -> Void)?
    var onAXTranslationProgress: ((AXTranslatedFrame) -> Void)?
    private let translatesAXParagraphs: Bool
    private(set) var latestAXFrame: AXFrameSnapshot?
    var latestAXSnapshot: AXExtractionSnapshot? { latestAXFrame?.snapshot }
    var onAXExtraction: ((AXExtractionSnapshot, CGImage, UInt64) -> Void)?
    private let failureNotice = SessionFailureNotice()
    private var failureDeduplicator = SessionFailureDeduplicator()
    var onFailure: ((SessionFailure) -> Void)?
    private func reportFailure(_ error: Error?, stage: SessionFailure.Stage, userInitiated: Bool = false) {
        diagnostics.error(error,stage:stage.rawValue,id:diagnostics.current)
        let failure = SessionFailure.make(error, stage: stage)
        guard failureDeduplicator.shouldPresent(failure, userInitiated: userInitiated) else { return }
        onFailure?(failure)
        if createsOutputWindow { failureNotice.show(failure, anchor: mirror, anchorRect: mirror?.failureNoticeAnchorRect) }
    }
    var onAXExtractionError: ((Error) -> Void)?
    private let ocr: any SessionOCRProvider
    private let changes = ChangeDetector()
    private let outputSink: (any SessionOutputSink)?
    private let createsOutputWindow: Bool
    private var mirror: TranslationMirrorWindow?
    private var regionBorder: RegionBorderController?
    private var mirrorUpdateStyle: MirrorUpdateStyle = .atomic
    private var translationDirection = TranslationDirection.load()
    private var protectsNonSourceText = TranslationTextProtection.load()
    private var displayMode = TranslationDisplayMode.load()
    private var mirrorDockingState = MirrorDockingState.load()
    private var overlaySettings = OverlayPresentationSettings.load()
    private var selectedScreen: NSScreen?
    private var selection: CGRect = .zero
    private var captureTarget: CaptureTarget = .allContent
    private var availableApplications: [CaptureApplication] = []
    private var refreshMode = RefreshMode.load()
    private var paused = false
    private(set) var overlayOriginalView = false
    private var captureSuspended = false
    private var captureEpoch = 0
    private var captureStreamID: UUID?
    private var captureTransition: Task<Void, Never>?

    var canToggleOverlayOriginalView: Bool {
        isSessionActive && displayMode == .overlay && !stopping
    }
    private var acceptingFrames = false
    private var stopping = false
    private var mirrorFollowsSelectionSize = MirrorFollowsSelectionSize.load()
    private var targetApplicationTracking = TargetApplicationTracking.load()
    private var capturePolicy = CapturePolicy.load()
    private var refinementOCRPolicy = RefinementOCRPolicy.load()
    private var ocrSettings: [OCRMode: OCRSettings] = [
        .realtime: OCRSettings.load(mode: .realtime),
        .refinement: OCRSettings.load(mode: .refinement)
    ]
    private var generation = 0
    private var contentRevision = 0
    private var processingFrames = false
    private var latestFrame: FrameEnvelope?
    private var latestCapturedFrame: FrameEnvelope?
    private var pendingAutomaticFrame = LatestValueLatch<FrameEnvelope>()
    private var ocrTask: Task<Void, Never>?
    private var delayedRefinementTask: Task<Void, Never>?
    private var windowTrackingTask: Task<Void, Never>?
    private var selectionUpdateTask: Task<Void, Never>?
    private var windowTrackingAnchor: WindowTrackingAnchor?
    private var selectionInteractionActive = false
    private var ocrTaskRevision: Int?
    private var ocrTaskSequence: UInt64 = 0
    private var lastRealtimeOCR = ContinuousClock.now - .seconds(2)
    private var lastMotion = ContinuousClock.now
    private var lastRealtimeLines: [RecognizedLine] = []
    private var lastRealtimeObservationCount = 0
    private var stabilityEpoch: UInt64 = 0
    private var lastRefinementEpoch: UInt64?
    private var benchmarkDiagnostics = false
    private var debugCaptureTranscript: DebugCaptureTextTranscript?
    private var initialComparisonStarted = false
    private let logger = Logger(subsystem: "io.github.bloodybear.rearview", category: "pipeline")

    var onDisplayModeChange: ((TranslationDisplayMode) -> Void)?
    var onOverlayPresentationChange: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onTranslationDirectionChange: ((TranslationDirection) -> Void)?
    var onNonSourceTextProtectionChange: ((Bool) -> Void)?

    init(
        broker: any SessionTranslationProvider,
        capture: any SessionCaptureProvider = ScreenCaptureEngine(),
        targetResolver: any SessionTargetResolver = CaptureApplicationPicker(),
        ocr: any SessionOCRProvider = OCRService(),
        ax: any SessionAXProvider = NativeSessionAXProvider(),
        outputSink: (any SessionOutputSink)? = nil,
        createsOutputWindow: Bool = true,
        translatesAXParagraphs: Bool = true,
        initialTranslationDirection: TranslationDirection? = nil,
        initialTextExtractionMode: TextExtractionMode = .ocr,
        persistsExtractionMode: Bool = false
    ) {
        self.persistsExtractionMode = persistsExtractionMode
        self.textExtractionMode = initialTextExtractionMode
        self.broker = broker
        self.translatesAXParagraphs = translatesAXParagraphs
        if let initialTranslationDirection { self.translationDirection = initialTranslationDirection }
        self.capture = capture
        self.targetResolver = targetResolver
        self.ocr = ocr
        self.ax = ax
        self.outputSink = outputSink
        self.createsOutputWindow = createsOutputWindow
        (broker as? TranslationBroker)?.diagnosticRecorder=diagnostics
    }

    var usesAXExtraction: Bool {
        TextExtractionPreference.effective(textExtractionMode, bundleIdentifier: captureTarget.application?.bundleIdentifier) == .ax
    }

    var onExtractionModeChange: ((TextExtractionMode) -> Void)?
    private var modeTransition: Task<Void, Never>?
    private var modeTransitionID = 0
    private var modeTransitionInProgress = false
    private var pendingModeRefresh = false
    private let persistsExtractionMode: Bool
    func setTextExtractionMode(_ mode: TextExtractionMode) async {
        cancelPrefetch()
        diagnostics.event("mode.change", ["requested":mode == .ax ? "ax":"ocr"])
        guard mode != textExtractionMode else { return }
        textExtractionMode = mode
        if persistsExtractionMode { TextExtractionPreference.save(mode) }
        mirror?.clearTextInteractions()
        mirror?.clearTranslationOutput()
        mirror?.setExtractionMode(mode)
        onExtractionModeChange?(mode)
        failureDeduplicator.reset()
        failureNotice.dismiss()
        modeTransitionInProgress = true
        pendingModeRefresh = false
        let frame = latestCapturedFrame
        invalidateCapturedContent()
        if let frame { display(MirrorFrame(image: frame.image, translatedItems: [], frameID: frame.id)) }
        modeTransitionID += 1
        let transitionID = modeTransitionID, activeGeneration = generation, activeRevision = contentRevision
        let previous = modeTransition
        let task = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            await self.ax.endSession()
            guard self.modeTransitionID == transitionID else { return }
            self.modeTransitionInProgress = false
            guard self.generation == activeGeneration, self.contentRevision == activeRevision else { return }
            if self.latestCapturedFrame == nil { self.latestCapturedFrame = frame }
            if self.latestCapturedFrame != nil { self.translateImmediately() }
            else { self.pendingModeRefresh = self.isSessionActive && !self.captureSuspended }
        }
        modeTransition = task
        await task.value
        if modeTransitionID == transitionID { modeTransition = nil }
    }

    private var visibleFirstAXCollection: Bool {
        #if LST_EXCLUDE_DEBUG_FEATURES
        false
        #else
        CommandLine.arguments.contains("--ax-visible-first")
        #endif
    }

    private var pruneOffscreenAXBranches: Bool {
        #if LST_EXCLUDE_DEBUG_FEATURES
        true
        #else
        !CommandLine.arguments.contains("--ax-disable-branch-pruning")
        #endif
    }

    private var prefetchTask: Task<Void, Never>?
    private var prefetchToken: TranslationPrefetch?
    private var prefetchEnabled: Bool {
        #if LST_EXCLUDE_DEBUG_FEATURES
        translatesAXParagraphs
        #else
        translatesAXParagraphs && !CommandLine.arguments.contains("--ax-disable-prefetch")
        #endif
    }

    private func cancelPrefetch() {
        guard let token = prefetchToken else { return }
        token.cancelled = true
        prefetchTask?.cancel()
        prefetchToken = nil
        prefetchTask = nil
        cancelProcessingStatus()
    }

    private func startPrefetch(requestID: UUID, frameID: UInt64, total: Int) {
        guard prefetchEnabled, total > 0, !paused, pendingAutomaticFrame.value == nil else { return }
        let token = TranslationPrefetch()
        prefetchToken = token
        let ax = self.ax
        let translator = AXParagraphTranslator(broker: broker, direction: translationDirection)
        showProcessingStatus(.prefetching(completed: 0, total: total), frameID: frameID)
        prefetchTask = Task(priority: .utility) { [weak self] in
            defer {
                if let self, self.prefetchToken === token { self.cancelPrefetch() }
            }
            var completed = 0
            await TranslationPrefetch.$current.withValue(token) {
                do {
                    while !Task.isCancelled, !token.cancelled {
                        let start = DispatchTime.now().uptimeNanoseconds
                        guard let source = try await ax.nextPrefetchSource(requestID: requestID) else { break }
                        PerformanceProfiler.shared.recordElapsed(.axPrefetchRead, startedAt: start)
                        try Task.checkCancellation()
                        if source.isEmpty {
                            PerformanceProfiler.shared.increment("ax.prefetchSkipped")
                        } else {
                            let result = try await translator.translate(.init(plainSource: source), node: 0)
                            PerformanceProfiler.shared.increment("ax.prefetch." + result.status)
                        }
                        guard !Task.isCancelled, let self, self.prefetchToken === token else { break }
                        completed += 1
                        self.showProcessingStatus(.prefetching(completed: completed, total: total), frameID: frameID)
                    }
                } catch is CancellationError {
                    PerformanceProfiler.shared.increment("ax.prefetchCancelled")
                } catch {
                    PerformanceProfiler.shared.increment("ax.prefetchFailed")
                }
            }
        }
    }

    private func axRequest() throws -> AXExtractionRequest {
        guard let app = captureTarget.application,
              let windowID = windowTrackingAnchor?.windowID ?? app.anchorWindowID,
              let windowFrame = windowTrackingAnchor?.lastKnownWindowFrame ?? app.anchorWindowFrame,
              let screen = selectedScreen, let displayID = Self.displayID(for:screen) else {
            throw AXExtractionError.windowMappingFailed
        }
        return AXExtractionRequest(processID:app.processID,windowID:windowID,windowFrame:windowFrame,
            selectionRegion:screenCaptureRect(for:selection,screenFrame:screen.frame,displayBounds:CGDisplayBounds(displayID)),
            collectParentTextDiagnostics:CommandLine.arguments.contains("--ax-collect-parent-values"), visibleFirst: visibleFirstAXCollection,
            pruneOffscreenBranches: pruneOffscreenAXBranches, prefetch: prefetchEnabled,
            retainScrollAnchors: scrollPreviewEnabled)
    }

    private func axPresentation(_ value: AXTranslatedFrame, artwork: AXRenderArtwork) -> MirrorFrame {
        let size = CGSize(width:value.frame.image.width,height:value.frame.image.height)
        var frame = MirrorFrame(image:value.frame.image,
            translatedItems:artwork.items + ((value.retainedBody?.imageLayers ?? []) + value.imageOCR.layers).flatMap { $0.mappedItems(frameSize:size) },
            ocrDebugItems:value.imageOCR.layers.flatMap { layer in
                layer.debugItems.map { item in
                    OCRDebugItem(id:item.id,status:item.status,rawText:item.rawText,confidence:item.confidence,
                        recognitionLanguages:item.recognitionLanguages,translatedText:item.translatedText,
                        normalizedRect:AXImageOCRProcessor.normalized(item.normalizedRect,in:layer.pixelBox,frameSize:size))
                }
            },frameID:value.frame.frameID)
        frame.axArtwork = artwork
        frame.imageOCRLayers = (value.retainedBody?.imageLayers ?? []) + value.imageOCR.layers
        return frame
    }

    private var scrollPreviewEnabled: Bool {
        #if !LST_EXCLUDE_DEBUG_FEATURES
        return !CommandLine.arguments.contains("--disable-ax-scroll-preview")
        #else
        return true
        #endif
    }

    private var scrollPreviewFrameID: UInt64?

    private func startScrollPreview(_ frame: FrameEnvelope, request: AXExtractionRequest,
                                    diagnosticID: UUID?, origin: MirrorStatusOrigin) async -> Task<Void, Never>? {
        guard request.retainScrollAnchors, origin == .automatic, translatesAXParagraphs, mirrorUpdateStyle == .atomic,
              mirror?.allowsAXScrollPreview == true,
              let previous = latestAXTranslation, previous.retainedBody == nil,
              let sourceID = previous.frame.scrollAnchorRequestID,
              let rendered = latestAXRenderedFrame, rendered.frameID == previous.frame.frameID,
              let artwork = rendered.axArtwork, frame.id > rendered.frameID,
              frame.image.width == previous.frame.image.width, frame.image.height == previous.frame.image.height else { return nil }
        let generation = generation, revision = contentRevision, sequence = ocrTaskSequence, epoch = stabilityEpoch
        let started = ContinuousClock.now
        // Read these anchors before starting the regular collection on the same AX queue.
        guard let displacement = await ax.scrollDisplacement(from: sourceID, to: request),
              !Task.isCancelled, self.generation == generation, self.contentRevision == revision,
              self.ocrTaskSequence == sequence, self.stabilityEpoch == epoch else { return nil }
        let deltaY = -displacement * CGFloat(frame.image.height) / request.selectionRegion.height
        return Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) {
                AXScrollPreview.make(size: CGSize(width: frame.image.width, height: frame.image.height),
                    deltaY: deltaY, artwork: artwork, snapshot: previous.frame.snapshot)
            }
            let result = await withTaskCancellationHandler {
                await worker.value
            } onCancel: { worker.cancel() }
            guard let self, !Task.isCancelled, self.generation == generation, self.contentRevision == revision,
                  self.ocrTaskSequence == sequence, self.stabilityEpoch == epoch,
                  self.latestAXRenderedFrame?.frameID == rendered.frameID,
                  self.mirror?.allowsAXScrollPreview == true, let result else { return }
            var preview = MirrorFrame(image: frame.image, translatedItems: [], frameID: frame.id)
            preview.axArtwork = result
            preview.isAXScrollPreview = true
            self.scrollPreviewFrameID = frame.id
            self.diagnostics.mark("ax.scroll_preview", id: diagnosticID, [
                "shift": String(Double(deltaY)), "method": "ax_position", "parts": String(result.diagnostics.count),
                "elapsed": String(describing: started.duration(to: .now))
            ])
            self.display(preview)
        }
    }

    private func scheduleAX(_ frame: FrameEnvelope, origin: MirrorStatusOrigin) {
        cancelPrefetch()
        let activeGeneration = generation, activeRevision = contentRevision
        ocrTaskSequence &+= 1
        let sequence = ocrTaskSequence
        let diagnosticID = beginDiagnosticFrame(frame, task:sequence)
        let diagnosticContext=diagnosticID.map { DiagnosticFrameContext(diagnostics,id:$0) }
        ocrTaskRevision = activeRevision
        showProcessingStatus(.recognizing, frameID:frame.id, origin:origin)
        ocrTask = Task { [weak self] in
            guard let self else { return }
            var preview: Task<Void, Never>?
            defer {
                preview?.cancel()
                if self.generation == activeGeneration, self.ocrTaskSequence == sequence {
                    self.ocrTask = nil; self.ocrTaskRevision = nil
                    _ = self.processPendingAutomaticFrameIfPossible()
                }
            }
            var diagnosticRequestID:UUID?
            do {
                let request = try self.axRequest()
                diagnosticRequestID=request.diagnosticRequestID
                preview = await self.startScrollPreview(frame, request: request, diagnosticID: diagnosticID, origin: origin)
                try Task.checkCancellation()
                let axStarted=Date()
                let result = try await self.ax.collect(request)
                self.recordAXDiagnostic(result,id:diagnosticID)
                let access=await self.ax.diagnosticSnapshot()
                self.recordAXAccessDiagnostic(access,requestID:request.diagnosticRequestID,id:diagnosticID)
                self.diagnostics.mark("ax.finished",id:diagnosticID,["seconds":String(Date().timeIntervalSince(axStarted)),"status":result.status.rawValue])
                guard !Task.isCancelled, self.generation == activeGeneration,
                      self.contentRevision == activeRevision, self.ocrTaskSequence == sequence else { self.diagnostics.event("result.discarded",frame:diagnosticID,["reason":"stale_or_cancelled"]); return }
                if result.status == .failed { throw SessionCollectionFailure.failed }
                self.failureDeduplicator.succeeded(.ax)
                let bodyScope=AXBodyScope(generation:activeGeneration,processID:request.processID,windowID:request.windowID,
                    window:request.windowFrame,selection:request.selectionRegion,pixels:CGSize(width:frame.image.width,height:frame.image.height),
                    direction:String(describing:self.translationDirection),protection:self.protectsNonSourceText)
                let (retainedBody,reuseDiagnostic)=self.bodyRetention.resolve(snapshot:result,scope:bodyScope)
                self.latestAXFrame = AXFrameSnapshot(snapshot:result,image:frame.image,frameID:frame.id,receivedAt:frame.receivedAt,
                    scrollAnchorRequestID: request.retainScrollAnchors ? request.diagnosticRequestID : nil)
                // Match OCR: atomic updates retain the displayed result until rendering finishes.
                if !self.translatesAXParagraphs || (self.mirrorUpdateStyle == .progressive && retainedBody == nil) {
                    self.display(MirrorFrame(image:frame.image,translatedItems:[],frameID:frame.id))
                }
                self.onAXExtraction?(result, frame.image, frame.id)
                if self.translatesAXParagraphs, retainedBody != nil, let captured=self.latestAXFrame {
                    let visible=AXTranslatedFrame(frame:captured,entries:[],retainedBody:retainedBody,bodyReuseDiagnostic:reuseDiagnostic)
                    let artwork=await AXLineRendering.render(visible)
                    guard !Task.isCancelled, self.generation == activeGeneration,self.contentRevision == activeRevision,self.ocrTaskSequence == sequence else { return }
                    let presentation=self.axPresentation(visible,artwork:artwork)
                    self.latestAXRenderedFrame=presentation;self.display(presentation);self.onAXPresentation?(visible)
                }
                if self.translatesAXParagraphs {
                    let translator = AXParagraphTranslator(broker: self.broker, direction: self.translationDirection)
                    let imageJobs = AXImageOCRProcessor.jobs(snapshot:result,image:frame.image,selection:request.selectionRegion)
                    let total = result.paragraphUnits.count + imageJobs.count
                    self.showProcessingStatus(.translating(completed:0,total:total),frameID:frame.id,origin:origin)
                    if !result.imageRegions.contains(where: { $0.status == "selected" }) { self.imageOCRProcessor.reset() }
                    var imageOCR = AXImageOCRResult()
                    let settings = self.ocrSettings[.realtime] ?? OCRSettings.defaultProfile(for:.realtime)
                    let direction = self.translationDirection
                    let processor = self.imageOCRProcessor, ocr = self.ocr, broker = self.broker
                    let (events, continuation) = AsyncThrowingStream<AXWorkResult, Error>.makeStream()
                    let entries = try await withThrowingTaskGroup(of:Void.self) { producers in
                        producers.addTask {
                            do {
                                try await withThrowingTaskGroup(of:Void.self) { group in
                                    if !imageJobs.isEmpty {
                                        group.addTask {
                                            _ = try await DiagnosticTaskScope.$context.withValue(diagnosticContext) { try await processor.process(snapshot:result,image:frame.image,
                                                selection:request.selectionRegion,ocr:ocr,broker:broker,settings:settings,direction:direction,
                                                onCompletion: { continuation.yield(.images($0)) }) }
                                        }
                                    }
                                    for (index, paragraph) in result.paragraphUnits.enumerated() {
                                        let request = AXTranslationRequest(paragraph:paragraph)
                                        group.addTask {
                                            let value = try await DiagnosticTaskScope.$context.withValue(diagnosticContext) { try await translator.translate(request,node:paragraph.node) }
                                            continuation.yield(.paragraph(index,value))
                                        }
                                    }
                                    try await group.waitForAll()
                                }
                                continuation.finish()
                            } catch { continuation.finish(throwing:error) }
                        }
                        defer { producers.cancelAll() }
                        var completed: [(Int, AXParagraphTranslation)] = []
                        var images: [Int:AXImageOCRResult] = [:]
                        var lastPresentation = ContinuousClock.now
                        var finished = 0
                        var artwork: AXRenderArtwork?
                        var renderedParagraphs = -1
                        for try await entry in events {
                            try Task.checkCancellation()
                            guard self.generation == activeGeneration, self.contentRevision == activeRevision,
                                  self.ocrTaskSequence == sequence else { throw CancellationError() }
                            finished += 1
                            let imageCompleted: Bool
                            switch entry {
                            case let .paragraph(index,value): completed.append((index,value)); imageCompleted = false
                            case let .images(value):
                                images[value.index] = value.result
                                let ordered = images.keys.sorted().compactMap { images[$0] }
                                imageOCR = AXImageOCRResult(layers:ordered.flatMap(\.layers),diagnostics:ordered.flatMap(\.diagnostics),maxConcurrentOCR:ordered.map(\.maxConcurrentOCR).max() ?? 0)
                                imageCompleted = true
                            }
                            if let captured = self.latestAXFrame {
                                let allParagraphs = completed.count == result.paragraphUnits.count
                                let visibleEntries = self.mirrorUpdateStyle == .progressive || allParagraphs
                                    ? completed.sorted { $0.0 < $1.0 }.map { $0.1 } : []
                                let progress = AXTranslatedFrame(frame:captured,entries:completed.sorted { $0.0 < $1.0 }.map { $0.1 },retainedBody:retainedBody,bodyReuseDiagnostic:reuseDiagnostic,imageOCR:imageOCR)
                                self.recordAXTranslationDiagnostic(progress,id:diagnosticID)
                                self.onAXTranslationProgress?(progress)
                                if imageCompleted || allParagraphs || (self.mirrorUpdateStyle == .progressive &&
                                    (artwork == nil || ContinuousClock.now-lastPresentation >= .milliseconds(50))) {
                                    let visible = AXTranslatedFrame(frame:captured,entries:visibleEntries,retainedBody:retainedBody,bodyReuseDiagnostic:reuseDiagnostic,imageOCR:imageOCR)
                                    if artwork == nil || renderedParagraphs != visibleEntries.count {
                                        artwork = await AXLineRendering.render(visible)
                                        renderedParagraphs = visibleEntries.count
                                    }
                                    try Task.checkCancellation()
                                    guard self.generation == activeGeneration, self.contentRevision == activeRevision,
                                          self.ocrTaskSequence == sequence else { throw CancellationError() }
                                    let presentation = self.axPresentation(visible,artwork:artwork!)
                                    self.latestAXRenderedFrame = presentation
                                    self.display(presentation)
                                    self.onAXPresentation?(visible)
                                    lastPresentation = .now
                                }
                            }
                            self.showProcessingStatus(.translating(completed:finished,total:total),frameID:frame.id,origin:origin)
                        }
                        try await producers.waitForAll()
                        return completed.sorted { $0.0 < $1.0 }.map { $0.1 }
                    }
                    guard !Task.isCancelled, self.generation == activeGeneration,
                          self.contentRevision == activeRevision, self.ocrTaskSequence == sequence,
                          let captured = self.latestAXFrame else { return }
                    let translated = AXTranslatedFrame(frame:captured,entries:entries,retainedBody:retainedBody,bodyReuseDiagnostic:reuseDiagnostic,imageOCR:imageOCR)
                    let artwork = await AXLineRendering.render(translated)
                    guard !Task.isCancelled, self.generation == activeGeneration,
                          self.contentRevision == activeRevision, self.ocrTaskSequence == sequence else { self.diagnostics.event("result.discarded",frame:diagnosticID,["reason":"stale_or_cancelled"]); return }
                    let rendered = self.axPresentation(translated,artwork:artwork)
                    self.latestAXRenderedFrame = rendered
                    self.display(rendered)
                    self.onAXPresentation?(translated)
                    self.bodyRetention.store(value:translated,artwork:artwork,scope:bodyScope)
                    self.recordAXTranslationDiagnostic(translated,id:diagnosticID)
                    self.latestAXTranslation = translated
                    let attempts = entries.filter { ["failed", "translated", "partial"].contains($0.status) }
                    if !attempts.isEmpty && attempts.allSatisfy({ $0.status == "failed" }) && imageOCR.layers.isEmpty { self.reportFailure(nil, stage: .translation, userInitiated: origin == .userAction) }
                    else if attempts.isEmpty && !imageOCR.diagnostics.isEmpty && imageOCR.failures == imageOCR.diagnostics.count {
                        let stage: SessionFailure.Stage = imageOCR.diagnostics.contains { $0.status == "failed" } ? .ocr : .translation
                        self.reportFailure(nil, stage: stage, userInitiated: origin == .userAction)
                    } else { self.failureDeduplicator.succeeded(.translation) }
                    self.showProcessingStatus(.completed(failures:imageOCR.failures + entries.filter { $0.status == "failed" }.count + (result.status == .complete ? 0 : 1)),frameID:frame.id,origin:origin)
                    self.onAXTranslation?(translated)
                    if result.status == .complete { self.startPrefetch(requestID: request.diagnosticRequestID, frameID: frame.id, total: result.prefetchCandidateCount) }
                } else {
                    self.showProcessingStatus(.completed(failures:result.status == .complete ? 0 : 1),frameID:frame.id,origin:origin)
                }
            } catch {
                if let requestID=diagnosticRequestID { self.recordAXAccessDiagnostic(await self.ax.diagnosticSnapshot(),requestID:requestID,id:diagnosticID) }
                self.diagnostics.error(error,stage:"ax",id:diagnosticID)
                guard !Task.isCancelled, self.generation == activeGeneration,
                      self.contentRevision == activeRevision, self.ocrTaskSequence == sequence else { self.diagnostics.event("result.discarded",frame:diagnosticID,["reason":"stale_or_cancelled"]); return }
                if let axError=error as? AXExtractionError, [.windowMappingFailed,.windowChanged,.targetTerminated].contains(axError) { self.bodyRetention.reset() }
                if self.scrollPreviewFrameID != nil, let previous = self.latestAXRenderedFrame {
                    self.display(previous)
                }
                self.showProcessingStatus(.recognitionFailed,frameID:frame.id,origin:origin)
                self.reportFailure(error, stage: .ax, userInitiated: origin == .userAction)
                self.onAXExtractionError?(error)
            }
        }
    }

    func start(
        screen: NSScreen, selection: CGRect,
        initialDockingState: MirrorDockingState? = nil,
        mirrorUpdateStyle: MirrorUpdateStyle = .atomic,
        captureTarget: CaptureTarget = .allContent,
        benchmarkDiagnostics: Bool = false,
        debugCaptureTranscript: DebugCaptureTextTranscript? = nil
    ) async throws {
        await stop()
        diagnostics.begin()
        self.selection = selection
        self.selectedScreen = screen
        mirrorDockingState = initialDockingState ?? MirrorDockingState.load()
        self.mirrorUpdateStyle = mirrorUpdateStyle

        // A newly selected region with exactly one visible app is scoped to that app.
        // Explicit targets remain authoritative for benchmark and programmatic starts.
        let resolvedTarget: CaptureTarget
        if captureTarget == .allContent {
            let resolvingGeneration = generation
            do {
                let resolution = try await targetResolver.resolveTarget(for: selection, on: screen)
                guard generation == resolvingGeneration else { throw CancellationError() }
                resolvedTarget = resolution.target
                self.availableApplications = resolution.candidate.map { [$0] } ?? []
            } catch {
                if generation == resolvingGeneration, !(error is CancellationError), SessionFailure.make(error, stage: .capture).permission != .screenCapture {
                    reportFailure(error, stage: .capture, userInitiated: true)
                }
                throw error
            }
        } else {
            resolvedTarget = captureTarget
            self.availableApplications = captureTarget.application.map { [$0] } ?? []
        }
        self.captureTarget = resolvedTarget
        diagnostics.update(["lastAttemptTargetBundleID":resolvedTarget.application?.bundleIdentifier ?? "all","lastAttemptSelection":String(describing:selection)])
        refreshDiagnosticState()
        generation += 1
        let activeGeneration = generation
        cancelPrefetch()
        contentRevision += 1
        delayedRefinementTask?.cancel()
        delayedRefinementTask = nil
        changes.reset()
        lastRealtimeLines = []
        lastRealtimeObservationCount = 0
        stabilityEpoch = 0
        lastRefinementEpoch = nil
        self.benchmarkDiagnostics = benchmarkDiagnostics
        initialComparisonStarted = false
        lastRealtimeOCR = .now - .seconds(2)
        lastMotion = .now
        self.debugCaptureTranscript = debugCaptureTranscript
        captureEpoch += 1

        do {
            try await startCaptureStream(on: screen, epoch: captureEpoch)
            guard generation == activeGeneration else {
                throw CancellationError()
            }
            if createsOutputWindow { createOutputWindow() }
            acceptingFrames = true
            startWindowTrackingIfNeeded()
        } catch {
            if !(error is CancellationError), generation == activeGeneration, SessionFailure.make(error, stage: .capture).permission != .screenCapture { reportFailure(error, stage: .capture, userInitiated: true) }
            await cleanupFailedStart(activeGeneration: activeGeneration)
            throw error
        }
    }

    private func startCaptureStream(on screen: NSScreen, epoch: Int) async throws {
        guard let displayID = Self.displayID(for: screen) else { throw TranslatorError.noDisplay }
        let streamID = UUID()
        captureStreamID = streamID
        if let engine = capture as? ScreenCaptureEngine {
            engine.onDiagnosticEvent = { [weak self] name in
                Task { @MainActor in self?.diagnostics.event("capture." + name) }
            }
            engine.onFailure = { [weak self] error in
                Task { @MainActor in
                    guard let self, self.captureEpoch == epoch, self.captureStreamID == streamID,
                          self.isSessionActive else { return }
                    self.reportFailure(error, stage: .capture)
                }
            }
        }
        try await capture.start(
            displayID: displayID, screenFrame: screen.frame,
            backingScale: screen.backingScaleFactor, selection: selection,
            target: captureTarget, policy: capturePolicy
        ) { [weak self] image, frameID, receivedAt in
            Task { @MainActor [weak self] in
                guard let self, self.captureEpoch == epoch, self.captureStreamID == streamID else { return }
                self.receive(image, frameID: frameID, receivedAt: receivedAt)
            }
        }
    }

    func toggleOverlayOriginalView() {
        guard canToggleOverlayOriginalView else { return }
        setOverlayOriginalView(!overlayOriginalView)
    }

    private func setOverlayOriginalView(_ enabled: Bool) {
        guard overlayOriginalView != enabled else { return }
        overlayOriginalView = enabled
        mirror?.setOriginalView(enabled)
        updateRegionBorderPresentation()
        captureEpoch += 1
        let epoch = captureEpoch
        acceptingFrames = false
        captureSuspended = true
        if enabled {
            pendingModeRefresh = false
            invalidateCapturedContent()
            failureNotice.dismiss()
        }
        let previous = captureTransition
        captureTransition = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, self.captureEpoch == epoch else { return }
            defer {
                if self.captureEpoch == epoch { self.captureTransition = nil }
            }
            await self.capture.stop()
            guard self.captureEpoch == epoch else { return }
            await self.modeTransition?.value
            guard self.captureEpoch == epoch else { return }
            await self.ax.endSession()
            guard self.captureEpoch == epoch, !enabled else { return }
            await self.resumeCapture(epoch: epoch)
        }
    }

    private func resumeCapture(epoch: Int) async {
        while captureEpoch == epoch, let screen = selectedScreen {
            let revision = contentRevision
            let policy = capturePolicy
            do {
                try await startCaptureStream(on: screen, epoch: epoch)
                guard captureEpoch == epoch else { return }
                if revision != contentRevision || policy != capturePolicy {
                    captureStreamID = nil
                    await capture.stop()
                    continue
                }
                captureSuspended = false
                acceptingFrames = true
                return
            } catch {
                guard captureEpoch == epoch else { return }
                if displayMode == .overlay {
                    overlayOriginalView = true
                    mirror?.setOriginalView(true)
                    updateRegionBorderPresentation()
                }
                reportFailure(error, stage: .capture, userInitiated: true)
                return
            }
        }
    }

    private func cleanupFailedStart(activeGeneration: Int) async {
        // A newer generation owns the coordinator state after it advances the
        // generation counter. Only the failed start may tear down its own
        // session; a concurrent stop or newer start performs its own cleanup.
        guard generation == activeGeneration else { return }
        await stop()
    }

    func stop() async {
        diagnostics.stop()
        modeTransitionID += 1
        modeTransitionInProgress = false
        pendingModeRefresh = false
        failureNotice.dismiss()
        failureDeduplicator.reset()
        bodyRetention.reset()
        imageOCRProcessor.reset()
        latestAXFrame = nil
        latestAXTranslation = nil; latestAXRenderedFrame = nil
        guard !stopping else { return }
        stopping = true
        captureEpoch += 1
        overlayOriginalView = false
        captureSuspended = false
        let pendingCaptureTransition = captureTransition
        captureTransition = nil
        defer { stopping = false }
        generation += 1
        cancelPrefetch()
        contentRevision += 1
        ocrTask?.cancel()
        ocrTask = nil
        ocrTaskRevision = nil
        delayedRefinementTask?.cancel()
        delayedRefinementTask = nil
        windowTrackingTask?.cancel()
        windowTrackingTask = nil
        selectionUpdateTask?.cancel()
        selectionUpdateTask = nil
        windowTrackingAnchor = nil
        latestFrame = nil
        latestCapturedFrame = nil
        pendingAutomaticFrame.clear()
        processingFrames = false
        acceptingFrames = false
        regionBorder?.close()
        regionBorder = nil
        let closingMirror = mirror
        mirror = nil
        closingMirror?.closeForSessionStop()
        selectedScreen = nil
        captureTarget = .allContent
        availableApplications = []
        paused = false
        debugCaptureTranscript?.close()
        debugCaptureTranscript = nil
        await pendingCaptureTransition?.value
        await capture.stop()
        await modeTransition?.value
        await ax.endSession()
    }

    func setMirrorUpdateStyle(_ style: MirrorUpdateStyle) async {
        guard style != mirrorUpdateStyle else { return }
        mirrorUpdateStyle = style
        guard selectedScreen != nil else { return }
        cancelPrefetch()
        contentRevision += 1
        ocrTask?.cancel()
        ocrTask = nil
        ocrTaskRevision = nil
        delayedRefinementTask?.cancel()
        delayedRefinementTask = nil
        lastRefinementEpoch = nil
        guard let frame = latestCapturedFrame else { return }
        lastRealtimeOCR = .now
        scheduleOCR(frame, mode: .realtime, roi: nil)
    }

    var currentTranslationDirection: TranslationDirection { translationDirection }
    var currentProtectsNonSourceText: Bool { protectsNonSourceText }

    func setTranslationDirection(_ direction: TranslationDirection) {
        guard translationDirection != direction else { return }
        translationDirection = direction
        bodyRetention.reset()
        imageOCRProcessor.reset()
        latestAXFrame = nil; latestAXTranslation = nil; latestAXRenderedFrame = nil
        direction.save()
        cancelPrefetch()
        contentRevision += 1
        ocrTask?.cancel(); ocrTask = nil; ocrTaskRevision = nil
        delayedRefinementTask?.cancel(); delayedRefinementTask = nil
        lastRefinementEpoch = nil
        broker.setDirection(direction)
        mirror?.setTranslationDirection(direction)
        onTranslationDirectionChange?(direction)
        if let frame = latestCapturedFrame, acceptingFrames, !modeTransitionInProgress {
            lastRealtimeOCR = .now
            scheduleOCR(frame, mode: .realtime, roi: nil)
        }
    }

    func setProtectsNonSourceText(_ enabled: Bool) {
        guard protectsNonSourceText != enabled else { return }
        protectsNonSourceText = enabled
        bodyRetention.reset()
        imageOCRProcessor.reset()
        latestAXFrame = nil; latestAXTranslation = nil; latestAXRenderedFrame = nil
        TranslationTextProtection.save(enabled)
        cancelPrefetch()
        contentRevision += 1
        ocrTask?.cancel(); ocrTask = nil; ocrTaskRevision = nil
        delayedRefinementTask?.cancel(); delayedRefinementTask = nil
        lastRefinementEpoch = nil
        broker.setProtectsNonSourceText(enabled)
        mirror?.setProtectsNonSourceText(enabled)
        onNonSourceTextProtectionChange?(enabled)
        if let frame = latestCapturedFrame, acceptingFrames, !modeTransitionInProgress {
            lastRealtimeOCR = .now
            scheduleOCR(frame, mode: .realtime, roi: nil)
        }
    }

    func setOCRSettings(_ settings: OCRSettings, mode: OCRMode) {
        guard ocrSettings[mode] != settings else { return }
        ocrSettings[mode] = settings
        settings.save(mode: mode)
        if mode == .realtime, usesAXExtraction {
            let captured = latestCapturedFrame
            invalidateCapturedContent()
            if let captured, acceptingFrames, !paused {
                scheduleAX(captured,origin:.userAction)
            }
        }
    }

    func setRefinementOCRPolicy(_ policy: RefinementOCRPolicy) {
        refinementOCRPolicy = policy
        policy.save()
        delayedRefinementTask?.cancel()
        delayedRefinementTask = nil
        lastRefinementEpoch = nil
    }


    func setMirrorFollowsSelectionSize(_ enabled: Bool) {
        mirrorFollowsSelectionSize = enabled
        mirror?.setFollowSelectionSize(enabled)
        if enabled { mirror?.selectionSizeDidChange(selection.size) }
    }

    func setTargetApplicationTracking(_ enabled: Bool) {
        targetApplicationTracking = enabled
        TargetApplicationTracking.save(enabled)
        if enabled {
            startWindowTrackingIfNeeded()
        } else {
            windowTrackingTask?.cancel()
            windowTrackingTask = nil
        }
    }

    func setMirrorBackgroundOpacity(_ opacity: CGFloat) { mirror?.setBackgroundOpacity(opacity) }
    func setOverlayControlBarOpacity(_ opacity: CGFloat) {
        overlaySettings.inactiveControlBarOpacity = OverlayControlBarOpacity.clamp(opacity)
        overlaySettings.save()
        mirror?.setOverlayPresentationSettings(overlaySettings)
        onOverlayPresentationChange?()
    }
    func setActiveOverlayControlBarOpacity(_ opacity: CGFloat) {
        overlaySettings.activeControlBarOpacity = OverlayControlBarActiveOpacity.clamp(opacity)
        overlaySettings.save()
        mirror?.setOverlayPresentationSettings(overlaySettings)
        onOverlayPresentationChange?()
    }
    func setOverlayIgnoresMouseEvents(_ enabled: Bool) {
        overlaySettings.ignoresMouseEvents = enabled
        overlaySettings.save()
        mirror?.setOverlayPresentationSettings(overlaySettings)
        onOverlayPresentationChange?()
    }

    func refreshShortcutToolTips() {
        mirror?.refreshShortcutToolTips()
    }
    func refreshLocalization() { mirror?.refreshLocalization() }
    func setDisplayMode(
        _ mode: TranslationDisplayMode,
        focusBehavior: DisplayModeFocusBehavior = .preserveKeyWindow
    ) {
        regionBorder?.setChromeVisible(mode == .mirror)
        guard displayMode != mode else { return }
        displayMode = mode
        mode.save()
        if mode == .mirror { setOverlayOriginalView(false) }
        mirror?.setDisplayMode(mode, focusBehavior: focusBehavior)
        onDisplayModeChange?(mode)
    }

    func setOverlayOpacity(_ opacity: CGFloat) {
        let opacity = OverlayOpacity.clamp(opacity)
        overlaySettings.inactiveContentOpacity = opacity
        overlaySettings.save()
        if let mirror {
            mirror.setOverlayPresentationSettings(overlaySettings)
        }
        onOverlayPresentationChange?()
    }

    func setActiveOverlayOpacity(_ opacity: CGFloat) {
        let opacity = OverlayActiveOpacity.clamp(opacity)
        overlaySettings.activeContentOpacity = opacity
        overlaySettings.save()
        mirror?.setOverlayPresentationSettings(overlaySettings)
        onOverlayPresentationChange?()
    }

    func setRegionBorderOpacity(_ opacity: CGFloat) {
        overlaySettings.regionBorderOpacity = RegionBorderOpacity.clamp(opacity)
        overlaySettings.save()
        regionBorder?.setOpacity(overlaySettings.regionBorderOpacity)
        mirror?.setOverlayPresentationSettings(overlaySettings)
        onOverlayPresentationChange?()
    }
    func setMirrorAlwaysOnTop(_ enabled: Bool) { mirror?.setAlwaysOnTop(enabled) }
    func setDebugFeaturesEnabled(_ enabled: Bool) { mirror?.setDebugFeaturesEnabled(enabled) }

    func setCapturePolicy(_ policy: CapturePolicy) async {
        capturePolicy = policy
        guard !captureSuspended else { return }
        do {
            try await capture.update(policy: policy)
        } catch {
            logger.error("Capture policy update failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func setRefreshMode(_ mode: RefreshMode) {
        diagnostics.event("refresh.change", ["mode":mode.rawValue])
        guard refreshMode != mode else { return }
        refreshMode = mode
        mode.save()
        if mode == .manual {
            if paused {
                paused = false
                mirror?.setPaused(false)
            }
            suspendAutomaticProcessing()
        }
        mirror?.setRefreshMode(mode)
        updateRegionBorderPresentation()
        if mode == .automatic, !paused {
            processLatestFrameImmediately(strategy: refinementOCRPolicy.automaticStrategy)
        }
    }

    func setPaused(_ value: Bool) {
        guard !overlayOriginalView else { return }
        diagnostics.event("pause.change", ["paused":String(value)])
        guard paused != value else { return }
        paused = value
        if value { suspendAutomaticProcessing() }
        mirror?.setPaused(value)
        updateRegionBorderPresentation()
        if !value, refreshMode == .automatic {
            processLatestFrameImmediately(strategy: refinementOCRPolicy.automaticStrategy)
        }
    }

    var currentRefreshMode: RefreshMode { refreshMode }
    var isPaused: Bool { paused }
    var isSessionActive: Bool { selectedScreen != nil }
    var isMirrorAlwaysOnTop: Bool { MirrorAlwaysOnTop.load() }
    var isMirrorFollowsSelectionSize: Bool { mirrorFollowsSelectionSize }

    func copyAllText() { mirror?.copyAllText() }
    func copyImage() { mirror?.copyImage() }
    func saveImage() { mirror?.saveImage() }
    func showSearch() { mirror?.showSearch(selectQuery: true) }
    func showApplicationCapturePopup() { mirror?.showApplicationCapturePopup() }
    func isTranslationSessionKeyWindow(_ window: NSWindow?) -> Bool {
        (mirror?.ownsTranslationSessionWindow(window) ?? false)
            || (regionBorder?.ownsInteractionWindow(window) ?? false)
    }
    func performTranslationTextShortcut(_ character: String) -> Bool {
        mirror?.performTranslationTextShortcut(character) ?? false
    }
    func toggleSelectionMode() { _ = mirror?.toggleSelectionMode() }
    func toggleOverlayIgnoresMouseEvents() {
        let enabled = !overlaySettings.ignoresMouseEvents
        setOverlayIgnoresMouseEvents(enabled)
    }
    func toggleModeSpecificDisplayControl() {
        switch displayMode {
        case .mirror:
            let enabled = !isMirrorAlwaysOnTop
            setMirrorAlwaysOnTop(enabled)
            MirrorAlwaysOnTop.save(enabled)
        case .overlay:
            toggleOverlayIgnoresMouseEvents()
        }
    }
    func toggleOCRDebugOverlay() { mirror?.toggleOCRDebugOverlay() }
    func scaleMirrorContent(by factor: CGFloat) { mirror?.scaleContent(by: factor) }
    func restoreMirrorContentSize() { mirror?.restoreOriginalSize() }
    func fitMirrorWindowToContent() { mirror?.fitWindowToDisplayedContent() }
    func toggleMirrorDocking(_ state: MirrorDockingState) {
        mirror?.performDockingShortcut(state)
    }

    private func updateRegionBorderPresentation() {
        let state: RegionBorderController.PresentationState
        if overlayOriginalView {
            state = .originalView
        } else if refreshMode == .manual {
            state = .manual
        } else {
            state = paused ? .automaticPaused : .automatic
        }
        regionBorder?.setPresentationState(state)
        // The drag-time dock preview shares the border color so it reads as
        // part of the same selection UI.
        mirror?.setDockPreviewColor(regionPresentationColor(for: state))
    }

    func translateImmediately() {
        guard selectedScreen != nil else { return }
        processLatestFrameImmediately(strategy: refinementOCRPolicy.manualStrategy)
    }

    func activateMirrorWindow() {
        mirror?.activateFromGlobalHotKey()
    }

    private func processLatestFrameImmediately(strategy: OCRExecutionStrategy) {
        guard !captureSuspended, let frame = latestCapturedFrame, ocrTask == nil else { return }
        latestFrame = nil
        pendingAutomaticFrame.clear()
        _ = prepareFrame(frame)
        PresentationTrace.shared.record("manual.request", [
            "frame": frame.id, "epoch": stabilityEpoch
        ])
        delayedRefinementTask?.cancel()
        delayedRefinementTask = nil
        lastRealtimeOCR = .now
        scheduleOCR(
            frame, mode: initialOCRMode(for: strategy), roi: nil,
            followWithRefinement: strategy == .realtimeThenRefinement,
            origin: .userAction
        )
    }

    private func recordDebugCaptureText(
        frameID: UInt64,
        mode: OCRMode,
        recognizedLines: [RecognizedLine],
        translatableLines: [RecognizedLine],
        translations: [TranslationResult]
    ) {
        guard let debugCaptureTranscript else { return }
        let translationByID = Dictionary(uniqueKeysWithValues: translations.map {
            ($0.line.id, $0.translated)
        })
        let translatableIDs = Set(translatableLines.map(\.id))
        let records = recognizedLines.map { line -> DebugCaptureTranscriptLine in
            let translatedText = translationByID[line.id]
            let status: DebugCaptureTranscriptLine.TranslationStatus
            if translatedText != nil {
                status = .translated
            } else if translatableIDs.contains(line.id) {
                status = .translationFailed
            } else {
                status = .notSourceLanguage
            }
            let rect = line.normalizedRect
            return DebugCaptureTranscriptLine(
                id: line.id.uuidString,
                sourceText: line.sourceText,
                translatedText: translatedText,
                translationStatus: status,
                confidence: Double(line.confidence),
                rect: [Double(rect.minX), Double(rect.minY), Double(rect.width), Double(rect.height)]
            )
        }
        debugCaptureTranscript.record(frameID: frameID, mode: mode, lines: records)
    }

    func diagnosticSnapshot() -> DiagnosticSnapshot {
        refreshDiagnosticState()
        var code:SecCode?
        if SecCodeCopySelf([], &code)==errSecSuccess,let code {
            var info:CFDictionary?
            var staticCode:SecStaticCode?
            if SecCodeCopyStaticCode(code,[],&staticCode)==errSecSuccess,let staticCode,SecCodeCopySigningInformation(staticCode,SecCSFlags(rawValue:kSecCSSigningInformation),&info)==errSecSuccess,let fields=info as? [String:Any] {
                diagnostics.update(["signingIdentifier":fields[kSecCodeInfoIdentifier as String] as? String ?? "unknown","signingTeam":fields[kSecCodeInfoTeamIdentifier as String] as? String ?? "unknown"])
                if let digest=fields[kSecCodeInfoUnique as String] as? Data { diagnostics.update(["codeDirectoryHash":digest.map { String(format:"%02x",$0) }.joined()]) }
            }
        }
        return diagnostics.snapshot()
    }
    func exportDiagnostics() {
        DiagnosticExportController.shared.present(diagnosticSnapshot())
    }
    private func refreshDiagnosticState() {
        var state: [String:String] = [
            "appVersion":Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            "build":Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
            "sourceRevision":Bundle.main.infoDictionary?["RearviewSourceRevision"] as? String ?? "unknown",
            "buildDate":Bundle.main.infoDictionary?["RearviewBuildDate"] as? String ?? "unknown",
            "bundleID":Bundle.main.bundleIdentifier ?? "unknown",
            "os":ProcessInfo.processInfo.operatingSystemVersionString,
            "architecture":Self.diagnosticArchitecture,
            "requestedMode":textExtractionMode == .ax ? "ax":"ocr", "effectiveMode":usesAXExtraction ? "ax":"ocr",
            "accessibilityTrusted":String(AXIsProcessTrusted()), "screenCapturePreflight":String(CGPreflightScreenCaptureAccess()),
            "translationDirection":translationDirection.rawValue,"protectsNonSourceText":String(protectsNonSourceText),
            "generation":String(generation),"revision":String(contentRevision),"task":String(ocrTaskSequence),
            "paused":String(paused),"refreshMode":refreshMode.rawValue,"displayMode":displayMode.rawValue,
            "createsOutputWindow":String(createsOutputWindow),"mirrorWindowExists":String(mirror != nil),"mirrorWindowVisible":String(mirror?.isVisible ?? false),"mirrorWindowFrame":String(describing:mirror?.frame),
            "updateStyle":String(describing:mirrorUpdateStyle),"acceptingFrames":String(acceptingFrames),"workInFlight":String(ocrTask != nil),
            "targetBundleID":captureTarget.application?.bundleIdentifier ?? "all",
            "captureFPS":String(capturePolicy.targetFPS),"ocrIntervalMilliseconds":String(capturePolicy.realtimeOCRIntervalMilliseconds),
            "axIntervalMilliseconds":String(capturePolicy.axRefreshIntervalMilliseconds),
            "refinement":String(describing:refinementOCRPolicy),"selection":String(describing:selection),
            "screenFrame":String(describing:selectedScreen?.frame),"screenScale":String(describing:selectedScreen?.backingScaleFactor),
            "overlaySettings":String(describing:overlaySettings),"tracking":String(targetApplicationTracking),
            "ocrRealtime":String(describing:ocrSettings[.realtime]),"ocrRefinement":String(describing:ocrSettings[.refinement])]
        if let broker=broker as? TranslationBroker {
            state["translationSessionReady"]=String(broker.isReadyForTranslation)
            state["translationPreparationFailed"]=String(broker.preparationError != nil)
            if let error=broker.preparationError { diagnostics.update([:],content:["translationPreparationError":error]) }
        }
        if let app=captureTarget.application,let process=NSRunningApplication(processIdentifier:app.processID),let url=process.bundleURL {
            state["targetVersion"]=Bundle(url:url)?.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        }
        diagnostics.update(state,content:["appPath":Bundle.main.bundlePath])
    }
    private static var diagnosticArchitecture:String {
#if arch(arm64)
        "arm64"
#else
        "x86_64"
#endif
    }
    private func beginDiagnosticFrame(_ frame:FrameEnvelope,task:UInt64) -> UUID? {
        diagnostics.update(["generation":String(generation),"revision":String(contentRevision),"task":String(task)])
        let id=diagnostics.startFrame(image:frame.image,frameID:frame.id,receivedAt:frame.receivedAt,generation:generation,revision:contentRevision,task:task,mode:usesAXExtraction ? "ax":"ocr")
        diagnostics.mark("frame.geometry",id:id,["selection":String(describing:selection),"screenFrame":String(describing:selectedScreen?.frame),"screenScale":String(describing:selectedScreen?.backingScaleFactor),"targetBundleID":captureTarget.application?.bundleIdentifier ?? "all","targetProcessID":String(captureTarget.application?.processID ?? 0),"targetWindowID":String(captureTarget.application?.anchorWindowID ?? 0)])
        return id
    }
    private func recordAXAccessDiagnostic(_ access:AXCollectionDiagnostics?,requestID:UUID,id:UUID?) {
        guard let access else { diagnostics.omit("ax-access:provider_unavailable",to:id);return }
        // A cancelled traversal may finish after a newer one was queued. Never attach that newer traversal's diagnostics.
        guard access.fields["requestID"] == nil || access.fields["requestID"] == requestID.uuidString else {
            diagnostics.omit("ax-access:superseded_request",to:id);return
        }
        diagnostics.add("ax-access.json",document:.init(access,estimatedBytes:16384),to:id)
        diagnostics.mark("ax.access",id:id,access.fields.mapKeysWithAXPrefix())
    }
    private func recordAXDiagnostic(_ result:AXExtractionSnapshot,id:UUID?) {
        for (name,data) in [("ax-nodes.json",result.nodes),("ax-selected.json",result.selected),("ax-paragraphs.json",result.paragraphs),("ax-metadata.json",result.metadata)] {
            diagnostics.add(name,document:.init(data:data),to:id)
        }
        if let metadata=(try? JSONSerialization.jsonObject(with:result.metadata)) as? [String:Any] {
            var counts:[String:String]=[:]
            for key in ["totalAXCalls","rangeCalls","rangeElapsed","rangeLimitReached","truncated","elapsed","initializationSeconds","windowMappingSeconds"] {
                if let value=metadata[key] as? NSNumber { counts[key]=value.stringValue }
            }
            diagnostics.mark("ax.counts",id:id,counts)
        }
        diagnostics.mark("ax.extracted",id:id,["nodes":String(result.observations.count),"paragraphs":String(result.paragraphUnits.count),"status":result.status.rawValue])
    }
    private func recordAXTranslationDiagnostic(_ value:AXTranslatedFrame,id:UUID?) {
        let estimate=value.entries.reduce(0) { $0+$1.source.utf8.count*12+4096 }
        diagnostics.add("ax-translations.json",document:.init(value.entries,estimatedBytes:estimate),to:id)
        diagnostics.add("image-ocr.json",document:.init(value.imageOCR.diagnostics,estimatedBytes:estimate),to:id)
        if let reuse=value.bodyReuseDiagnostic { diagnostics.add("body-reuse.json",document:.init(reuse,estimatedBytes:4096),to:id) }
        if let retained=value.retainedBody {
            recordRetainedDiagnostic(retained,id:id)
        }
    }
    private func recordRetainedDiagnostic(_ value:AXBodyReuse,id:UUID?) {
        let snapshot=value.body.frame.snapshot
        for (name,data) in [("retained-nodes.json",snapshot.nodes),("retained-selected.json",snapshot.selected),("retained-paragraphs.json",snapshot.paragraphs),("retained-metadata.json",snapshot.metadata)] {
            diagnostics.add(name,document:.init(data:data),to:id)
        }
        diagnostics.image("retained-source.png",value.body.frame.image,to:id)
        diagnostics.add("retained-translations.json",document:.init(value.body.entries,estimatedBytes:value.body.entries.count*8192),to:id)
        diagnostics.add("retained-regions.json",document:.init(value.regions,estimatedBytes:value.regions.count*128),to:id)
        diagnostics.add("retained-panels.json",document:.init(value.panels,estimatedBytes:value.panels.count*128),to:id)
    }
    private func recordOCRDiagnostic(_ batch:OCRService.RecognitionBatch,mode:OCRMode,roi:CGRect?,purpose:OCRDiagnosticPurpose,id:UUID?,seconds:Double) {
        let estimate=batch.lines.reduce(0) { $0+$1.sourceText.utf8.count*4+4096 }+batch.confidenceRejected.count*2048
        diagnostics.add("ocr-\(mode.rawValue)-\(purpose.rawValue).json",document:.init(DiagnosticOCRBatch(batch,mode:mode,roi:roi,direction:translationDirection),estimatedBytes:estimate),to:id)
        diagnostics.mark("ocr.finished",id:id,["ocrMode":mode.rawValue,"raw":String(batch.rawObservationCount),"accepted":String(batch.lines.count),"missingCandidate":String(batch.missingCandidateCount),"confidenceRejected":String(batch.confidenceRejected.count),"seconds":String(seconds)])
    }

    private func display(_ original: MirrorFrame) {
        guard !captureSuspended else { return }
        if !original.isAXScrollPreview { scrollPreviewFrameID = nil }
        var frame=original
        let id=diagnostics.find(frameID:frame.frameID,generation:generation,revision:contentRevision)
        if let id { frame.diagnosticContext=DiagnosticFrameContext(diagnostics,id:id) }
        diagnostics.submitted(frame,id:id)
        mirror?.display(frame)
        outputSink?.display(frame)
    }

    private func showProcessingStatus(
        _ status: MirrorProcessingStatus, frameID: UInt64,
        origin: MirrorStatusOrigin = .automatic
    ) {
        diagnostics.update(["processingStatus":String(describing:status)])
        diagnostics.event("processing.status",frame:diagnostics.find(frameID:frameID,generation:generation,revision:contentRevision),["status":String(describing:status),"frameID":String(frameID)])
        mirror?.showProcessingStatus(status, frameID: frameID, origin: origin)
        outputSink?.showProcessingStatus(status, frameID: frameID)
    }

    private func cancelProcessingStatus() {
        diagnostics.update(["processingStatus":"cancelled"])
        diagnostics.event("processing.cancel")
        mirror?.cancelProcessingStatus()
        outputSink?.cancelProcessingStatus()
    }

    private func initialOCRMode(for strategy: OCRExecutionStrategy) -> OCRMode {
        strategy == .refinementImmediately ? .refinement : .realtime
    }

    private func suspendAutomaticProcessing() {
        bodyRetention.reset()
        imageOCRProcessor.reset()
        latestAXFrame = nil
        latestAXTranslation = nil; latestAXRenderedFrame = nil
        cancelPrefetch()
        contentRevision += 1
        ocrTask?.cancel()
        ocrTask = nil
        ocrTaskRevision = nil
        delayedRefinementTask?.cancel()
        delayedRefinementTask = nil
        latestFrame = nil
        pendingAutomaticFrame.clear()
        processingFrames = false
        cancelProcessingStatus()
    }

    private func createOutputWindow() {
        guard let selectedScreen else { return }
        if regionBorder == nil {
            let border = RegionBorderController(
                selection: selection, screen: selectedScreen,
                opacity: overlaySettings.regionBorderOpacity
            )
            border.onChange = { [weak self] rect, screen, change, finished in
                guard let self else { return }
                self.handleInteractiveSelectionChange(
                    rect: rect, screen: screen, change: change,
                    finished: finished, synchronizeBorder: false
                )
            }
            // The border's end-translation button ends the session exactly
            // like the control bar's close button: the mirror window close
            // flow (or a direct stop when the window is gone) tears down the
            // whole session.
            border.onEndTranslation = { [weak self] in
                guard let self else { return }
                if let mirror = self.mirror {
                    mirror.close()
                } else {
                    Task { @MainActor [weak self] in await self?.stop() }
                }
            }
            regionBorder = border
            border.setChromeVisible(displayMode == .mirror)
            updateRegionBorderPresentation()
        }
        let window = TranslationMirrorWindow(
            selection: selection,
            screen: selectedScreen,
            backgroundOpacity: MirrorBackgroundOpacity.load(),
            displayMode: displayMode,
            overlaySettings: overlaySettings,
            initialDockingState: mirrorDockingState
        )
        window.onBackgroundOpacityChange = { opacity in
            MirrorBackgroundOpacity.save(opacity)
        }
        window.onOverlayPresentationChange = { [weak self] settings in
            guard let self else { return }
            let previous = self.overlaySettings
            self.overlaySettings = settings.normalized()
            self.overlaySettings.save()
            self.regionBorder?.setOpacity(self.overlaySettings.regionBorderOpacity)
            if previous != self.overlaySettings { self.onOverlayPresentationChange?() }
        }
        window.onDisplayModeChange = { [weak self] mode in
            guard let self else { return }
            self.displayMode = mode
            if mode == .mirror { self.setOverlayOriginalView(false) }
            self.regionBorder?.setChromeVisible(mode == .mirror)
            mode.save()
            self.onDisplayModeChange?(mode)
        }
        window.onTranslationDirectionChange = { [weak self] direction in
            self?.setTranslationDirection(direction)
        }
        window.onNonSourceTextProtectionChange = { [weak self] enabled in
            self?.setProtectsNonSourceText(enabled)
        }
        window.onUserClose = { [weak self] in
            Task { @MainActor [weak self] in await self?.stop() }
        }
        window.onFollowSelectionSizeChange = { [weak self] enabled in
            MirrorFollowsSelectionSize.save(enabled)
            self?.setMirrorFollowsSelectionSize(enabled)
        }
        window.onDockingStateChange = { [weak self] state in
            guard let self else { return }
            self.mirrorDockingState = state
            state.save()
            self.regionBorder?.setMirrorDocking(state, seamFrame: self.mirror?.dockingSeamFrame)
        }
        window.onDockingGeometryChange = { [weak self] state, seamFrame in
            self?.regionBorder?.setMirrorDocking(state, seamFrame: seamFrame)
        }
        window.onApplicationCaptureChange = { [weak self] application in
            Task { @MainActor [weak self] in await self?.setApplicationCapture(application) }
        }
        window.onApplicationListRequest = { [weak self] in
            Task { @MainActor [weak self] in await self?.refreshApplicationList() }
        }
        window.onRefreshModeChange = { [weak self] mode in self?.setRefreshMode(mode) }
        window.onOriginalViewToggle = { [weak self] in self?.toggleOverlayOriginalView() }
        window.onPauseChange = { [weak self] paused in self?.setPaused(paused) }
        window.onImmediateTranslation = { [weak self] in self?.translateImmediately() }
        window.onExtractionModeToggle = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                await self.setTextExtractionMode(self.textExtractionMode == .ax ? .ocr : .ax)
            }
        }
        window.setExtractionMode(textExtractionMode)
        window.setTranslationDirection(translationDirection)
        window.setProtectsNonSourceText(protectsNonSourceText)
        window.onOverlaySelectionDrag = { [weak self] rect, screen, change, finished in
            guard let self else { return }
            self.handleInteractiveSelectionChange(
                rect: rect, screen: screen, change: change,
                finished: finished, synchronizeBorder: true
            )
        }
        window.onOverlayControlBarGeometryChange = { [weak self] frame, docking in
            self?.regionBorder?.setOverlayControlBarFrame(frame, docking: docking)
        }
        window.onOpenSettings = { [weak self] in self?.onOpenSettings?() }
        window.onTextSelectionBegin = { [weak self] in
            guard self?.refreshMode == .automatic else { return }
            self?.setPaused(true)
        }
        window.setFollowSelectionSize(mirrorFollowsSelectionSize)
        window.setRefreshMode(refreshMode)
        window.setPaused(paused)
        updateTargetControl(window)
        mirror = window
        // The window is created after the border's initial presentation
        // update, so push the current border color onto it now.
        updateRegionBorderPresentation()
        let requestedDockingState = mirrorDockingState
        mirrorDockingState = window.currentDockingState
        if mirrorDockingState == requestedDockingState { mirrorDockingState.save() }
        regionBorder?.setMirrorDocking(mirrorDockingState, seamFrame: window.dockingSeamFrame)
    }

    private func handleInteractiveSelectionChange(
        rect: CGRect, screen: NSScreen, change: RegionBorderController.Change,
        finished: Bool, synchronizeBorder: Bool
    ) {
        if !selectionInteractionActive {
            selectionInteractionActive = true
            windowTrackingTask?.cancel()
            windowTrackingTask = nil
            if windowTrackingAnchor?.missingSince != nil {
                Task { @MainActor [weak self] in
                    await self?.releaseApplicationTarget()
                }
            }
        }
        selection = rect
        selectedScreen = screen
        regionBorder?.setScreen(screen)
        if synchronizeBorder { regionBorder?.setSelection(rect) }
        switch change {
        case let .move(delta):
            mirror?.selectionDidMove(delta)
        case let .resize(edge):
            mirror?.selectionSizeDidChange(
                rect.size, resizing: edge,
                followsSelectionSize: mirrorFollowsSelectionSize
            )
        }
        mirror?.setSelectionFrame(rect)
        if finished { mirror?.finishSelectionTransform() }
        guard finished else { return }
        selectionInteractionActive = false
        scheduleSelectionUpdate(rect, screen: screen, reevaluateTarget: false)
    }

    private func scheduleSelectionUpdate(
        _ rect: CGRect, screen: NSScreen, reevaluateTarget: Bool
    ) {
        let previousTask = selectionUpdateTask
        selectionUpdateTask = Task { @MainActor [weak self] in
            _ = await previousTask?.result
            guard !Task.isCancelled else { return }
            await self?.applySelection(
                rect, screen: screen, reevaluateTarget: reevaluateTarget,
                rebuildTrackingAnchor: true
            )
        }
    }

    func applySelection(
        _ rect: CGRect, screen: NSScreen? = nil, reevaluateTarget: Bool,
        trackingGeneration: Int? = nil, trackingRevision: Int? = nil,
        rebuildTrackingAnchor: Bool = false
    ) async {
        guard let selectedScreen = screen ?? selectedScreen else { return }
        guard trackingGeneration == nil || trackingGeneration == generation else { return }
        guard trackingRevision == nil || trackingRevision == contentRevision else { return }
        let previousSelection = selection
        let previousScreen = self.selectedScreen
        self.selectedScreen = selectedScreen
        selection = rect
        invalidateCapturedContent()
        let activeRevision = contentRevision
        let epoch = captureEpoch
        acceptingFrames = false
        do {
            if !captureSuspended {
                try await capture.updateRegion(
                    selection: rect, screenFrame: selectedScreen.frame,
                    backingScale: selectedScreen.backingScaleFactor,
                    displayID: Self.displayID(for: selectedScreen)
                )
            }
        } catch {
            guard captureEpoch == epoch else { return }
            logger.error("Capture region update failed: \(error.localizedDescription, privacy: .public)")
            let ownsState = trackingGeneration == nil
                || (generation == trackingGeneration && contentRevision == activeRevision)
            if ownsState {
                self.selectedScreen = previousScreen
                selection = previousSelection
                regionBorder?.setScreen(previousScreen ?? selectedScreen)
                regionBorder?.setSelection(previousSelection)
                mirror?.setSelectionFrame(previousSelection)
            }
            acceptingFrames = true
            return
        }
        guard captureEpoch == epoch else { return }
        guard generation == (trackingGeneration ?? generation),
              trackingRevision == nil || activeRevision == contentRevision else {
            acceptingFrames = true
            return
        }
        regionBorder?.setScreen(selectedScreen)
        regionBorder?.setSelection(rect)
        if previousSelection.size != rect.size {
            mirror?.selectionSizeDidChange(rect.size, followsSelectionSize: mirrorFollowsSelectionSize)
        }
        mirror?.setSelectionFrame(rect)
        acceptingFrames = !captureSuspended
        if rebuildTrackingAnchor, case .application = captureTarget, !selectionInteractionActive {
            startWindowTrackingIfNeeded()
        }
    }

    func setApplicationCapture(_ application: CaptureApplication?) async {
        diagnostics.event("target.change", ["target":application?.bundleIdentifier ?? "all"])
        guard let selectedScreen else { return }
        let target = application.map(CaptureTarget.application) ?? .allContent
        guard target != captureTarget else { updateTargetControl(); return }
        failureDeduplicator.reset()
        failureNotice.dismiss()
        modeTransitionID += 1
        modeTransitionInProgress = false
        pendingModeRefresh = false
        windowTrackingTask?.cancel()
        windowTrackingTask = nil
        windowTrackingAnchor = nil
        selectionUpdateTask?.cancel()
        selectionUpdateTask = nil
        invalidateCapturedContent()
        acceptingFrames = false
        let epoch = captureEpoch
        await modeTransition?.value
        await ax.endSession()
        guard captureEpoch == epoch, isSessionActive else { return }
        do {
            try await updateCaptureTarget(target, on: selectedScreen)
        } catch {
            logger.error("Capture target update failed: \(error.localizedDescription, privacy: .public)")
            updateTargetControl()
        }
        guard captureEpoch == epoch else { return }
        acceptingFrames = !captureSuspended
        startWindowTrackingIfNeeded()
    }

    private func startWindowTrackingIfNeeded() {
        windowTrackingTask?.cancel()
        windowTrackingTask = nil
        guard case .application(let application) = captureTarget else {
            windowTrackingAnchor = nil
            return
        }
        if targetApplicationTracking {
            rebuildWindowTrackingAnchor()
        } else {
            windowTrackingAnchor = nil
        }

        windowTrackingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, let self else { return }
                await self.updateTrackedWindowPosition(application: application)
            }
        }
    }

    private func rebuildWindowTrackingAnchor() {
        guard targetApplicationTracking,
              case .application(let application) = captureTarget,
              let windowID = application.anchorWindowID,
              let selectedScreen,
              let displayID = Self.displayID(for: selectedScreen) else {
            windowTrackingAnchor = nil
            windowTrackingTask = nil
            return
        }

        guard let initialFrame = application.anchorWindowFrame else {
            windowTrackingAnchor = nil
            return
        }
        let candidate = WindowTrackingAnchor(
            processID: application.processID, windowID: windowID, insets: nil,
            lastKnownWindowFrame: initialFrame, missingSince: nil
        )
        guard case .visible(let windowFrame) = lookupTrackedWindow(anchor: candidate) else {
            windowTrackingAnchor = candidate
            return
        }
        windowTrackingAnchor = makeWindowTrackingAnchor(
            candidate, frame: windowFrame, screen: selectedScreen, displayID: displayID
        )
    }

    private func makeWindowTrackingAnchor(
        _ anchor: WindowTrackingAnchor, frame: CGRect,
        screen: NSScreen, displayID: CGDirectDisplayID
    ) -> WindowTrackingAnchor {
        let rect = screenCaptureRect(
            for: selection, screenFrame: screen.frame, displayBounds: CGDisplayBounds(displayID)
        )
        return WindowTrackingAnchor(
            processID: anchor.processID, windowID: anchor.windowID,
            insets: WindowTrackingInsets(captureRect: rect, windowFrame: frame),
            lastKnownWindowFrame: frame, missingSince: nil
        )
    }

    private func updateTrackedWindowPosition(application: CaptureApplication) async {
        guard case .application = captureTarget,
              application.processID == captureTarget.application?.processID else {
            return
        }
        guard let runningApplication = NSRunningApplication(processIdentifier: application.processID),
              !runningApplication.isTerminated else {
            await releaseApplicationTarget()
            return
        }
        guard let anchor = windowTrackingAnchor else { return }
        switch lookupTrackedWindow(anchor: anchor) {
        case .queryFailed:
            return
        case .unavailable:
            await handleUnavailableTrackedWindow()
        case .visible(let windowFrame):
            guard var anchor = windowTrackingAnchor,
                  let selectedScreen,
                  let selectedDisplayID = Self.displayID(for: selectedScreen) else { return }
            guard let insets = anchor.insets else {
                windowTrackingAnchor = makeWindowTrackingAnchor(
                    anchor, frame: windowFrame, screen: selectedScreen, displayID: selectedDisplayID
                )
                return
            }
            anchor.missingSince = nil
            anchor.lastKnownWindowFrame = windowFrame
            windowTrackingAnchor = anchor
            let displays = NSScreen.screens.compactMap { screen -> WindowTrackingDisplay? in
                guard let displayID = Self.displayID(for: screen) else { return nil }
                return WindowTrackingDisplay(displayID: displayID, bounds: CGDisplayBounds(displayID))
            }
            guard let projection = projectTrackedSelection(
                insets: insets,
                windowFrame: windowFrame,
                displays: displays,
                preferredDisplayID: selectedDisplayID
            ),
            let newScreen = NSScreen.screens.first(where: {
                Self.displayID(for: $0) == projection.displayID
            }) else { return }
            let newCaptureRect = projection.captureRect
            let newSelection = appKitSelectionRect(
                for: newCaptureRect,
                screenFrame: newScreen.frame,
                displayBounds: CGDisplayBounds(projection.displayID)
            )
            guard abs(newSelection.minX - selection.minX) > 0.01
                    || abs(newSelection.minY - selection.minY) > 0.01
                    || abs(newSelection.width - selection.width) > 0.01
                    || abs(newSelection.height - selection.height) > 0.01
                    || projection.displayID != selectedDisplayID else { return }
            let activeGeneration = generation
            let activeRevision = contentRevision
            let previousTask = selectionUpdateTask
            let updateTask = Task { @MainActor [weak self] in
                _ = await previousTask?.result
                guard !Task.isCancelled, let self, self.targetApplicationTracking,
                      !self.selectionInteractionActive else { return }
                await self.applySelection(
                    newSelection,
                    screen: newScreen,
                    reevaluateTarget: false,
                    trackingGeneration: activeGeneration,
                    trackingRevision: activeRevision,
                    rebuildTrackingAnchor: false
                )
            }
            selectionUpdateTask = updateTask
            await updateTask.value
        }
    }

    private func lookupTrackedWindow(anchor: WindowTrackingAnchor) -> TrackedWindowLookup {
        guard let windowInfo = CGWindowListCopyWindowInfo(
            [.excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return .queryFailed }
        guard let currentEntry = windowInfo.first(where: {
            ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == anchor.windowID
                && ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == Int32(anchor.processID)
        }),
        let bounds = currentEntry[kCGWindowBounds as String] as? [String: Any],
        let currentFrame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else {
            return .unavailable
        }
        let isOnscreen = (currentEntry[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
        return isOnscreen ? .visible(currentFrame) : .unavailable
    }

    private func handleUnavailableTrackedWindow() async {
        guard var anchor = windowTrackingAnchor else { return }
        let now = ContinuousClock.now
        if anchor.missingSince == nil { anchor.missingSince = now }
        windowTrackingAnchor = anchor
        guard let missingSince = anchor.missingSince,
              missingSince.duration(to: now) >= .seconds(2) else { return }
        await releaseApplicationTarget()
    }

    private func releaseApplicationTarget() async {
        guard case .application = captureTarget else { return }
        windowTrackingTask?.cancel()
        windowTrackingTask = nil
        windowTrackingAnchor = nil
        await setApplicationCapture(nil)
    }

    private func refreshApplicationList() async {
        guard let selectedScreen else { return }
        do {
            availableApplications = try await targetResolver.applications(for: selection, on: selectedScreen)
            updateTargetControl()
        } catch {
            logger.error("Capture application list failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func updateCaptureTarget(_ target: CaptureTarget, on screen: NSScreen) async throws {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            throw TranslatorError.noDisplay
        }
        let epoch = captureEpoch
        if !captureSuspended {
            try await capture.updateTarget(displayID: number.uint32Value, target: target)
        }
        guard captureEpoch == epoch else { return }
        if captureSuspended { contentRevision += 1 }
        captureTarget = target
        refreshDiagnosticState()
        updateTargetControl()
    }

    private func invalidateCapturedContent() {
        diagnostics.event("content.invalidate", ["generation":String(generation),"revision":String(contentRevision)])
        bodyRetention.reset()
        imageOCRProcessor.reset()
        latestAXFrame = nil
        latestAXTranslation = nil; latestAXRenderedFrame = nil
        cancelPrefetch()
        contentRevision += 1
        ocrTask?.cancel()
        ocrTask = nil
        ocrTaskRevision = nil
        delayedRefinementTask?.cancel()
        delayedRefinementTask = nil
        latestFrame = nil
        latestCapturedFrame = nil
        pendingAutomaticFrame.clear()
        changes.reset()
        cancelProcessingStatus()
    }

    private func updateTargetControl(_ window: TranslationMirrorWindow? = nil) {
        let targetWindow = window ?? mirror
        targetWindow?.setApplicationCapture(
            applications: availableApplications, selected: captureTarget.application
        )
    }

    private func receive(_ image: CGImage, frameID: UInt64, receivedAt: UInt64) {
        guard acceptingFrames, !captureSuspended else { return }
        let received = FrameEnvelope(image: image, id: frameID, receivedAt: receivedAt)
        latestCapturedFrame = received
        diagnostics.event("capture.received", ["frameID":String(frameID),"receivedAt":String(receivedAt),"width":String(image.width),"height":String(image.height)])
        if diagnostics.current == nil { _ = diagnostics.startFrame(image:image,frameID:frameID,receivedAt:receivedAt,generation:generation,revision:contentRevision,task:ocrTaskSequence,mode:usesAXExtraction ? "ax":"ocr") }
        guard !modeTransitionInProgress else { return }
        if pendingModeRefresh {
            pendingModeRefresh = false
            translateImmediately()
            return
        }
        guard refreshMode == .automatic, !paused else { return }
        if latestFrame != nil { PerformanceProfiler.shared.increment("frame.overwritten") }
        latestFrame = received
        if !usesAXExtraction, benchmarkDiagnostics, !initialComparisonStarted, frameID >= 3 {
            initialComparisonStarted = true
            scheduleInitialOCRComparison(received)
        }
        guard !processingFrames else { return }
        processingFrames = true
        let activeGeneration = generation
        Task { [weak self] in await self?.processFrames(generation: activeGeneration) }
    }

    private func processFrames(generation activeGeneration: Int) async {
        while generation == activeGeneration, let frame = latestFrame {
            latestFrame = nil
            processMirrorFrame(frame)
        }
        processingFrames = false
        if let frame = latestFrame, generation == activeGeneration {
            latestFrame = nil
            receive(frame.image, frameID: frame.id, receivedAt: frame.receivedAt)
        }
    }

    private func prepareFrame(_ frame: FrameEnvelope) -> FrameChange {
        let change = changes.analyze(frame.image)
        diagnostics.event("change.analyzed", ["frameID":String(frame.id),"ratio":String(change.changedRatio),"kind":String(describing:change.motion.kind)])
        PerformanceProfiler.shared.increment("change.tilesPercent", by: Int(change.changedRatio * 100))
        if change.changedRatio > 0 {
            lastMotion = .now
            stabilityEpoch &+= 1
            PresentationTrace.shared.record("visual.change", [
                "frame": frame.id, "epoch": stabilityEpoch,
                "ratio": change.changedRatio,
                "motion": String(describing: change.motion.kind),
                "inFlight": ocrTask != nil
            ])
        }
        return change
    }

    private func processMirrorFrame(_ frame: FrameEnvelope) {
        let change = prepareFrame(frame)
        let hasVisualChange = change.changedRatio > 0
        let now = ContinuousClock.now
        if hasVisualChange {
            cancelPrefetch()
            if change.motion.kind == .sceneChange {
                pendingAutomaticFrame.clear()
                delayedRefinementTask?.cancel()
                delayedRefinementTask = nil
                if ocrTask != nil {
                    cancelPrefetch()
                    contentRevision += 1
                    ocrTask?.cancel()
                    ocrTask = nil
                    ocrTaskRevision = nil
                    cancelProcessingStatus()
                }
                lastRealtimeOCR = now
                scheduleOCR(
                    frame, mode: initialOCRMode(for: refinementOCRPolicy.automaticStrategy), roi: nil
                )
                return
            }
            guard lastRealtimeOCR.duration(to: now) >= capturePolicy.refreshInterval(usesAX: usesAXExtraction) else {
                diagnostics.event("frame.queued", ["frameID":String(frame.id)])
                pendingAutomaticFrame.store(frame)
                return
            }
            guard ocrTask == nil else {
                diagnostics.event("frame.queued", ["frameID":String(frame.id)])
                pendingAutomaticFrame.store(frame)
                PerformanceProfiler.shared.increment("ocr.realtimeSkippedInFlight")
                return
            }
            pendingAutomaticFrame.clear()
            lastRealtimeOCR = now
            scheduleOCR(frame, mode: initialOCRMode(for: refinementOCRPolicy.automaticStrategy), roi: nil)
            return
        }

        if pendingAutomaticFrame.value != nil {
            // The visual change is already the detector baseline. Keep the newest
            // equivalent frame until the OCR interval and in-flight task allow it.
            pendingAutomaticFrame.store(frame)
            _ = processPendingAutomaticFrameIfPossible()
            return
        }

        guard !usesAXExtraction, refinementOCRPolicy.automaticStrategy == .realtimeThenRefinement,
              lastMotion.duration(to: now) >= refinementOCRPolicy.delay,
              lastRefinementEpoch != stabilityEpoch else { return }
        switch decideRefinementOCR(
            observationCount: lastRealtimeObservationCount, japaneseLines: lastRealtimeLines, policy: refinementOCRPolicy
        ) {
        case .skipHighConfidence:
            lastRefinementEpoch = stabilityEpoch
            PerformanceProfiler.shared.increment("ocr.refinementSkippedHighConfidence")
        case .fullFrameFallback, .lowConfidenceROI:
            guard ocrTask == nil else {
                PerformanceProfiler.shared.increment("ocr.refinementSkippedInFlight")
                return
            }
            lastRefinementEpoch = stabilityEpoch
            scheduleOCR(frame, mode: .refinement, roi: nil)
        }
    }

    private func scheduleOCR(
        _ frame: FrameEnvelope, mode: OCRMode, roi: CGRect?, followWithRefinement: Bool = false,
        origin: MirrorStatusOrigin = .automatic
    ) {
        guard !modeTransitionInProgress else { return }
        if usesAXExtraction { scheduleAX(frame, origin:origin); return }
        let activeGeneration = generation
        let activeRevision = contentRevision
        ocrTaskSequence &+= 1
        let taskSequence = ocrTaskSequence
        let diagnosticID = beginDiagnosticFrame(frame,task:taskSequence)
        PresentationTrace.shared.record("schedule", [
            "frame": frame.id, "mode": mode.rawValue,
            "origin": String(describing: origin), "generation": activeGeneration,
            "revision": activeRevision, "epoch": stabilityEpoch
        ])
        if let roi {
            PerformanceProfiler.shared.increment("ocr.roiPercent", by: Int(roi.width * roi.height * 100))
        } else {
            PerformanceProfiler.shared.increment("ocr.fullFrame")
        }
        ocrTaskRevision = activeRevision
        showProcessingStatus(.recognizing, frameID: frame.id, origin: origin)
        if mirrorUpdateStyle == .progressive {
            display(MirrorFrame(image: frame.image, translatedItems: [], frameID: frame.id))
            PerformanceProfiler.shared.increment("mirror.progressiveFrame")
        }
        ocrTask = Task { [weak self] in
            guard let self else { return }
            await self.executeOCR(
                frame, mode: mode, roi: roi, generation: activeGeneration,
                revision: activeRevision, origin: origin, diagnosticID:diagnosticID
            )
            if self.generation == activeGeneration, self.ocrTaskRevision == activeRevision,
               self.ocrTaskSequence == taskSequence {
                self.ocrTask = nil
                self.ocrTaskRevision = nil
                if self.processPendingAutomaticFrameIfPossible() { return }
                if followWithRefinement, self.contentRevision == activeRevision {
                    self.scheduleRefinementAfterDelay(
                        frame, generation: activeGeneration, revision: activeRevision
                    )
                }
            }
        }
    }

    private func scheduleRefinementAfterDelay(
        _ frame: FrameEnvelope, generation activeGeneration: Int, revision activeRevision: Int
    ) {
        delayedRefinementTask?.cancel()
        let policy = refinementOCRPolicy
        delayedRefinementTask = Task { [weak self] in
            try? await Task.sleep(for: policy.delay)
            guard !Task.isCancelled,
                  let self,
                  self.generation == activeGeneration,
                  self.contentRevision == activeRevision,
                  self.ocrTask == nil else { return }

            if self.pendingAutomaticFrame.value != nil {
                _ = self.processPendingAutomaticFrameIfPossible()
                self.delayedRefinementTask = nil
                return
            }

            switch decideRefinementOCR(
                observationCount: self.lastRealtimeObservationCount,
                japaneseLines: self.lastRealtimeLines,
                policy: policy
            ) {
            case .skipHighConfidence:
                PerformanceProfiler.shared.increment("ocr.refinementSkippedHighConfidence")
            case .fullFrameFallback, .lowConfidenceROI:
                self.scheduleOCR(frame, mode: .refinement, roi: nil)
            }
            self.delayedRefinementTask = nil
        }
    }

    private func scheduleInitialOCRComparison(_ frame: FrameEnvelope) {
        let activeGeneration = generation
        let activeRevision = contentRevision
        ocrTaskSequence &+= 1
        let taskSequence = ocrTaskSequence
        ocrTaskRevision = activeRevision
        ocrTask = Task { [weak self] in
            guard let self else { return }
            do {
                let realtime = try await self.performOCR(
                    frame, mode: .realtime, roi: nil, purpose: .initialComparison
                )
                guard self.generation == activeGeneration else { return }
                self.lastRealtimeObservationCount = realtime.lines.count
                self.lastRealtimeLines = realtime.lines.filter {
                    LanguageProtector.containsSourceLanguage($0.sourceText, direction: self.translationDirection)
                }
                _ = try await self.performOCR(
                    frame, mode: .refinement, roi: nil, purpose: .initialComparison
                )
            } catch {
                self.logger.error("Initial OCR comparison failed: \(error.localizedDescription, privacy: .public)")
            }
            if self.generation == activeGeneration, self.ocrTaskRevision == activeRevision,
               self.ocrTaskSequence == taskSequence {
                self.ocrTask = nil
                self.ocrTaskRevision = nil
                _ = self.processPendingAutomaticFrameIfPossible()
            }
        }
    }

    @discardableResult
    private func processPendingAutomaticFrameIfPossible() -> Bool {
        let now = ContinuousClock.now
        let intervalElapsed = lastRealtimeOCR.duration(to: now) >= capturePolicy.refreshInterval(usesAX: usesAXExtraction)
        guard refreshMode == .automatic, !paused, ocrTask == nil,
              let frame = pendingAutomaticFrame.take(when: intervalElapsed) else { return false }
        PresentationTrace.shared.record("pending.consume", [
            "frame": frame.id, "epoch": stabilityEpoch
        ])
        lastRealtimeOCR = now
        scheduleOCR(
            frame, mode: initialOCRMode(for: refinementOCRPolicy.automaticStrategy), roi: nil
        )
        return true
    }

    private func performOCR(
        _ frame: FrameEnvelope, mode: OCRMode, roi: CGRect?, purpose: OCRDiagnosticPurpose, diagnosticID:UUID? = nil
    ) async throws -> OCRService.RecognitionBatch {
        let diagnosticStart=Date()
        let stage: ProfileStage = mode == .realtime ? .ocrRealtime : .ocrRefinement
        let span = PerformanceProfiler.shared.begin(
            stage, frameID: frame.id, mode: mode.rawValue
        )
        do {
            let settings = ocrSettings[mode] ?? OCRSettings.defaultProfile(for: mode)
            let batch = try await ocr.recognize(
                image: frame.image, mode: mode, regionOfInterest: roi,
                includeRejectedAlternatives: benchmarkDiagnostics && purpose == .initialComparison,
                settings: settings, direction: translationDirection
            )
            recordOCRDiagnostic(batch,mode:mode,roi:roi,purpose:purpose,id:diagnosticID,seconds:Date().timeIntervalSince(diagnosticStart))
            PerformanceProfiler.shared.end(span)
            PerformanceProfiler.shared.increment("ocr.rawObservations", by: batch.rawObservationCount)
            PerformanceProfiler.shared.increment("ocr.missingCandidate", by: batch.missingCandidateCount)
            PerformanceProfiler.shared.increment("ocr.confidenceRejected", by: batch.confidenceRejected.count)
            PerformanceProfiler.shared.recordOCRDiagnostics(
                batch.lines, frameID: frame.id, mode: mode,
                regionOfInterest: roi, purpose: purpose
            )
            if purpose == .initialComparison {
                PerformanceProfiler.shared.recordOCRDiagnostics(
                    batch.confidenceRejected.map {
                        RecognizedLine(
                            sourceText: $0.text, normalizedRect: $0.normalizedRect,
                            confidence: $0.confidence, background: .lightBackground, foreground: .darkText
                        )
                    },
                    frameID: frame.id, mode: mode,
                    regionOfInterest: roi, purpose: .confidenceRejected
                )
                PerformanceProfiler.shared.recordOCRDiagnostics(
                    batch.confidenceRejected.flatMap { rejected in
                        rejected.alternatives.map {
                            RecognizedLine(
                                sourceText: $0.text, normalizedRect: rejected.normalizedRect,
                                confidence: $0.confidence,
                                background: .lightBackground, foreground: .darkText
                            )
                        }
                    },
                    frameID: frame.id, mode: mode,
                    regionOfInterest: roi, purpose: .alternativeCandidate
                )
            }
            return batch
        } catch {
            PerformanceProfiler.shared.end(span)
            throw error
        }
    }

    private func executeOCR(
        _ frame: FrameEnvelope, mode: OCRMode, roi: CGRect?, generation activeGeneration: Int,
        revision activeRevision: Int, origin: MirrorStatusOrigin, diagnosticID:UUID?
    ) async {
        let batch: OCRService.RecognitionBatch
        do {
            batch = try await performOCR(
                frame, mode: mode, roi: roi, purpose: .runtime, diagnosticID:diagnosticID
            )
        } catch {
            diagnostics.error(error,stage:"ocr",id:diagnosticID)
            logger.error("OCR failed: \(error.localizedDescription, privacy: .public)")
            if generation == activeGeneration, contentRevision == activeRevision {
                if !(error is CancellationError) { reportFailure(error, stage: .ocr, userInitiated: origin == .userAction) }
                showProcessingStatus(.recognitionFailed, frameID: frame.id, origin: origin)
            }
            return
        }
        guard generation == activeGeneration, contentRevision == activeRevision else {
            diagnostics.event("result.discarded",frame:diagnosticID,["reason":"stale_ocr"])
            PerformanceProfiler.shared.increment("ocr.staleResult")
            return
        }

        failureDeduplicator.succeeded(.ocr)
        let recognized = batch.lines
        if PresentationTrace.shared.enabled {
            PresentationTrace.shared.record("ocr.result", [
                "frame": frame.id, "mode": mode.rawValue,
                "lines": recognized.map { line in
                    [
                        "id": line.id.uuidString,
                        "rect": PresentationTrace.rect(line.normalizedRect),
                        "confidence": line.confidence
                    ] as [String: Any]
                }
            ])
        }
        var debugItems = batch.debugItems

        let languageSpan = PerformanceProfiler.shared.begin(
            .languageFiltering, frameID: frame.id, itemCount: recognized.count,
            characterCount: recognized.reduce(0) { $0 + $1.sourceText.count }
        )
        let lines = recognized.filter {
            LanguageProtector.containsSourceLanguage($0.sourceText, direction: translationDirection)
        }
        PerformanceProfiler.shared.end(languageSpan)
        PerformanceProfiler.shared.increment("ocr.observations", by: recognized.count)
        PerformanceProfiler.shared.increment("ocr.sourceLanguageLines", by: lines.count)
        if mode == .realtime {
            lastRealtimeObservationCount = recognized.count
            lastRealtimeLines = lines
        }

        let translationTasks: [Task<TranslationResult?, Never>] = lines.map { line in
            Task { [broker] in
                do {
                    let started=Date()
                    let translated = try await DiagnosticTaskScope.$context.withValue(diagnosticID.map { DiagnosticFrameContext(self.diagnostics,id:$0) }) { try await broker.translate(line.sourceText) }
                    self.diagnostics.add("translation-\(line.id).json",document:.init(["source":line.sourceText,"translation":translated,"status":"translated","seconds":String(Date().timeIntervalSince(started))],estimatedBytes:(line.sourceText.utf8.count+translated.utf8.count)*4+256),to:diagnosticID)
                    return TranslationResult(line: line, translated: translated)
                } catch {
                    self.diagnostics.error(error,stage:"translation",id:diagnosticID)
                    self.diagnostics.add("translation-\(line.id).json",document:.init(["source":line.sourceText,"status":"failed","error":String(describing:error)],estimatedBytes:line.sourceText.utf8.count*4+4096),to:diagnosticID)
                    PerformanceProfiler.shared.increment("translation.lineFailure")
                    PerformanceProfiler.shared.increment("translation.failure")
                    return nil
                }
            }
        }

        showProcessingStatus(
            .translating(completed: 0, total: lines.count), frameID: frame.id, origin: origin
        )

        if mirrorUpdateStyle == .atomic {
            var completed: [TranslationResult] = []
            completed.reserveCapacity(translationTasks.count)
            var finishedCount = 0
            for task in translationTasks {
                if let result = await task.value { completed.append(result) }
                finishedCount += 1
                guard generation == activeGeneration, contentRevision == activeRevision else { return }
                showProcessingStatus(
                    .translating(completed: finishedCount, total: lines.count), frameID: frame.id,
                    origin: origin
                )
            }
            guard generation == activeGeneration, contentRevision == activeRevision else { return }
            let items = makeMirrorItems(
                frameID: frame.id,
                recognizedLines: recognized,
                translations: completed.map {
                    MirrorTranslation(frameID: frame.id, line: $0.line, translatedText: $0.translated)
                }
            )
            if !lines.isEmpty && completed.isEmpty { reportFailure(nil, stage: .translation, userInitiated: origin == .userAction) }
            else { failureDeduplicator.succeeded(.translation) }
            let translatedTextByID = Dictionary(uniqueKeysWithValues: completed.map { ($0.line.id, $0.translated) })
            let translatedIDs = Set(translatedTextByID.keys)
            debugItems = debugItems.map { item in
                guard item.status == .translationPending else { return item }
                let succeeded = translatedIDs.contains(item.id)
                return OCRDebugItem(id: item.id,
                                    status: succeeded ? .success : .translationFailed,
                                    rawText: item.rawText, confidence: item.confidence,
                                    recognitionLanguages: item.recognitionLanguages,
                                    translatedText: translatedTextByID[item.id], normalizedRect: item.normalizedRect)
            }
            display(MirrorFrame(image: frame.image, translatedItems: items, ocrDebugItems: debugItems, frameID: frame.id))
            showProcessingStatus(
                .completed(failures: lines.count - completed.count), frameID: frame.id, origin: origin
            )
            PerformanceProfiler.shared.increment("mirror.atomicFrame")
            PerformanceProfiler.shared.recordElapsed(
                .endToEnd, startedAt: frame.receivedAt, frameID: frame.id,
                itemCount: items.count, mode: "mirror"
            )
            recordDebugCaptureText(
                frameID: frame.id, mode: mode, recognizedLines: recognized,
                translatableLines: lines, translations: completed
            )
            return
        }

        if mirrorUpdateStyle == .progressive {
            display(MirrorFrame(
                image: frame.image,
                translatedItems: makeMirrorItems(
                    frameID: frame.id, recognizedLines: recognized, translations: []
                ),
                ocrDebugItems: debugItems,
                frameID: frame.id
            ))
            await withTaskGroup(of: TranslationResult?.self) { group in
                for task in translationTasks {
                    group.addTask { await task.value }
                }
                var completed: [TranslationResult] = []
                completed.reserveCapacity(translationTasks.count)
                var finishedCount = 0
                while let next = await group.next() {
                    guard generation == activeGeneration, contentRevision == activeRevision,
                          mirrorUpdateStyle == .progressive else {
                        group.cancelAll()
                        return
                    }
                    finishedCount += 1
                    if let result = next {
                        completed.append(result)
                        let items = makeMirrorItems(
                            frameID: frame.id,
                            recognizedLines: recognized,
                            translations: completed.map {
                                MirrorTranslation(
                                    frameID: frame.id, line: $0.line, translatedText: $0.translated
                                )
                            }
                        )
                        display(
                            MirrorFrame(image: frame.image, translatedItems: items, ocrDebugItems: debugItems.map { item in
                                guard item.status == .translationPending else { return item }
                                return OCRDebugItem(id: item.id, status: .success, rawText: item.rawText,
                                                    confidence: item.confidence,
                                                    recognitionLanguages: item.recognitionLanguages,
                                                    normalizedRect: item.normalizedRect)
                            }, frameID: frame.id)
                        )
                        PerformanceProfiler.shared.increment("mirror.progressiveLine")
                        PerformanceProfiler.shared.recordElapsed(
                            .endToEnd, startedAt: frame.receivedAt, frameID: frame.id,
                            itemCount: 1, mode: MirrorUpdateStyle.progressive.rawValue
                        )
                    }
                    showProcessingStatus(
                        .translating(completed: finishedCount, total: lines.count), frameID: frame.id,
                        origin: origin
                    )
                }
                showProcessingStatus(
                    .completed(failures: lines.count - completed.count), frameID: frame.id, origin: origin
                )
                if !lines.isEmpty && completed.isEmpty { reportFailure(nil, stage: .translation, userInitiated: origin == .userAction) }
                else { failureDeduplicator.succeeded(.translation) }
                recordDebugCaptureText(
                    frameID: frame.id, mode: mode, recognizedLines: recognized,
                    translatableLines: lines, translations: completed
                )
            }
        }
    }

}

private enum SessionCollectionFailure: Error { case failed }
