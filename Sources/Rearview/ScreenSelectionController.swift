import AppKit

func shouldDisplaySelectionTargetPreview(
    requestID: UInt64, lastDisplayedRequestID: UInt64
) -> Bool {
    requestID > lastDisplayedRequestID
}

enum SelectionTargetPreview: Equatable {
    case application(CaptureApplication)
    case allContent

    var title: String {
        switch self {
        case .application(let application): application.name
        case .allContent: L10n.text("모든 앱")
        }
    }
}

/// Geometry-only placement for the two selection-screen badges. Keeping the
/// collision policy independent from drawing makes the cursor-corner behavior
/// testable without creating a selection window.
enum SelectionBadgePlacement {
    private enum Corner {
        case topLeft, topRight, bottomLeft, bottomRight

        var oppositeAxisOrder: [Corner] {
            switch self {
            case .topLeft: [.bottomLeft, .topRight, .bottomRight]
            case .topRight: [.bottomRight, .topLeft, .bottomLeft]
            case .bottomLeft: [.topLeft, .bottomRight, .topRight]
            case .bottomRight: [.topRight, .bottomLeft, .topLeft]
            }
        }
    }

    static func targetFrame(
        for selection: CGRect, size: CGSize, in bounds: CGRect,
        inset: CGFloat = 8
    ) -> CGRect? {
        guard size.width > 0, size.height > 0,
              size.width <= bounds.width, size.height <= bounds.height else { return nil }

        let inside = CGRect(
            x: selection.minX + inset,
            y: selection.maxY - size.height - inset,
            width: size.width, height: size.height
        )
        if selection.insetBy(dx: inset, dy: inset).contains(inside), bounds.contains(inside) {
            return inside
        }

        let above = CGRect(
            x: selection.minX + inset,
            y: selection.maxY + inset,
            width: size.width, height: size.height
        )
        if bounds.contains(above) { return above }

        let below = CGRect(
            x: selection.minX + inset,
            y: selection.minY - size.height - inset,
            width: size.width, height: size.height
        )
        if bounds.contains(below) { return below }

        return clamped(
            CGRect(x: selection.minX + inset, y: selection.maxY - size.height - inset,
                   width: size.width, height: size.height), in: bounds
        )
    }

    static func pixelFrame(
        for selection: CGRect, size: CGSize, cursor: CGPoint, in bounds: CGRect,
        avoiding: CGRect?, inset: CGFloat = 8, gap: CGFloat = 4
    ) -> CGRect? {
        guard size.width > 0, size.height > 0,
              size.width <= bounds.width, size.height <= bounds.height else { return nil }

        let preferred: Corner = cursor.x >= selection.midX
            ? (cursor.y >= selection.midY ? .topRight : .bottomRight)
            : (cursor.y >= selection.midY ? .topLeft : .bottomLeft)
        var candidates: [CGRect] = []

        // When the cursor is at the same corner as the target badge, stack the
        // pixel badge underneath it before moving to a distant corner.
        if preferred == .topLeft, let avoiding {
            candidates.append(CGRect(
                x: avoiding.minX,
                y: avoiding.minY - size.height - gap,
                width: size.width, height: size.height
            ))
        }

        let corners = [preferred] + preferred.oppositeAxisOrder
        for corner in corners {
            candidates.append(frame(for: corner, selection: selection, size: size, inset: inset))
            candidates.append(outsideFrame(
                for: corner, selection: selection, size: size, inset: inset
            ))
        }

        let forbidden = avoiding?.insetBy(dx: -gap, dy: -gap)
        for candidate in candidates {
            guard let candidate = clamped(candidate, in: bounds),
                  forbidden.map({ !$0.intersects(candidate) }) ?? true else { continue }
            return candidate
        }
        return nil
    }

    private static func frame(
        for corner: Corner, selection: CGRect, size: CGSize, inset: CGFloat
    ) -> CGRect {
        switch corner {
        case .topLeft:
            CGRect(x: selection.minX + inset, y: selection.maxY - size.height - inset,
                   width: size.width, height: size.height)
        case .topRight:
            CGRect(x: selection.maxX - size.width - inset, y: selection.maxY - size.height - inset,
                   width: size.width, height: size.height)
        case .bottomLeft:
            CGRect(x: selection.minX + inset, y: selection.minY + inset,
                   width: size.width, height: size.height)
        case .bottomRight:
            CGRect(x: selection.maxX - size.width - inset, y: selection.minY + inset,
                   width: size.width, height: size.height)
        }
    }

