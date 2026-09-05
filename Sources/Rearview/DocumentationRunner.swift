#if REARVIEW_DOCUMENTATION
import AppKit
import CryptoKit
import SwiftUI
@preconcurrency import ScreenCaptureKit

/// Public, repository-owned text used to make the documentation capture
/// repeatable. It is rendered by an actual NSWindow and then passed through
/// the same Vision and Translation pipelines as a normal session.
enum DocumentationFixture {
    static let source = "新しいウィンドウを開いて、設定を確認してください。"
    static let imageSize = CGSize(width: 960, height: 540)
    static let viewportSize = CGSize(width: 1440, height: 900)

    static func makeImage() -> CGImage? {
        let image = NSImage(size: imageSize)
        image.lockFocus()
        NSColor(calibratedWhite: 0.12, alpha: 1).setFill()
        NSBezierPath(rect: CGRect(origin: .zero, size: imageSize)).fill()
        let heading: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 28, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let body: [NSAttributedString.Key: Any] = [
            // Keep the source large enough for Vision's accurate Japanese
            // recognizer while preserving the natural screen-text appearance.
            .font: NSFont.systemFont(ofSize: 30),
            .foregroundColor: NSColor(calibratedWhite: 0.85, alpha: 1)
        ]
        ("Rearview 문서용 일본어 화면" as NSString).draw(
            at: CGPoint(x: 56, y: imageSize.height - 86), withAttributes: heading
        )
        (source as NSString).draw(
            at: CGPoint(x: 56, y: imageSize.height - 150), withAttributes: body
        )
        image.unlockFocus()
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}

private final class DocumentationFixtureView: NSView {
    private let image: CGImage

    init(image: CGImage) {
        self.image = image
        super.init(frame: CGRect(origin: .zero, size: DocumentationFixture.imageSize))
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSImage(cgImage: image, size: DocumentationFixture.imageSize).draw(
            in: bounds, from: .zero, operation: .copy, fraction: 1
        )
    }
}

@MainActor
private final class DocumentationFixtureWindow: NSWindow {
    init(screen: NSScreen, image: CGImage) {
        let frame = CGRect(
            x: screen.visibleFrame.minX + 40,
            y: screen.visibleFrame.minY + 40,
            width: DocumentationFixture.imageSize.width,
            height: DocumentationFixture.imageSize.height
        )
        super.init(
            contentRect: frame, styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false
        )
        title = "문서용 일본어 화면"
        contentView = DocumentationFixtureView(image: image)
        level = .normal
        isReleasedWhenClosed = false
        // Make this a real key window.  Documentation runs before the normal
        // app event loop is entered, so `orderFrontRegardless()` alone does
        // not always give WindowServer an activation transaction to compose.
        makeKeyAndOrderFront(nil)
    }
}

@MainActor
private final class DocumentationBackdropWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame, styleMask: [.borderless],
            backing: .buffered, defer: false
        )
        isOpaque = true
        hasShadow = false
        ignoresMouseEvents = true
        level = .normal
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        contentView = DocumentationBackdropView(frame: CGRect(origin: .zero, size: screen.frame.size))
        orderFrontRegardless()
    }
}

private final class DocumentationBackdropView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let gradient = NSGradient(
            starting: NSColor(calibratedRed: 0.10, green: 0.22, blue: 0.34, alpha: 1),
            ending: NSColor(calibratedRed: 0.03, green: 0.07, blue: 0.12, alpha: 1)
        )
        gradient?.draw(in: bounds, angle: 90)
    }
}

/// Captures the fixture window with ScreenCaptureKit. The provider is a
/// one-frame source: SessionCoordinator, OCRService and TranslationBroker
/// still execute their normal asynchronous code paths.
@MainActor
private final class DocumentationScreenCaptureProvider: SessionCaptureProvider {
    private let fixtureWindow: DocumentationFixtureWindow
    private let documentationDisplayID: CGDirectDisplayID
    private var selection = CGRect.zero
    private var screenFrame = CGRect.zero
    private var backingScale: CGFloat = 1
    private var callback: (@Sendable (CGImage, UInt64, UInt64) -> Void)?
    private var nextFrameID: UInt64 = 0
#if DEBUG || REARVIEW_DOCUMENTATION
    private(set) var lastImage: CGImage?
#endif

