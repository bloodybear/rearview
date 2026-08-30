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
protocol SessionTranslationProvider: AnyObject {
    func setDirection(_ direction: TranslationDirection)
    func setProtectsNonSourceText(_ enabled: Bool)
    func translate(_ source: String) async throws -> String
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
        let relativeSelection: CGRect
        var lastKnownWindowFrame: CGRect
        var missingSince: ContinuousClock.Instant?
    }

    private enum TrackedWindowLookup {
        case visible(CGRect)
        case unavailable
        case queryFailed
    }

    private let broker: any SessionTranslationProvider
    private let capture: any SessionCaptureProvider
    private let targetResolver: any SessionTargetResolver
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
    private var lastRealtimeOCR = ContinuousClock.now - .seconds(2)
    private var lastMotion = ContinuousClock.now
    private var lastRealtimeLines: [RecognizedLine] = []
    private var lastRealtimeObservationCount = 0
    private var stabilityEpoch: UInt64 = 0
    private var lastRefinementEpoch: UInt64?
    private var benchmarkDiagnostics = false
    private var initialComparisonStarted = false
    private let logger = Logger(subsystem: "io.github.bloodybear.rearview", category: "pipeline")

    var onDisplayModeChange: ((TranslationDisplayMode) -> Void)?
    var onOverlayPresentationChange: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onTranslationDirectionChange: ((TranslationDirection) -> Void)?

    init(
        broker: any SessionTranslationProvider,
        capture: any SessionCaptureProvider = ScreenCaptureEngine(),
        targetResolver: any SessionTargetResolver = CaptureApplicationPicker(),
        ocr: any SessionOCRProvider = OCRService(),
        outputSink: (any SessionOutputSink)? = nil,
        createsOutputWindow: Bool = true
    ) {
        self.broker = broker
        self.capture = capture
        self.targetResolver = targetResolver
        self.ocr = ocr
        self.outputSink = outputSink
        self.createsOutputWindow = createsOutputWindow
    }

    func start(
        screen: NSScreen, selection: CGRect,
        initialDockingState: MirrorDockingState? = nil,
        mirrorUpdateStyle: MirrorUpdateStyle = .atomic,
        captureTarget: CaptureTarget = .allContent,
        benchmarkDiagnostics: Bool = false
    ) async throws {
        await stop()
        self.selection = selection
        self.selectedScreen = screen
        mirrorDockingState = initialDockingState ?? MirrorDockingState.load()
        self.mirrorUpdateStyle = mirrorUpdateStyle

        // A newly selected region with exactly one visible app is scoped to that app.
        // Explicit targets remain authoritative for benchmark and programmatic starts.
        let resolvedTarget: CaptureTarget
        if captureTarget == .allContent {
            let resolution = try await targetResolver.resolveTarget(for: selection, on: screen)
            resolvedTarget = resolution.target
            self.availableApplications = resolution.candidate.map { [$0] } ?? []
        } else {
            resolvedTarget = captureTarget
            self.availableApplications = captureTarget.application.map { [$0] } ?? []
        }
        self.captureTarget = resolvedTarget
        generation += 1
        let activeGeneration = generation
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
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            throw TranslatorError.noDisplay
        }

        do {
            try await capture.start(
                displayID: number.uint32Value, screenFrame: screen.frame,
                backingScale: screen.backingScaleFactor, selection: selection,
                target: resolvedTarget,
                policy: capturePolicy
            ) { [weak self] image, frameID, receivedAt in
                Task { @MainActor [weak self] in self?.receive(image, frameID: frameID, receivedAt: receivedAt) }
            }
            guard generation == activeGeneration else {
                throw CancellationError()
            }
            if createsOutputWindow { createOutputWindow() }
            acceptingFrames = true
            startWindowTrackingIfNeeded()
        } catch {
            await cleanupFailedStart(activeGeneration: activeGeneration)
            throw error
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
        guard !stopping else { return }
        stopping = true
        defer { stopping = false }
        generation += 1
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
        await capture.stop()
    }

    func setMirrorUpdateStyle(_ style: MirrorUpdateStyle) async {
        guard style != mirrorUpdateStyle else { return }
        mirrorUpdateStyle = style
        guard selectedScreen != nil else { return }
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

    func setTranslationDirection(_ direction: TranslationDirection) {
        guard translationDirection != direction else { return }
        translationDirection = direction
        direction.save()
        contentRevision += 1
        ocrTask?.cancel(); ocrTask = nil; ocrTaskRevision = nil
        delayedRefinementTask?.cancel(); delayedRefinementTask = nil
        lastRefinementEpoch = nil
        broker.setDirection(direction)
        mirror?.setTranslationDirection(direction)
        onTranslationDirectionChange?(direction)
        if let frame = latestCapturedFrame, acceptingFrames {
            lastRealtimeOCR = .now
            scheduleOCR(frame, mode: .realtime, roi: nil)
        }
    }

    func setProtectsNonSourceText(_ enabled: Bool) {
        guard protectsNonSourceText != enabled else { return }
        protectsNonSourceText = enabled
        TranslationTextProtection.save(enabled)
        contentRevision += 1
        ocrTask?.cancel(); ocrTask = nil; ocrTaskRevision = nil
        delayedRefinementTask?.cancel(); delayedRefinementTask = nil
        lastRefinementEpoch = nil
        broker.setProtectsNonSourceText(enabled)
        if let frame = latestCapturedFrame, acceptingFrames {
            lastRealtimeOCR = .now
            scheduleOCR(frame, mode: .realtime, roi: nil)
        }
    }

    func setOCRSettings(_ settings: OCRSettings, mode: OCRMode) {
        guard ocrSettings[mode] != settings else { return }
        ocrSettings[mode] = settings
        settings.save(mode: mode)
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
        do {
            try await capture.update(policy: policy)
        } catch {
            logger.error("Capture policy update failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func setRefreshMode(_ mode: RefreshMode) {
        guard refreshMode != mode else { return }
        refreshMode = mode
        mode.save()
        if mode == .manual {
            if paused { setPaused(false) }
            suspendAutomaticProcessing()
        }
        mirror?.setRefreshMode(mode)
        updateRegionBorderPresentation()
        if mode == .automatic, !paused {
            processLatestFrameImmediately(strategy: refinementOCRPolicy.automaticStrategy)
        }
    }

    func setPaused(_ value: Bool) {
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
        guard displayMode == .mirror else { return }
        mirror?.toggleDocking(state)
    }

    private func updateRegionBorderPresentation() {
        let state: RegionBorderController.PresentationState
        if refreshMode == .manual {
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
        guard let frame = latestCapturedFrame, ocrTask == nil else { return }
        latestFrame = nil
        pendingAutomaticFrame.clear()
        changes.reset()
        lastRealtimeOCR = .now
        scheduleOCR(
            frame, mode: initialOCRMode(for: strategy), roi: nil,
            followWithRefinement: strategy == .realtimeThenRefinement,
            origin: .userAction
        )
    }

    private func display(_ frame: MirrorFrame) {
        mirror?.display(frame)
        outputSink?.display(frame)
    }

    private func showProcessingStatus(
        _ status: MirrorProcessingStatus, frameID: UInt64,
        origin: MirrorStatusOrigin = .automatic
    ) {
        mirror?.showProcessingStatus(status, frameID: frameID, origin: origin)
        outputSink?.showProcessingStatus(status, frameID: frameID)
    }

    private func cancelProcessingStatus() {
        mirror?.cancelProcessingStatus()
        outputSink?.cancelProcessingStatus()
    }

    private func initialOCRMode(for strategy: OCRExecutionStrategy) -> OCRMode {
        strategy == .refinementImmediately ? .refinement : .realtime
    }

    private func suspendAutomaticProcessing() {
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
            self.regionBorder?.setChromeVisible(mode == .mirror)
            mode.save()
            self.onDisplayModeChange?(mode)
        }
        window.onTranslationDirectionChange = { [weak self] direction in
            self?.setTranslationDirection(direction)
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
        window.onPauseChange = { [weak self] paused in self?.setPaused(paused) }
        window.onImmediateTranslation = { [weak self] in self?.translateImmediately() }
        window.setTranslationDirection(translationDirection)
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

    private func applySelection(
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
        acceptingFrames = false
        do {
            try await capture.updateRegion(
                selection: rect, screenFrame: selectedScreen.frame,
                backingScale: selectedScreen.backingScaleFactor,
                displayID: Self.displayID(for: selectedScreen)
            )
        } catch {
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
        guard generation == (trackingGeneration ?? generation),
              trackingRevision == nil || activeRevision == contentRevision else {
            acceptingFrames = true
            return
        }
        regionBorder?.setScreen(selectedScreen)
        regionBorder?.setSelection(rect)
        mirror?.setSelectionFrame(rect)
        acceptingFrames = true
        if rebuildTrackingAnchor, case .application = captureTarget, !selectionInteractionActive {
            rebuildWindowTrackingAnchor()
            startWindowTrackingIfNeeded()
        }
    }

    private func setApplicationCapture(_ application: CaptureApplication?) async {
        guard let selectedScreen else { return }
        let target = application.map(CaptureTarget.application) ?? .allContent
        guard target != captureTarget else { updateTargetControl(); return }
        windowTrackingTask?.cancel()
        windowTrackingTask = nil
        windowTrackingAnchor = nil
        selectionUpdateTask?.cancel()
        selectionUpdateTask = nil
        invalidateCapturedContent()
        acceptingFrames = false
        do {
            try await updateCaptureTarget(target, on: selectedScreen)
        } catch {
            logger.error("Capture target update failed: \(error.localizedDescription, privacy: .public)")
            updateTargetControl()
        }
        acceptingFrames = true
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

        let windowFrame: CGRect
        if let currentAnchor = windowTrackingAnchor,
           currentAnchor.windowID == windowID,
           currentAnchor.processID == application.processID {
            windowFrame = currentAnchor.lastKnownWindowFrame
        } else if let initialFrame = application.anchorWindowFrame {
            windowFrame = initialFrame
        } else {
            windowTrackingAnchor = nil
            windowTrackingTask = nil
            return
        }

        let relativeSelection = relativeSelectionInWindow(
            selection: selection,
            screenFrame: selectedScreen.frame,
            displayBounds: CGDisplayBounds(displayID),
            windowFrame: windowFrame
        )
        windowTrackingAnchor = WindowTrackingAnchor(
            processID: application.processID,
            windowID: windowID,
            relativeSelection: relativeSelection,
            lastKnownWindowFrame: windowFrame,
            missingSince: nil
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
            anchor.missingSince = nil
            anchor.lastKnownWindowFrame = windowFrame
            windowTrackingAnchor = anchor
            let displays = NSScreen.screens.compactMap { screen -> WindowTrackingDisplay? in
                guard let displayID = Self.displayID(for: screen) else { return nil }
                return WindowTrackingDisplay(displayID: displayID, bounds: CGDisplayBounds(displayID))
            }
            guard let projection = projectTrackedSelection(
                relativeSelection: anchor.relativeSelection,
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
                guard !Task.isCancelled, let self else { return }
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
        try await capture.updateTarget(displayID: number.uint32Value, target: target)
        captureTarget = target
        updateTargetControl()
    }

    private func invalidateCapturedContent() {
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
        guard acceptingFrames else { return }
        let received = FrameEnvelope(image: image, id: frameID, receivedAt: receivedAt)
        latestCapturedFrame = received
        guard refreshMode == .automatic, !paused else { return }
        if latestFrame != nil { PerformanceProfiler.shared.increment("frame.overwritten") }
        latestFrame = received
        if benchmarkDiagnostics, !initialComparisonStarted, frameID >= 3 {
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

    private func processMirrorFrame(_ frame: FrameEnvelope) {
        let change = changes.analyze(frame.image)
        PerformanceProfiler.shared.increment(
            "change.tilesPercent", by: Int(change.changedRatio * 100)
        )
        let hasVisualChange = change.changedRatio > 0
        let now = ContinuousClock.now
        if hasVisualChange {
            lastMotion = now
            stabilityEpoch &+= 1
            if change.motion.kind == .sceneChange {
                pendingAutomaticFrame.clear()
                delayedRefinementTask?.cancel()
                delayedRefinementTask = nil
                if ocrTask != nil {
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
            guard lastRealtimeOCR.duration(to: now) >= capturePolicy.realtimeOCRInterval else {
                pendingAutomaticFrame.store(frame)
                return
            }
            guard ocrTask == nil else {
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

        guard refinementOCRPolicy.automaticStrategy == .realtimeThenRefinement,
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
        let activeGeneration = generation
        let activeRevision = contentRevision
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
                revision: activeRevision, origin: origin
            )
            if self.generation == activeGeneration, self.ocrTaskRevision == activeRevision {
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
            if self.generation == activeGeneration, self.ocrTaskRevision == activeRevision {
                self.ocrTask = nil
                self.ocrTaskRevision = nil
                _ = self.processPendingAutomaticFrameIfPossible()
            }
        }
    }

    @discardableResult
    private func processPendingAutomaticFrameIfPossible() -> Bool {
        let now = ContinuousClock.now
        let intervalElapsed = lastRealtimeOCR.duration(to: now) >= capturePolicy.realtimeOCRInterval
        guard refreshMode == .automatic, !paused, ocrTask == nil,
              let frame = pendingAutomaticFrame.take(when: intervalElapsed) else { return false }
        lastRealtimeOCR = now
        scheduleOCR(
            frame, mode: initialOCRMode(for: refinementOCRPolicy.automaticStrategy), roi: nil
        )
        return true
    }

    private func performOCR(
        _ frame: FrameEnvelope, mode: OCRMode, roi: CGRect?, purpose: OCRDiagnosticPurpose
    ) async throws -> OCRService.RecognitionBatch {
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
        revision activeRevision: Int, origin: MirrorStatusOrigin
    ) async {
        let batch: OCRService.RecognitionBatch
        do {
            batch = try await performOCR(
                frame, mode: mode, roi: roi, purpose: .runtime
            )
        } catch {
            logger.error("OCR failed: \(error.localizedDescription, privacy: .public)")
            if generation == activeGeneration, contentRevision == activeRevision {
                showProcessingStatus(.recognitionFailed, frameID: frame.id, origin: origin)
            }
            return
        }
        guard generation == activeGeneration, contentRevision == activeRevision else {
            PerformanceProfiler.shared.increment("ocr.staleResult")
            return
        }

        let recognized = batch.lines
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
                    let translated = try await broker.translate(line.sourceText)
                    return TranslationResult(line: line, translated: translated)
                } catch {
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
            }
        }
    }

}