    private static func outsideFrame(
        for corner: Corner, selection: CGRect, size: CGSize, inset: CGFloat
    ) -> CGRect {
        switch corner {
        case .topLeft:
            CGRect(x: selection.minX - size.width - inset, y: selection.maxY + inset,
                   width: size.width, height: size.height)
        case .topRight:
            CGRect(x: selection.maxX + inset, y: selection.maxY + inset,
                   width: size.width, height: size.height)
        case .bottomLeft:
            CGRect(x: selection.minX - size.width - inset, y: selection.minY - size.height - inset,
                   width: size.width, height: size.height)
        case .bottomRight:
            CGRect(x: selection.maxX + inset, y: selection.minY - size.height - inset,
                   width: size.width, height: size.height)
        }
    }

    private static func clamped(_ rect: CGRect, in bounds: CGRect) -> CGRect? {
        guard rect.width <= bounds.width, rect.height <= bounds.height else { return nil }
        return CGRect(
            x: min(max(rect.minX, bounds.minX), bounds.maxX - rect.width),
            y: min(max(rect.minY, bounds.minY), bounds.maxY - rect.height),
            width: rect.width, height: rect.height
        )
    }
}

struct ScreenSelectionResult {
    let selection: CGRect
    let screen: NSScreen
    let initialDockingState: MirrorDockingState
    let displayMode: TranslationDisplayMode
}

@MainActor
final class ScreenSelectionController {
    private var panels: [SelectionPanel] = []
    private var completion: ((Result<ScreenSelectionResult, Error>) -> Void)?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private lazy var placementProbe = MirrorPlacementProbe()
    private let targetResolver: any SessionTargetResolver

    init(targetResolver: any SessionTargetResolver = CaptureApplicationPicker()) {
        self.targetResolver = targetResolver
    }

    var isSelecting: Bool { completion != nil }

    @discardableResult
    func select(
        displayMode: TranslationDisplayMode,
        dockingShortcuts: [MirrorDockingState: ToolbarHotKey],
        displayModeShortcut: ToolbarHotKey?,
        presentationState: RegionBorderController.PresentationState,
        regionBorderOpacity: CGFloat,
        completion: @escaping (Result<ScreenSelectionResult, Error>) -> Void
    ) -> Bool {
        guard !isSelecting else { return false }
        self.completion = completion
        for screen in NSScreen.screens {
            let panel = SelectionPanel(
                screen: screen, displayMode: displayMode,
                dockingState: MirrorDockingState.load(), dockingShortcuts: dockingShortcuts,
                displayModeShortcut: displayModeShortcut,
                presentationState: presentationState,
                regionBorderOpacity: regionBorderOpacity,
                placementProbe: placementProbe,
                targetResolver: targetResolver
            )
            panel.selectionHandler = { [weak self, weak panel] rect, dockingState, displayMode in
                guard let self, let panel else { return }
                guard let screen = NSScreen.screens.first(where: {
                    displayID(for: $0) == panel.targetDisplayID
                }) else {
                    self.finish(.failure(CancellationError()))
                    return
                }
                let result: Result<ScreenSelectionResult, Error> = rect.width >= 32 && rect.height >= 20
                    ? .success(ScreenSelectionResult(
                        selection: rect, screen: screen,
                        initialDockingState: dockingState, displayMode: displayMode
                    ))
                    : .failure(TranslatorError.invalidSelection)
                self.finish(result)
            }
            panel.cancelHandler = { [weak self] in self?.finish(.failure(CancellationError())) }
            panels.append(panel)
        }
        installObservers()
        activateSelectionPanels()
        return true
    }

    func cancel() {
        guard isSelecting else { return }
        finish(.failure(CancellationError()))
    }

    private func installObservers() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let spaceObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: NSWorkspace.shared,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.activateSelectionPanels() }
        }
        observers.append((workspaceCenter, spaceObserver))

        let applicationCenter = NotificationCenter.default
        let screenObserver = applicationCenter.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.cancel() }
        }
        observers.append((applicationCenter, screenObserver))
    }

    private func activateSelectionPanels() {
        guard isSelecting else { return }
        panels.forEach { $0.orderFrontRegardless() }
        let mouseLocation = NSEvent.mouseLocation
        let keyPanel = panels.first { $0.targetScreen.frame.contains(mouseLocation) }
            ?? panels.first
        NSApp.activate()
        keyPanel?.activateSelectionView()
    }

    private func finish(_ result: Result<ScreenSelectionResult, Error>) {
        guard let callback = completion else { return }
        completion = nil
        observers.forEach { center, observer in center.removeObserver(observer) }
        observers.removeAll()
        panels.forEach { $0.close() }
        panels.removeAll()
        callback(result)
    }
}

private func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
    (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
}