    init(fixtureWindow: DocumentationFixtureWindow, displayID: CGDirectDisplayID) {
        self.fixtureWindow = fixtureWindow
        documentationDisplayID = displayID
    }

    func start(
        displayID: CGDirectDisplayID, screenFrame: CGRect, backingScale: CGFloat,
        selection: CGRect, target: CaptureTarget, policy: CapturePolicy,
        onFrame: @escaping @Sendable (CGImage, UInt64, UInt64) -> Void
    ) async throws {
        guard displayID == documentationDisplayID else { throw TranslatorError.noDisplay }
        self.selection = selection
        self.screenFrame = screenFrame
        self.backingScale = backingScale
        callback = onFrame
        try await emit()
    }

    func emit() async throws {
        fixtureWindow.orderFrontRegardless()
        var content = try await DocumentationRunner.shareableContent()
        var source = content.windows.first { $0.windowID == CGWindowID(fixtureWindow.windowNumber) }
        var display = content.displays.first { $0.displayID == documentationDisplayID }
        for _ in 0..<20 where source == nil || display == nil {
            try? await Task.sleep(for: .milliseconds(100))
            content = try await DocumentationRunner.shareableContent()
            source = content.windows.first { $0.windowID == CGWindowID(fixtureWindow.windowNumber) }
            display = content.displays.first { $0.displayID == documentationDisplayID }
        }
        guard let display, let source else {
            throw DocumentationError.captureFailed("fixture window is not visible to ScreenCaptureKit")
        }
        let filter = SCContentFilter(display: display, including: [source])
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = pixelAlignedCaptureRect(
            selection: selection, screenFrame: screenFrame, backingScale: backingScale
        )
        configuration.width = max(1, Int((selection.width * backingScale).rounded()))
        configuration.height = max(1, Int((selection.height * backingScale).rounded()))
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = false
        let image = try await Self.captureImage(filter: filter, configuration: configuration)
        #if DEBUG || REARVIEW_DOCUMENTATION
        lastImage = image
        #endif
        nextFrameID &+= 1
        callback?(image, nextFrameID, DispatchTime.now().uptimeNanoseconds)
    }

    func update(policy: CapturePolicy) async throws {}
    func updateRegion(selection: CGRect, screenFrame: CGRect, backingScale: CGFloat, displayID: CGDirectDisplayID?) async throws {
        self.selection = selection
        self.screenFrame = screenFrame
        self.backingScale = backingScale
    }
    func updateTarget(displayID: CGDirectDisplayID, target: CaptureTarget) async throws {}
    func stop() async { callback = nil }

    fileprivate static func captureImage(
        filter: SCContentFilter, configuration: SCStreamConfiguration
    ) async throws -> CGImage {
        try await withCheckedThrowingContinuation { continuation in
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { image, error in
                if let error { continuation.resume(throwing: error) }
                else if let image { continuation.resume(returning: image) }
                else { continuation.resume(throwing: DocumentationError.captureFailed("ScreenCaptureKit returned no image")) }
            }
        }
    }
}

@MainActor
private final class DocumentationTargetResolver: SessionTargetResolver {
    func applications(for selection: CGRect, on screen: NSScreen) async throws -> [CaptureApplication] { [] }
    func resolveTarget(for selection: CGRect, on screen: NSScreen) async throws -> CaptureTargetResolution {
        CaptureTargetResolution(target: .allContent, candidate: nil)
    }
}

@MainActor
private final class DocumentationSystemScreenshotter {
    private let screen: NSScreen
    private let displayID: CGDirectDisplayID

    init(screen: NSScreen, displayID: CGDirectDisplayID) {
        self.screen = screen
        self.displayID = displayID
    }