/// App-lifetime helper that answers "where would the real mirror window
/// appear for this selection?" by asking AppKit's own placement logic
/// (`NSWindow.center()`) on a hidden stand-in window that replicates the
/// mirror window's chrome and content setup order. Reused across selection
/// sessions; never shown.
@MainActor
fileprivate final class MirrorPlacementProbe {
    let window: NSPanel

    init() {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        // Replicate TranslationMirrorWindow's chrome so the queried frame
        // size (content + chrome) matches the real window exactly.
        panel.isFloatingPanel = true
        panel.titleVisibility = .hidden
        panel.toolbarStyle = .unifiedCompact
        let toolbar = NSToolbar(identifier: "MirrorPlacementProbeToolbar")
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        panel.toolbar = toolbar
        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .left
        accessory.view = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: OverlayControlBarMetrics.height))
        accessory.preferredContentSize = NSSize(
            width: 200, height: OverlayControlBarMetrics.height
        )
        panel.addTitlebarAccessoryViewController(accessory)
        window = panel
    }

    /// The frame `NSWindow.center()` would give the real mirror window
    /// whose content is `selectionSize` on `screen`, using the same content
    /// sizing (`defaultMirrorContentFrame`) and the same setup order as the
    /// real window's init.
    func undockedFrame(selectionSize: CGSize, screen: NSScreen) -> CGRect {
        let visibleFrame = screen.visibleFrame
        let contentFrame = defaultMirrorContentFrame(
            selectionSize: selectionSize, visibleFrame: visibleFrame
        )
        // Anchor the probe inside the target screen so `center()` bases its
        // placement on that screen's visible frame (multi-display).
        window.setFrameOrigin(NSPoint(x: visibleFrame.minX + 16, y: visibleFrame.minY + 16))
        window.setContentSize(contentFrame.size)
        window.center()
        return window.frame
    }
}

@MainActor
private final class SelectionPanel: NSPanel {
    let targetScreen: NSScreen
    let targetDisplayID: CGDirectDisplayID?
    var selectionHandler: ((CGRect, MirrorDockingState, TranslationDisplayMode) -> Void)?
    var cancelHandler: (() -> Void)?

    init(
        screen: NSScreen, displayMode: TranslationDisplayMode,
        dockingState: MirrorDockingState,
        dockingShortcuts: [MirrorDockingState: ToolbarHotKey],
        displayModeShortcut: ToolbarHotKey?,
        presentationState: RegionBorderController.PresentationState,
        regionBorderOpacity: CGFloat,
        placementProbe: MirrorPlacementProbe,
        targetResolver: any SessionTargetResolver = CaptureApplicationPicker()
    ) {
        targetScreen = screen
        targetDisplayID = displayID(for: screen)
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hidesOnDeactivate = false
        // Keep the active selection UI visible while the user changes Spaces.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let localVisibleFrame = screen.visibleFrame.offsetBy(
            dx: -screen.frame.minX, dy: -screen.frame.minY
        )
        let safeTopY = min(
            localVisibleFrame.maxY,
            screen.frame.height - screen.safeAreaInsets.top
        )
        let view = SelectionView(
            frame: CGRect(origin: .zero, size: screen.frame.size),
            safeTopY: safeTopY, displayMode: displayMode,
            dockingState: dockingState, dockingShortcuts: dockingShortcuts,
            displayModeShortcut: displayModeShortcut,
            presentationState: presentationState,
            regionBorderOpacity: regionBorderOpacity,
            placementProbe: placementProbe,
            targetResolver: targetResolver
        )
        view.onComplete = { [weak self] localRect, dockingState, displayMode in
            guard let self else { return }
            let global = localRect.offsetBy(dx: self.frame.minX, dy: self.frame.minY)
            self.selectionHandler?(global, dockingState, displayMode)
        }
        view.onCancel = { [weak self] in self?.cancelHandler?() }
        contentView = view
    }

    override var canBecomeKey: Bool { true }

    func activateSelectionView() {
        makeKeyAndOrderFront(nil)
        makeFirstResponder(contentView)
    }
}

@MainActor
private final class SelectionView: NSView {
    var onComplete: ((CGRect, MirrorDockingState, TranslationDisplayMode) -> Void)?
    var onCancel: (() -> Void)?
    private var start: CGPoint?
    private var current: CGPoint?
    private let safeTopY: CGFloat
    private var displayMode: TranslationDisplayMode
    private var dockingState: MirrorDockingState
    private let dockingShortcuts: [MirrorDockingState: ToolbarHotKey]
    /// The user's configured mirror/overlay toggle shortcut, usable during
    /// selection so the ghost preview can be switched before committing.
    private let displayModeShortcut: ToolbarHotKey?
    private let placementProbe: MirrorPlacementProbe
    private let targetResolver: any SessionTargetResolver
    /// Matches the persistent region border's presentation state so the
    /// selection border uses the same color (e.g. purple in manual mode).
    private let presentationState: RegionBorderController.PresentationState
    /// Applies the user's "영역 테두리 불투명도" setting to the selection
    /// border so both phases render identically.
    private let regionBorderOpacity: CGFloat
    /// Decays from 1 to 0 right after a docking shortcut toggles, briefly
    /// brightening the docking seam so the "attached" state is obvious.
    private var seamFlash: CGFloat = 0
    private nonisolated(unsafe) var seamFlashTimer: Timer?
    private static let targetPreviewInterval: Duration = .milliseconds(150)
    private var targetPreviewState: SelectionTargetPreview?
    private var cachedTargetPreviewState: SelectionTargetPreview?
    private var cachedTargetPreviewIcon: NSImage?
    private var targetPreviewWorker: Task<Void, Never>?
    private var pendingTargetPreview: (
        selection: CGRect, screen: NSScreen, requestID: UInt64, dragGeneration: UInt64
    )?
    private var targetPreviewRequestID: UInt64 = 0
    private var lastDisplayedTargetPreviewRequestID: UInt64 = 0
    private var targetPreviewDragGeneration: UInt64 = 0
    private var lastTargetPreviewStart: ContinuousClock.Instant?