    func capture(windows: [NSWindow]) async throws -> CGImage {
        let ids = Set(windows.compactMap { window -> CGWindowID? in
            guard window.windowNumber > 0 else { return nil }
            return CGWindowID(window.windowNumber)
        })
        return try await Self.captureDetached(
            displayID: displayID, screenFrame: screen.frame,
            backingScale: screen.backingScaleFactor, windowIDs: ids
        )
    }

    /// Captures without hopping back to MainActor.  This is required while an
    /// `NSMenu` is tracking: `NSMenu.popUp` owns a nested AppKit loop and the
    /// runner cannot resume on MainActor until the menu closes.  Taking the
    /// screenshot from a detached task preserves the menu in the compositor.
    nonisolated static func captureDetached(
        displayID: CGDirectDisplayID, screenFrame: CGRect,
        backingScale: CGFloat, windowIDs: Set<CGWindowID>
    ) async throws -> CGImage {
        var content = try await DocumentationRunner.shareableContent()
        var sources = content.windows.filter { windowIDs.contains($0.windowID) }
        var display = content.displays.first { $0.displayID == displayID }
        for _ in 0..<20 where sources.isEmpty || display == nil {
            try? await Task.sleep(for: .milliseconds(100))
            content = try await DocumentationRunner.shareableContent()
            sources = content.windows.filter { windowIDs.contains($0.windowID) }
            display = content.displays.first { $0.displayID == displayID }
        }
        guard let display, !sources.isEmpty else {
            let availableDisplays = content.displays.map { String($0.displayID) }.joined(separator: ",")
            let requestedWindows = windowIDs.map(String.init).sorted().joined(separator: ",")
            let availableWindows = content.windows.map { String($0.windowID) }.joined(separator: ",")
            throw DocumentationError.captureFailed(
                "documentation windows are not visible to ScreenCaptureKit "
                    + "(display=\(displayID), displays=[\(availableDisplays)], "
                    + "requestedWindows=[\(requestedWindows)], availableWindows=[\(availableWindows)])"
            )
        }
        let filter = SCContentFilter(display: display, including: sources)
        let scale = max(1, backingScale)
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = CGRect(origin: .zero, size: screenFrame.size)
        configuration.width = max(1, Int((screenFrame.width * scale).rounded()))
        configuration.height = max(1, Int((screenFrame.height * scale).rounded()))
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = false
        return try await DocumentationScreenCaptureProvider.captureImage(filter: filter, configuration: configuration)
    }
}