    init(
        frame frameRect: NSRect, safeTopY: CGFloat,
        displayMode: TranslationDisplayMode, dockingState: MirrorDockingState,
        dockingShortcuts: [MirrorDockingState: ToolbarHotKey],
        displayModeShortcut: ToolbarHotKey?,
        presentationState: RegionBorderController.PresentationState,
        regionBorderOpacity: CGFloat,
        placementProbe: MirrorPlacementProbe,
        targetResolver: any SessionTargetResolver
    ) {
        self.safeTopY = safeTopY
        self.displayMode = displayMode
        self.dockingState = dockingState
        self.dockingShortcuts = dockingShortcuts
        self.displayModeShortcut = displayModeShortcut
        self.presentationState = presentationState
        self.regionBorderOpacity = RegionBorderOpacity.clamp(regionBorderOpacity)
        self.placementProbe = placementProbe
        self.targetResolver = targetResolver
        super.init(frame: frameRect)
    }

    deinit {
        seamFlashTimer?.invalidate()
        targetPreviewWorker?.cancel()
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        resetTargetPreview()
        start = constrainedPoint(for: event)
        current = start
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        current = constrainedPoint(for: event)
        needsDisplay = true
        guard let rect = activeSelectionRect,
              rect.width >= 32, rect.height >= 20,
              let panel = window as? SelectionPanel else { return }
        let globalRect = rect.offsetBy(dx: panel.frame.minX, dy: panel.frame.minY)
        requestTargetPreview(for: globalRect, on: panel.targetScreen)
    }

    override func mouseUp(with event: NSEvent) {
        current = constrainedPoint(for: event)
        guard let rect = selectionRect else { return }
        onComplete?(rect, dockingState, displayMode)
    }

    private func resetTargetPreview() {
        targetPreviewDragGeneration &+= 1
        pendingTargetPreview = nil
        targetPreviewState = nil
        cachedTargetPreviewState = nil
        cachedTargetPreviewIcon = nil
        lastDisplayedTargetPreviewRequestID = 0
        lastTargetPreviewStart = nil
    }

    private func requestTargetPreview(for selection: CGRect, on screen: NSScreen) {
        targetPreviewRequestID &+= 1
        pendingTargetPreview = (
            selection: selection, screen: screen,
            requestID: targetPreviewRequestID, dragGeneration: targetPreviewDragGeneration
        )
        guard targetPreviewWorker == nil else { return }
        targetPreviewWorker = Task { @MainActor [weak self] in
            await self?.runTargetPreviewWorker()
        }
    }

    private func runTargetPreviewWorker() async {
        defer { targetPreviewWorker = nil }
        while !Task.isCancelled {
            guard let request = pendingTargetPreview else { return }
            pendingTargetPreview = nil

            if let lastTargetPreviewStart {
                let elapsed = lastTargetPreviewStart.duration(to: .now)
                if elapsed < Self.targetPreviewInterval {
                    try? await Task.sleep(for: Self.targetPreviewInterval - elapsed)
                }
            }
            guard !Task.isCancelled else { return }

            lastTargetPreviewStart = .now
            do {
                let resolution = try await targetResolver.resolveTarget(
                    for: request.selection, on: request.screen
                )
                guard !Task.isCancelled,
                      request.dragGeneration == targetPreviewDragGeneration,
                      shouldDisplaySelectionTargetPreview(
                          requestID: request.requestID,
                          lastDisplayedRequestID: lastDisplayedTargetPreviewRequestID
                      ) else { continue }
                lastDisplayedTargetPreviewRequestID = request.requestID
                switch resolution.target {
                case .application(let application):
                    setTargetPreview(.application(application))
                case .allContent:
                    setTargetPreview(.allContent)
                }
                needsDisplay = true
            } catch {
                // A transient query failure must not replace the last normal
                // preview. The next drag update will retry naturally.
            }
        }
    }

    private func setTargetPreview(_ state: SelectionTargetPreview) {
        targetPreviewState = state
        guard cachedTargetPreviewState != state else { return }
        cachedTargetPreviewState = state
        switch state {
        case .application(let application):
            let icon = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: application.bundleIdentifier
            ).map { NSWorkspace.shared.icon(forFile: $0.path) }
                ?? NSImage(systemSymbolName: "app", accessibilityDescription: application.name)
            icon?.size = CGSize(width: 16, height: 16)
            cachedTargetPreviewIcon = icon
        case .allContent:
            let symbol = NSImage(
                systemSymbolName: "square.stack.3d.up",
                accessibilityDescription: L10n.text("모든 앱")
            )
            let configuration = NSImage.SymbolConfiguration(
                pointSize: 16, weight: .medium
            ).applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
            cachedTargetPreviewIcon = symbol?.withSymbolConfiguration(configuration) ?? symbol
        }
    }

    private func constrainedPoint(for event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX),
            y: min(max(point.y, bounds.minY), bounds.maxY)
        )
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?(); return }
        // Selection-screen shortcuts match the bare key only — modifiers are
        // ignored while selecting.
        if let displayModeShortcut, displayModeShortcut.isEnabled,
           UInt32(event.keyCode) == displayModeShortcut.keyCode {
            displayMode = displayMode == .mirror ? .overlay : .mirror
            needsDisplay = true
            return
        }
        if displayMode == .mirror,
           let requested = dockingShortcuts.first(where: { _, shortcut in
               shortcut.isEnabled && UInt32(event.keyCode) == shortcut.keyCode
           })?.key {
            let previous = dockingState
            dockingState = dockingState.toggled(with: requested)
            if dockingState != previous { startSeamFlash() }
            needsDisplay = true
            return
        }
        super.keyDown(with: event)
    }

    private func startSeamFlash() {
        seamFlash = 1
        seamFlashTimer?.invalidate()
        seamFlashTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) {
            [weak self] timer in
            // The timer is scheduled on the main run loop, so the main-actor
            // state is safe to touch here; `timer` itself stays outside the
            // isolated block to avoid crossing isolation regions.
            let finished = MainActor.assumeIsolated {
                guard let self else { return true }
                self.seamFlash = max(0, self.seamFlash - 0.06)
                self.needsDisplay = true
                return self.seamFlash == 0
            }
            if finished { timer.invalidate() }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = activeSelectionRect
        drawDim(selection: rect)
        if let rect {
            drawSelectionBorder(for: rect)
            let ghostFrame = drawOutputPreview(for: rect)
            drawDockingSeam(selection: rect, ghostFrame: ghostFrame)
            let targetBadgeFrame = drawTargetPreviewBadge(for: rect)
            drawSelectionBadge(for: rect, avoiding: targetBadgeFrame)
        }
        drawInstructions()
    }

    private var activeSelectionRect: CGRect? {
        guard let rect = selectionRect, rect.width >= 1, rect.height >= 1 else { return nil }
        return rect
    }

    /// Dims everything outside the selection with a flat overlay and cuts a
    /// crisp rounded hole at the border: only the selection interior stays
    /// bright, with no soft falloff or glow around the edge.
    private func drawDim(selection: CGRect?) {
        let dimMax = RegionBorderTuning.dimMaxAlpha
        guard let selection, selection.width >= 1, selection.height >= 1 else {
            NSColor.black.withAlphaComponent(dimMax).setFill()
            bounds.fill()
            return
        }
        NSColor.black.withAlphaComponent(dimMax).setFill()
        bounds.fill()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.compositingOperation = .clear
        NSBezierPath(
            roundedRect: selection,
            xRadius: RegionBorderTuning.cornerRadius,
            yRadius: RegionBorderTuning.cornerRadius
        ).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Renders the selection outline with the shared region-border effect
    /// stack (layered outer shadow, inner glow, base stroke), the same state
    /// color (e.g. purple in manual mode) and the same opacity setting as the
    /// persistent region border.
    private func drawSelectionBorder(for rect: CGRect) {
        let borderColor = regionPresentationColor(for: presentationState)
        let opacity = regionBorderOpacity
        let shape = NSBezierPath(
            roundedRect: rect,
            xRadius: RegionBorderTuning.cornerRadius,
            yRadius: RegionBorderTuning.cornerRadius
        )
        shape.close()
        RegionBorderDrawing.drawOuterShadow(
            path: shape, shape: shape, in: bounds,
            layers: RegionBorderTuning.borderShadowLayers, opacity: opacity
        )
        RegionBorderDrawing.drawInnerGlow(
            shape: shape, in: bounds, color: borderColor,
            blur: RegionBorderTuning.innerGlowBlur,
            alpha: opacity * RegionBorderTuning.innerGlowAlpha
        )
        borderColor.withAlphaComponent(opacity).setStroke()
        shape.lineWidth = RegionBorderTuning.borderLineWidth
        shape.stroke()
    }

    /// Draws a ghost sketch of where the output will appear: for mirror mode
    /// a miniature window silhouette (chrome + placeholder text lines), for
    /// overlay mode a sketch of the real control bar (drag handle dots,
    /// button placeholders). Returns the local frame of the drawn ghost so
    /// the docking seam can share the same placement.
    private func drawOutputPreview(for rect: CGRect) -> CGRect? {
        guard let window = window as? SelectionPanel else { return nil }
        let globalSelection = rect.offsetBy(dx: window.frame.minX, dy: window.frame.minY)
        let globalFrame: CGRect?
        if displayMode == .overlay {
            let width = min(max(OverlayControlBarMetrics.minimumWidth, rect.width + 4), bounds.width)
            let aboveY = globalSelection.maxY + 2
            let belowY = globalSelection.minY - OverlayControlBarMetrics.height - 2
            let y = aboveY + OverlayControlBarMetrics.height <= window.targetScreen.visibleFrame.maxY
                ? aboveY : belowY
            globalFrame = CGRect(
                x: globalSelection.midX - width / 2, y: y,
                width: width, height: OverlayControlBarMetrics.height
            )
        } else {
            // Ask AppKit's own placement logic (via the shared probe
            // window) where the real mirror window would land for this
            // selection, so the preview matches the actual window exactly —
            // including the chrome height and the platform's centering
            // behavior. The persisted undocked frame is only restored by
            // the undock toggle, never at session start.
            let probeFrame = placementProbe.undockedFrame(
                selectionSize: globalSelection.size, screen: window.targetScreen
            )
            if dockingState == .undocked {
                globalFrame = mirrorUndockedFrame(
                    savedFrame: nil,
                    defaultFrame: probeFrame,
                    visibleFrames: NSScreen.screens.map(\.visibleFrame)
                )
            } else {
                globalFrame = mirrorDockedFrame(
                    selection: globalSelection, windowSize: probeFrame.size,
                    state: dockingState, visibleFrames: NSScreen.screens.map(\.visibleFrame),
                    chromeHeight: OverlayControlBarMetrics.height,
                    borderOutset: RegionBorderTuning.borderOutset,
                    alignment: MirrorDockAlignment.shortcutDefault(for: dockingState)
                )?.frame
            }
        }
        guard let globalFrame else { return nil }
        let localFrame = globalFrame.offsetBy(dx: -window.frame.minX, dy: -window.frame.minY)
        switch displayMode {
        case .mirror: RegionBorderDrawing.drawSolidGhost(
            frame: localFrame,
            color: regionPresentationColor(for: presentationState),
            in: bounds
        )
        // The overlay control bar ghost uses the same solid style as the
        // mirror ghost; at the bar's fixed 40pt height the titlebar divider
        // is skipped, leaving a plain colored bar.
        case .overlay: RegionBorderDrawing.drawSolidGhost(
            frame: localFrame,
            color: regionPresentationColor(for: presentationState),
            in: bounds
        )
        }
        return localFrame
    }

    /// Glowing seam between the selection and a docked mirror ghost, sharing
    /// the running session's `MirrorDockingSeamView` drawing (same bridge
    /// geometry and border color). Brightens briefly when a docking shortcut
    /// toggles the state.
    private func drawDockingSeam(selection: CGRect, ghostFrame: CGRect?) {
        guard displayMode == .mirror, dockingState != .undocked,
              let ghostFrame,
              let band = mirrorDockingSeamRect(
                  placement: ghostFrame, state: dockingState, selection: selection,
                  borderOutset: RegionBorderTuning.borderOutset,
                  borderShadowReach: RegionBorderTuning.borderShadowReach,
                  chromeHeight: OverlayControlBarMetrics.height
              ),
              band.width >= 1, band.height >= 1 else { return }
        let boost = 0.5 + 0.5 * seamFlash
        RegionBorderDrawing.drawSeam(
            band: band, direction: dockingState,
            color: regionPresentationColor(for: presentationState),
            bandAlpha: RegionBorderTuning.seamBandAlpha * boost,
            lineAlpha: RegionBorderTuning.seamLineAlpha * boost
        )
    }

    /// Draws the last normal target-resolution result at the selection's
    /// upper-left corner. Query errors intentionally leave this state alone,
    /// so a transient WindowServer/ScreenCaptureKit failure cannot make the
    /// badge flicker.
    @discardableResult
    private func drawTargetPreviewBadge(for rect: CGRect) -> CGRect? {
        guard let targetPreviewState else { return nil }
        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let text = targetPreviewState.title as NSString
        let iconSize = CGSize(width: 16, height: 16)
        let maxWidth = min(220, max(96, bounds.width - 16))
        let maxTextWidth = max(40, maxWidth - iconSize.width - 6 - 20)
        let displayText = truncatedBadgeText(text, attributes: textAttributes, maxWidth: maxTextWidth)
        let textSize = displayText.size(withAttributes: textAttributes)
        let badgeSize = CGSize(
            width: min(maxWidth, textSize.width + iconSize.width + 6 + 20),
            height: max(textSize.height, iconSize.height) + 12
        )
        guard let frame = SelectionBadgePlacement.targetFrame(
            for: rect, size: badgeSize, in: bounds
        ) else { return nil }

        drawBadgeBackground(frame)
        targetPreviewIcon()?.draw(
            in: CGRect(
                x: frame.minX + 8,
                y: frame.midY - iconSize.height / 2,
                width: iconSize.width,
                height: iconSize.height
            ),
            from: .zero, operation: .sourceOver, fraction: 1,
            respectFlipped: true, hints: nil
        )
        displayText.draw(
            at: CGPoint(
                x: frame.minX + 8 + iconSize.width + 6,
                y: frame.midY - textSize.height / 2
            ),
            withAttributes: textAttributes
        )
        return frame
    }

    private func targetPreviewIcon() -> NSImage? {
        cachedTargetPreviewIcon
    }

    private func truncatedBadgeText(
        _ text: NSString, attributes: [NSAttributedString.Key: Any], maxWidth: CGFloat
    ) -> NSString {
        guard text.size(withAttributes: attributes).width > maxWidth else { return text }
        let ellipsis = "…" as NSString
        var length = text.length
        while length > 1 {
            length -= 1
            let candidate = text.substring(with: NSRange(location: 0, length: length)) + "…"
            if (candidate as NSString).size(withAttributes: attributes).width <= maxWidth {
                return candidate as NSString
            }
        }
        return ellipsis
    }

    private func drawBadgeBackground(_ frame: CGRect) {
        let path = NSBezierPath(roundedRect: frame, xRadius: 7, yRadius: 7)
        NSColor.black.withAlphaComponent(0.72).setFill()
        path.fill()
        NSColor.white.withAlphaComponent(0.10).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    /// Pixel pill anchored at the selection corner nearest the cursor, so the
    /// digits stay close to where the user is looking. If that corner is
    /// occupied by the target pill, placement tries a stacked position and
    /// then the remaining corners.
    private func drawSelectionBadge(for rect: CGRect, avoiding: CGRect?) {
        guard let window = window else { return }
        let scale = max(1, window.backingScaleFactor)
        let globalRect = rect.offsetBy(dx: window.frame.minX, dy: window.frame.minY)
        let aligned = pixelAlignedCaptureRect(
            selection: globalRect, screenFrame: window.frame, backingScale: scale
        )
        let width = Int((aligned.width * scale).rounded())
        let height = Int((aligned.height * scale).rounded())
        let text = "\(width) × \(height) px" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let textSize = text.size(withAttributes: attributes)
        let pillSize = CGSize(width: textSize.width + 20, height: textSize.height + 12)
        let point = current ?? rect.origin
        guard let pillRect = SelectionBadgePlacement.pixelFrame(
            for: rect, size: pillSize, cursor: point, in: bounds, avoiding: avoiding
        ) else { return }
        drawBadgeBackground(pillRect)
        text.draw(
            at: CGPoint(x: pillRect.midX - textSize.width / 2,
                        y: pillRect.midY - textSize.height / 2),
            withAttributes: attributes
        )
    }

    private func drawInstructions() {
        let firstText = L10n.text("드래그하여 영역 선택  ·  Esc로 취소") as NSString
        let firstAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let firstSize = firstText.size(withAttributes: firstAttributes)

        // Below the drag hint: one "label: key" line per selection single key.
        let detailAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.85)
        ]
        var details: [(NSString, NSSize)] = []
        if let displayModeShortcut, displayModeShortcut.isEnabled {
            let text = "\(SelectionShortcutAction.displayMode.title): \(displayModeShortcut.keyLabel)" as NSString
            details.append((text, text.size(withAttributes: detailAttributes)))
        }
        // Docking keys only work in mirror mode, so both docking lines appear
        // and disappear dynamically with the current display mode.
        if displayMode == .mirror {
            let dockLabels = [MirrorDockingState.top, .bottom, .left, .right].compactMap { state in
                guard let shortcut = dockingShortcuts[state], shortcut.isEnabled else { return nil }
                return shortcut.keyLabel
            }.joined()
            if !dockLabels.isEmpty {
                let text = "\(L10n.text("미러 도킹")): \(dockLabels)" as NSString
                details.append((text, text.size(withAttributes: detailAttributes)))
            }
            // When the mirror is docked, pressing the same direction again
            // undocks: surface that with a dynamic line showing the docked
            // direction's key.
            if dockingState != .undocked,
               let dockedShortcut = dockingShortcuts[dockingState],
               dockedShortcut.isEnabled {
                let text = "\(L10n.text("미러 도킹 해제")): \(dockedShortcut.keyLabel)" as NSString
                details.append((text, text.size(withAttributes: detailAttributes)))
            }
        }

        let padding = CGSize(width: 28, height: 16)
        let lineGap: CGFloat = 4
        let detailsHeight = details.reduce(CGFloat(0)) { $0 + $1.1.height }
            + (details.isEmpty ? 0 : lineGap * CGFloat(details.count - 1))
        let contentHeight = firstSize.height
            + (details.isEmpty ? 0 : lineGap + detailsHeight)
        let width = details.reduce(firstSize.width) { max($0, $1.1.width) } + padding.width
        let backgroundRect = CGRect(
            x: bounds.midX - width / 2,
            y: min(bounds.maxY, safeTopY) - contentHeight - padding.height - 16,
            width: width,
            height: contentHeight + padding.height
        )
        NSColor.black.withAlphaComponent(0.68).setFill()
        NSBezierPath(roundedRect: backgroundRect, xRadius: 8, yRadius: 8).fill()
        let contentTop = backgroundRect.midY + contentHeight / 2
        var lineBottom = contentTop - firstSize.height
        firstText.draw(
            at: CGPoint(x: backgroundRect.midX - firstSize.width / 2, y: lineBottom),
            withAttributes: firstAttributes
        )
        lineBottom -= lineGap
        for (text, size) in details {
            lineBottom -= size.height
            text.draw(
                at: CGPoint(x: backgroundRect.midX - size.width / 2, y: lineBottom),
                withAttributes: detailAttributes
            )
        }
    }

    private var selectionRect: CGRect? {
        guard let start, let current else { return nil }
        return CGRect(
            x: min(start.x, current.x), y: min(start.y, current.y),
            width: abs(start.x - current.x), height: abs(start.y - current.y)
        )
    }
}