@MainActor
enum DocumentationRunner {
    nonisolated fileprivate static func shareableContent() async throws -> SCShareableContent {
        // `current` asks ScreenCaptureKit for the complete, user-authorized
        // view.  Some macOS releases return an object with windows but no
        // displays while a newly launched app is being activated.  Try the
        // documented filtered variants as well; the first result containing a
        // display is the one that can be used to compose an exact screen.
        let current = try await SCShareableContent.current
        if !current.displays.isEmpty { return current }
        let onScreen = try await SCShareableContent.excludingDesktopWindows(
            true, onScreenWindowsOnly: true
        )
        if !onScreen.displays.isEmpty { return onScreen }
        let allWindows = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false
        )
        return allWindows
    }

    static func run(arguments: [String]) async throws {
        guard let outputPath = value("--documentation-output=", arguments: arguments),
              let scenariosPath = value("--documentation-scenarios=", arguments: arguments) else {
            throw DocumentationError.invalidInput("--documentation-output and --documentation-scenarios are required")
        }
        let scenarios = try DocumentationJSON.loadScenarios(from: URL(fileURLWithPath: scenariosPath))
        let selectedID = value("--documentation-scenario=", arguments: arguments)
        if selectedID == nil { try validateCoverage(scenarios) }
        let selected = scenarios.scenarios.filter { selectedID == nil || $0.id == selectedID }
        guard !selected.isEmpty else { throw DocumentationError.invalidInput("requested scenario was not found") }
        let statusPath = value("--documentation-status-file=", arguments: arguments)
        func progress(_ message: String) {
            guard let statusPath else { return }
            try? message.write(
                to: URL(fileURLWithPath: statusPath), atomically: true, encoding: .utf8
            )
        }

        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        application.finishLaunching()
        // Launch Services starts the docs bundle in the background in some
        // developer environments.  Explicitly activate the running bundle
        // after it has a regular activation policy; this is what makes the
        // windows part of the user-visible WindowServer scene.
        NSApp.activate(ignoringOtherApps: true)
        NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
        AppDisplayLanguage.korean.save()
        TranslationDirection.japaneseToKorean.save()
        TranslationDisplayMode.mirror.save()
        RefreshMode.automatic.save()
        TranslationTextProtection.save(false)
        OCRRecognitionLanguageChoice.japaneseFirst.save()
        OCRSettings.defaultProfile(for: .realtime).save(mode: .realtime)
        OCRSettings.defaultProfile(for: .refinement).save(mode: .refinement)
        OverlayPresentationSettings(
            inactiveContentOpacity: OverlayOpacity.defaultValue,
            activeContentOpacity: OverlayActiveOpacity.defaultValue,
            inactiveControlBarOpacity: OverlayControlBarOpacity.defaultValue,
            activeControlBarOpacity: OverlayControlBarActiveOpacity.defaultValue,
            regionBorderOpacity: RegionBorderOpacity.defaultValue,
            ignoresMouseEvents: OverlayIgnoresMouseEvents.defaultValue
        ).save()
        MirrorBackgroundOpacity.save(MirrorBackgroundOpacity.defaultValue)
        MirrorAlwaysOnTop.save(false)
        MirrorFollowsSelectionSize.save(false)
        MirrorDockingState.undocked.save()

        guard let screen = documentationScreen(arguments: arguments),
              let displayID = displayID(for: screen),
              let fixtureImage = DocumentationFixture.makeImage() else {
            throw DocumentationError.captureFailed("no documentation display or fixture image")
        }
        let backdrop = DocumentationBackdropWindow(screen: screen)
        let fixture = DocumentationFixtureWindow(screen: screen, image: fixtureImage)
        let broker = TranslationBroker()
        let bridge = NSHostingView(rootView: TranslationBridgeView(broker: broker))
        let bootstrap = NSWindow(
            contentRect: CGRect(x: -1000, y: -1000, width: 2, height: 2),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        bootstrap.isOpaque = false
        bootstrap.backgroundColor = .clear
        bootstrap.ignoresMouseEvents = true
        bootstrap.contentView = bridge
        bootstrap.orderFrontRegardless()
        fixture.makeKeyAndOrderFront(nil)
        backdrop.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
        // Give AppKit/WindowServer a complete turn before the first
        // ScreenCaptureKit query.  The normal product app has a long-running
        // run loop; documentation mode is a finite command, so we must pump
        // it explicitly at this boundary.
        await settleAsync(seconds: 0.25)
        try await waitForTranslationSession(broker)

        let capture = DocumentationScreenCaptureProvider(fixtureWindow: fixture, displayID: displayID)
        let targetResolver = DocumentationTargetResolver()
        let coordinator = SessionCoordinator(
            broker: broker, capture: capture, targetResolver: targetResolver,
            ocr: OCRService()
        )
        let screenshotter = DocumentationSystemScreenshotter(screen: screen, displayID: displayID)
        let outputURL = URL(fileURLWithPath: outputPath, isDirectory: true)
        let assetsURL = outputURL.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assetsURL, withIntermediateDirectories: true)
        var records: [DocumentationScreenshotRecord] = []
        var selection = CGRect(
            x: screen.visibleFrame.minX + 180, y: screen.visibleFrame.minY + 160,
            width: 720, height: 320
        )
        var permission: ScreenCapturePermissionWindowController?
        var settings: SettingsWindowController?
        var overflowMenuRequested = false
        let selectionController = ScreenSelectionController(targetResolver: targetResolver)

        for scenario in selected {
            progress("running scenario \(scenario.id)\n")
            await coordinator.stop()
            permission?.window?.orderOut(nil)
            settings?.window?.orderOut(nil)
            selectionController.closeDocumentationPreview()
            permission = nil; settings = nil
            coordinator.dismissDocumentationOverflowMenu()
            overflowMenuRequested = false
            backdrop.orderFrontRegardless(); fixture.orderFrontRegardless()
            coordinator.setDisplayMode(.mirror)
            coordinator.setRefreshMode(.automatic)
            coordinator.setProtectsNonSourceText(false)
            coordinator.setPaused(false)

            for (actionIndex, action) in scenario.actions.enumerated() {
                progress("running scenario \(scenario.id) action \(actionIndex + 1)/\(scenario.actions.count): \(action.type)\n")
                switch action.type {
                case "showPermissionPreview":
                    let controller = ScreenCapturePermissionWindowController(kind: .introduction)
                    controller.showPermissionRequired(); controller.showWindow(nil)
                    controller.window?.center(); controller.window?.orderFrontRegardless()
                    permission = controller
                case "showSelectionPreview":
                    selectionController.showDocumentationPreview(on: screen, selection: selection)
                case "setSelection":
                    if let values = action.rect, values.count == 4 {
                        selection = CGRect(
                            x: screen.visibleFrame.minX + values[0], y: screen.visibleFrame.minY + values[1],
                            width: values[2], height: values[3]
                        )
                        selectionController.updateDocumentationSelection(selection, on: screen)
                    }
                case "startSession":
                    coordinator.setDisplayMode(action.mode == "overlay" ? .overlay : .mirror)
                    try await coordinator.start(
                        screen: screen, selection: selection, initialDockingState: .undocked,
                        mirrorUpdateStyle: .atomic, captureTarget: .allContent
                    )
                    selectionController.closeDocumentationPreview()
                    try await capture.emit()
#if REARVIEW_DOCUMENTATION
                    if let debugPath = ProcessInfo.processInfo.environment["REARVIEW_DOCUMENTATION_DEBUG_FRAME_PATH"],
                       let image = capture.lastImage,
                       let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                        try data.write(to: URL(fileURLWithPath: debugPath), options: .atomic)
                    }
                    if ProcessInfo.processInfo.environment["REARVIEW_DOCUMENTATION_OCR_PROBE"] == "1",
                       let image = capture.lastImage {
                        let probe = try await OCRService().recognize(
                            image: image, mode: .realtime, regionOfInterest: nil,
                            includeRejectedAlternatives: false,
                            settings: OCRSettings.defaultProfile(for: .realtime),
                            direction: .japaneseToKorean
                        )
                        let probeMessage = "observations=\(probe.rawObservationCount), lines=\(probe.lines.count)\n"
                        if let probePath = ProcessInfo.processInfo.environment["REARVIEW_DOCUMENTATION_OCR_PROBE_PATH"] {
                            try probeMessage.write(to: URL(fileURLWithPath: probePath), atomically: true, encoding: .utf8)
                        }
                    }
#endif
                    try await waitForTranslatedFrame(coordinator, broker: broker)
                case "setDisplayMode":
                    coordinator.setDisplayMode(action.mode == "overlay" ? .overlay : .mirror)
                case "setRefreshMode":
                    coordinator.setRefreshMode(action.mode == "manual" ? .manual : .automatic)
                case "setPaused": coordinator.setPaused(action.value == "true")
                case "showSearch": coordinator.showSearch()
                case "showTextSelection": coordinator.toggleDocumentationTextSelection()
                case "copyText": coordinator.copyDocumentationText()
                case "showSettings":
                    let controller = settings ?? SettingsWindowController()
                    settings = controller
                    controller.showWindow(nil)
                    controller.showDocumentationCategory(action.category)
                    controller.window?.center(); controller.window?.orderFrontRegardless()
                case "setSetting": applySetting(action, coordinator: coordinator)
                case "showToolbarOverflow":
                    coordinator.showDocumentationOverflowMenu()
                    overflowMenuRequested = true
                case "wait": await settleAsync(seconds: Double(action.number ?? 400) / 1_000)
                case "capture":
                    guard let name = action.name else { continue }
                    if !overflowMenuRequested { await settleAsync(seconds: 0.15) }
                    let windows = [backdrop, fixture]
                        + (permission?.window.map { [$0] } ?? [])
                        + (settings?.window.map { [$0] } ?? [])
                        + selectionController.documentationWindowsForCapture()
                        + coordinator.documentationWindowsForCapture()
                    let image: CGImage
                    if overflowMenuRequested {
                        // The native menu is currently in AppKit's nested
                        // tracking loop. Capture from a detached task before
                        // the safety timer dismisses it, otherwise the
                        // screenshot would be taken after the menu vanished.
                        try? await Task.sleep(for: .milliseconds(180))
                        let windowIDs = Set(windows.compactMap { window -> CGWindowID? in
                            guard window.windowNumber > 0 else { return nil }
                            return CGWindowID(window.windowNumber)
                        })
                        let captureDisplayID = displayID
                        let captureScreenFrame = screen.frame
                        let captureBackingScale = screen.backingScaleFactor
                        image = try await Task.detached(priority: .userInitiated) {
                            try await DocumentationSystemScreenshotter.captureDetached(
                                displayID: captureDisplayID, screenFrame: captureScreenFrame,
                                backingScale: captureBackingScale, windowIDs: windowIDs
                            )
                        }.value
                    } else {
                        image = try await screenshotter.capture(windows: windows)
                    }
                    try writeCapture(image: image, name: name, scenarioID: scenario.id, assetsURL: assetsURL, records: &records)
                    coordinator.dismissDocumentationOverflowMenu()
                    overflowMenuRequested = false
                case "stopSession": await coordinator.stop()
                default: break
                }
                if !overflowMenuRequested { await settleAsync(seconds: 0.08) }
            }
        }

        await coordinator.stop()
        permission?.close(); settings?.close(); selectionController.closeDocumentationPreview()
        fixture.close(); backdrop.close(); bootstrap.close()
        let manifest = DocumentationManifest(
            schemaVersion: 1,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            scenarios: records,
            coveredUIItems: OverlayControlBarCatalog.items.map { $0.id.rawValue }
        )
        try DocumentationJSON.write(manifest, to: outputURL.appendingPathComponent("manifest.json"))
    }

    private static func documentationScreen(arguments: [String]) -> NSScreen? {
        let configured = value("--documentation-display-id=", arguments: arguments)
            ?? ProcessInfo.processInfo.environment["REARVIEW_DOCUMENTATION_DISPLAY_ID"]
        if let configured, let id = UInt32(configured) {
            return NSScreen.screens.first { displayID(for: $0) == id }
        }
        // Prefer a dedicated non-main display. A single-display setup remains
        // usable for development; CI should set the display ID explicitly.
        if let secondary = NSScreen.screens.first(where: { $0 != NSScreen.main }) { return secondary }
        return NSScreen.main ?? NSScreen.screens.first
    }

    private static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    private static func waitForTranslationSession(_ broker: TranslationBroker) async throws {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if broker.documentationSessionReady { return }
            await settleAsync(seconds: 0.1)
        }
        throw DocumentationError.captureFailed("Apple Translation session did not become ready")
    }

    private static func waitForTranslatedFrame(
        _ coordinator: SessionCoordinator, broker: TranslationBroker
    ) async throws {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if coordinator.documentationHasTranslatedFrame() { return }
            await settleAsync(seconds: 0.1)
        }
        let translation = broker.documentationLastError.map { ", translationError=\($0)" } ?? ""
        throw DocumentationError.captureFailed(
            "Vision OCR or translation produced no visible result (\(coordinator.documentationProcessingSummary())\(translation))"
        )
    }

    private static func writeCapture(
        image: CGImage, name: String, scenarioID: String, assetsURL: URL,
        records: inout [DocumentationScreenshotRecord]
    ) throws {
        let normalized = rasterize(image: image, width: 1440, height: 900)
        let annotated = annotate(image: normalized, label: name)
        let bitmap = NSBitmapImageRep(cgImage: annotated)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw DocumentationError.captureFailed("could not encode PNG")
        }
        let url = assetsURL.appendingPathComponent("\(name).png")
        try data.write(to: url, options: .atomic)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        records.append(DocumentationScreenshotRecord(
            scenarioID: scenarioID, name: name, path: "assets/\(name).png",
            width: annotated.width, height: annotated.height, sha256: hash
        ))
    }

    private static func annotate(image: CGImage, label: String) -> CGImage {
        let size = NSSize(width: image.width, height: image.height)
        let canvas = NSImage(cgImage: image, size: size)
        canvas.lockFocus()
        let badge = CGRect(x: 24, y: size.height - 56, width: 250, height: 32)
        NSColor.black.withAlphaComponent(0.78).setFill()
        NSBezierPath(roundedRect: badge, xRadius: 8, yRadius: 8).fill()
        (label as NSString).draw(
            at: CGPoint(x: badge.minX + 12, y: badge.minY + 8),
            withAttributes: [.font: NSFont.systemFont(ofSize: 14, weight: .semibold), .foregroundColor: NSColor.white]
        )
        canvas.unlockFocus()
        return canvas.cgImage(forProposedRect: nil, context: nil, hints: nil) ?? image
    }

    private static func rasterize(image: CGImage, width: Int, height: Int) -> CGImage {
        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bitmapFormat: [],
            bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: representation) else { return image }
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
        NSImage(cgImage: image, size: NSSize(width: width, height: height)).draw(
            in: CGRect(x: 0, y: 0, width: width, height: height), from: .zero, operation: .copy, fraction: 1
        )
        NSGraphicsContext.restoreGraphicsState()
        return representation.cgImage ?? image
    }

    private static func value(_ prefix: String, arguments: [String]) -> String? {
        arguments.first(where: { $0.hasPrefix(prefix) }).map { String($0.dropFirst(prefix.count)) }
    }

    private static func validateCoverage(_ file: DocumentationScenarioFile) throws {
        let actions = file.scenarios.flatMap(\.actions)
        guard actions.contains(where: { $0.type == "showToolbarOverflow" }) else {
            throw DocumentationError.invalidInput("toolbar coverage is missing: add a showToolbarOverflow action")
        }
        let categories = Set(file.scenarios.flatMap { $0.actions.compactMap { $0.type == "showSettings" ? $0.category : nil } })
        let missing = ["general", "shortcuts", "display", "captureOCR"].filter { !categories.contains($0) }
        guard missing.isEmpty else { throw DocumentationError.invalidInput("settings coverage is missing: \(missing.joined(separator: ", "))") }
    }

    private static func applySetting(_ action: DocumentationAction, coordinator: SessionCoordinator) {
        switch action.name {
        case "protectNonSourceText": coordinator.setProtectsNonSourceText(action.value == "true")
        case "displayMode": coordinator.setDisplayMode(action.value == "overlay" ? .overlay : .mirror)
        case "refreshMode": coordinator.setRefreshMode(action.value == "manual" ? .manual : .automatic)
        default: break
        }
    }

    private static func settle(seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    /// Documentation mode runs on MainActor but does not enter
    /// `NSApplication.run()`.  A nested RunLoop can keep AppKit drawing alive,
    /// yet it prevents MainActor tasks (including OCR result delivery and the
    /// translation broker) from resuming.  Yield with an async sleep instead.
    private static func settleAsync(seconds: TimeInterval) async {
        guard seconds > 0 else { return }
        try? await Task.sleep(for: .milliseconds(max(1, Int((seconds * 1_000).rounded()))))
    }
}

#endif