@MainActor
func selectionPanelContractViolationsForSelfTest() -> [String] {
    guard let screen = NSScreen.main ?? NSScreen.screens.first else {
        return ["selection panel requires an available screen"]
    }
    let probe = MirrorPlacementProbe()
    defer { probe.window.close() }
    let panel = SelectionPanel(
        screen: screen, displayMode: .mirror, dockingState: .undocked,
        dockingShortcuts: [:], displayModeShortcut: nil,
        presentationState: .automatic,
        regionBorderOpacity: 1, placementProbe: probe
    )
    defer { panel.close() }
    var violations: [String] = []
    if panel.hidesOnDeactivate {
        violations.append("selection panel must remain visible while the app is inactive")
    }
    if !panel.collectionBehavior.contains(.canJoinAllSpaces) {
        violations.append("selection panel must appear in every Space")
    }
    if !panel.collectionBehavior.contains(.fullScreenAuxiliary) {
        violations.append("selection panel must appear in full-screen Spaces")
    }
    if !panel.canBecomeKey {
        violations.append("selection panel must become key for selection input")
    }
    return violations
}

/// The placement probe must answer with the frame AppKit itself would give
/// the real mirror window, without encoding any platform-specific formula:
/// never shown, deterministic, the real content-plus-chrome size, kept on
/// screen for fitting selections, and keeping an oversized window's
/// titlebar reachable.
@MainActor
func mirrorPlacementProbeContractViolationsForSelfTest() -> [String] {
    guard let screen = NSScreen.main ?? NSScreen.screens.first else {
        return ["mirror placement probe requires an available screen"]
    }
    let probe = MirrorPlacementProbe()
    defer { probe.window.close() }
    var violations: [String] = []
    if probe.window.isVisible {
        violations.append("mirror placement probe window must never be shown")
    }
    let visibleFrame = screen.visibleFrame
    let fittingSelection = CGSize(
        width: min(800, visibleFrame.width * 0.5),
        height: min(600, visibleFrame.height * 0.5)
    )
    let expectedContent = defaultMirrorContentFrame(
        selectionSize: fittingSelection, visibleFrame: visibleFrame
    )
    let first = probe.undockedFrame(selectionSize: fittingSelection, screen: screen)
    if probe.undockedFrame(selectionSize: fittingSelection, screen: screen) != first {
        violations.append("mirror placement probe must be deterministic")
    }
    if abs(first.width - expectedContent.width) > 0.5 {
        violations.append("mirror placement probe width must match the content width")
    }
    if first.height <= expectedContent.height + 0.5 {
        violations.append("mirror placement probe height must include the chrome")
    }
    if first.minX < visibleFrame.minX - 0.5 || first.maxX > visibleFrame.maxX + 0.5
        || first.minY < visibleFrame.minY - 0.5 || first.maxY > visibleFrame.maxY + 0.5 {
        violations.append("mirror placement probe must keep a fitting window inside the visible frame")
    }
    let oversized = probe.undockedFrame(
        selectionSize: CGSize(width: 800, height: visibleFrame.height + 400),
        screen: screen
    )
    if oversized.maxY > visibleFrame.maxY + 0.5 {
        violations.append("mirror placement probe must keep an oversized window's titlebar on screen")
    }
    return violations
}
