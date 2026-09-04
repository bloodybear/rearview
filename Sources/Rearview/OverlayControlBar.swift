import AppKit

@MainActor
private final class OverlayControlBarDragView: NSView {
    enum Phase { case began, changed, ended }

    var onDrag: ((Phase, CGPoint) -> Void)?
    var onHoverChange: ((Bool) -> Void)?
    private var dragCursorPushed = false
    private var trackingAreaReference: NSTrackingArea?

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func updateTrackingAreas() {
        if let trackingAreaReference { removeTrackingArea(trackingAreaReference) }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(trackingArea)
        trackingAreaReference = trackingArea
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { onHoverChange?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChange?(false) }

    override func mouseDown(with event: NSEvent) {
        if !dragCursorPushed {
            NSCursor.closedHand.push()
            dragCursorPushed = true
        }
        onDrag?(.began, NSEvent.mouseLocation)
    }

    override func mouseDragged(with event: NSEvent) {
        onDrag?(.changed, NSEvent.mouseLocation)
    }

    override func mouseUp(with event: NSEvent) {
        onDrag?(.ended, NSEvent.mouseLocation)
        restoreCursorIfNeeded()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { restoreCursorIfNeeded() }
        super.viewWillMove(toWindow: newWindow)
    }

    private func restoreCursorIfNeeded() {
        guard dragCursorPushed else { return }
        NSCursor.pop()
        dragCursorPushed = false
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.secondaryLabelColor.setFill()
        let radius: CGFloat = 1.25
        let spacing: CGFloat = 5
        for column in 0 ..< 2 {
            for row in 0 ..< 3 {
                let center = CGPoint(
                    x: bounds.midX + CGFloat(column * 2 - 1) * spacing / 2,
                    y: bounds.midY + CGFloat(row - 1) * spacing
                )
                NSBezierPath(
                    ovalIn: CGRect(
                        x: center.x - radius, y: center.y - radius,
                        width: radius * 2, height: radius * 2
                    )
                ).fill()
            }
        }
    }
}

@MainActor
private final class OverlayControlBarContainerView: NSView {
    var onPointerActivity: (() -> Void)?
    var onDrag: ((OverlayControlBarDragView.Phase, CGPoint) -> Void)?
    var usesStandardWindowDrag = false
    weak var windowDragRegion: NSView?
    private var trackingAreaReference: NSTrackingArea?

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if hit === self || hit === windowDragRegion
            || hit is NSStackView || hit is NSVisualEffectView {
            return self
        }
        return hit
    }

    override func mouseDown(with event: NSEvent) {
        if usesStandardWindowDrag, let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.performDrag(with: event)
            return
        }
        onDrag?(.began, NSEvent.mouseLocation)
    }

    override func mouseDragged(with event: NSEvent) {
        guard !usesStandardWindowDrag else { return }
        onDrag?(.changed, NSEvent.mouseLocation)
    }

    override func mouseUp(with event: NSEvent) {
        guard !usesStandardWindowDrag else { return }
        onDrag?(.ended, NSEvent.mouseLocation)
    }

    override func updateTrackingAreas() {
        if let trackingAreaReference { removeTrackingArea(trackingAreaReference) }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(trackingArea)
        trackingAreaReference = trackingArea
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { onPointerActivity?() }
    override func mouseMoved(with event: NSEvent) { onPointerActivity?() }
    override func mouseExited(with event: NSEvent) { onPointerActivity?() }
}

enum OverlayControlBarItemID: String, CaseIterable, Sendable {
    case application
    case displayMode
    case translationDirection
    case protectNonSourceText
    case refreshMode
    case mouseEvents
    case pause
    case translate
    case copyAll
    case copyImage
    case saveImage
    case search
    case selection
    case zoomOut
    case zoomActual
    case zoomIn
    case fitWindowToContent
    case followSelectionSize
    case docking
    case opacity
    case debug
}

enum OverlayControlBarItemGroup: Equatable, Sendable {
    case leading
    case trailing
}

enum OverlayControlBarOverflowPresentation: Sendable {
    case applicationMenu
    case displayModeAction
    case translationDirectionAction
    case protectNonSourceTextAction
    case refreshModeMenu
    case pauseAction
    case translateAction
    case copyAllAction
    case copyImageAction
    case saveImageAction
    case searchAction
    case selectionAction
    case mouseEventsAction
    case zoomOutAction
    case zoomActualAction
    case zoomInAction
    case fitWindowToContentAction
    case followSelectionSizeAction
    case dockingMenu
    case opacityPopover
    case debugAction
}

struct OverlayControlBarItemDefinition: Sendable {
    let id: OverlayControlBarItemID
    let group: OverlayControlBarItemGroup
    let width: CGFloat
    let overflowPresentation: OverlayControlBarOverflowPresentation
    let requiresDebugFeatures: Bool
    let modes: [TranslationDisplayMode]

    init(
        id: OverlayControlBarItemID, group: OverlayControlBarItemGroup, width: CGFloat,
        overflowPresentation: OverlayControlBarOverflowPresentation,
        requiresDebugFeatures: Bool = false,
        modes: [TranslationDisplayMode] = [.mirror, .overlay]
    ) {
        self.id = id
        self.group = group
        self.width = width
        self.overflowPresentation = overflowPresentation
        self.requiresDebugFeatures = requiresDebugFeatures
        self.modes = modes
    }
}

enum OverlayControlBarCatalog {
    static let items: [OverlayControlBarItemDefinition] = [
        .init(id: .application, group: .leading,
              width: OverlayControlBarMetrics.applicationWidth,
              overflowPresentation: .applicationMenu),
        .init(id: .displayMode, group: .leading,
              width: OverlayControlBarMetrics.displayModeWidth,
              overflowPresentation: .displayModeAction),
        .init(id: .translationDirection, group: .leading,
              width: OverlayControlBarMetrics.displayModeWidth,
              overflowPresentation: .translationDirectionAction),
        .init(id: .protectNonSourceText, group: .leading,
              width: OverlayControlBarMetrics.iconControlWidth,
              overflowPresentation: .protectNonSourceTextAction),
        .init(id: .refreshMode, group: .leading,
              width: OverlayControlBarMetrics.refreshModeWidth,
              overflowPresentation: .refreshModeMenu),
        .init(id: .mouseEvents, group: .leading, width: OverlayControlBarMetrics.iconControlWidth,
              overflowPresentation: .mouseEventsAction),
        .init(id: .pause, group: .trailing, width: OverlayControlBarMetrics.iconControlWidth,
              overflowPresentation: .pauseAction),
        .init(id: .translate, group: .trailing, width: OverlayControlBarMetrics.iconControlWidth,
              overflowPresentation: .translateAction),
        .init(id: .copyAll, group: .trailing, width: OverlayControlBarMetrics.iconControlWidth,
              overflowPresentation: .copyAllAction),
        .init(id: .copyImage, group: .trailing, width: OverlayControlBarMetrics.iconControlWidth,
              overflowPresentation: .copyImageAction),
        .init(id: .saveImage, group: .trailing, width: OverlayControlBarMetrics.iconControlWidth,
              overflowPresentation: .saveImageAction),
        .init(id: .search, group: .trailing, width: OverlayControlBarMetrics.iconControlWidth,
              overflowPresentation: .searchAction),
        .init(id: .selection, group: .trailing, width: OverlayControlBarMetrics.iconControlWidth,
              overflowPresentation: .selectionAction),
        .init(id: .zoomOut, group: .trailing, width: OverlayControlBarMetrics.iconControlWidth,
              overflowPresentation: .zoomOutAction, modes: [.mirror]),
        .init(id: .zoomActual, group: .trailing, width: OverlayControlBarMetrics.iconControlWidth,
              overflowPresentation: .zoomActualAction, modes: [.mirror]),
        .init(id: .zoomIn, group: .trailing, width: OverlayControlBarMetrics.iconControlWidth,
              overflowPresentation: .zoomInAction, modes: [.mirror]),
        .init(id: .fitWindowToContent, group: .trailing, width: OverlayControlBarMetrics.iconControlWidth,
              overflowPresentation: .fitWindowToContentAction, modes: [.mirror]),
        .init(id: .followSelectionSize, group: .trailing, width: OverlayControlBarMetrics.iconControlWidth,
              overflowPresentation: .followSelectionSizeAction, modes: [.mirror]),
        .init(id: .docking, group: .trailing, width: OverlayControlBarMetrics.iconControlWidth,
              overflowPresentation: .dockingMenu, modes: [.mirror]),
        .init(id: .opacity, group: .trailing, width: OverlayControlBarMetrics.iconControlWidth,
              overflowPresentation: .opacityPopover),
        .init(id: .debug, group: .trailing, width: OverlayControlBarMetrics.iconControlWidth,
              overflowPresentation: .debugAction, requiresDebugFeatures: true)
    ]

    static func availableItems(
        displayMode: TranslationDisplayMode = .overlay,
        debugFeaturesEnabled: Bool
    ) -> [OverlayControlBarItemDefinition] {
        items.filter {
            $0.modes.contains(displayMode)
                && (debugFeaturesEnabled || !$0.requiresDebugFeatures)
        }
    }
}

enum OverlayControlBarTuning {
    // Change only this line to compare the grouped controls with the previous layout.
    static let itemGrouping: OverlayControlBarItemGrouping = .grouped
    static let commandHoldHintDelay: TimeInterval = 1.0
    static let hoverToolTipDelay: TimeInterval = 0.4
    static let height: CGFloat = 40
    static let gradientAlpha: CGFloat = 0.20
    static let emphasizedGradientAlpha: CGFloat = 0.40
}

enum OverlayControlBarItemGrouping: Equatable {
    case grouped
    case legacy
}

enum OverlayControlBarShortcutSource: Equatable, Sendable {
    case toolbar(ToolbarShortcutAction)
    case immediateTranslation
}

func overlayControlBarShortcutSource(
    for id: OverlayControlBarItemID
) -> OverlayControlBarShortcutSource? {
    switch id {
    case .application: .toolbar(.applicationCapture)
    case .displayMode: .toolbar(.displayMode)
    case .translationDirection: .toolbar(.translationDirection)
    case .protectNonSourceText: .toolbar(.protectNonSourceText)
    case .refreshMode: .toolbar(.refreshMode)
    case .mouseEvents: .toolbar(.modeSpecificDisplayControl)
    case .pause: .toolbar(.sessionControlSingleKey)
    case .translate: .immediateTranslation
    case .copyAll: .toolbar(.copyAll)
    case .copyImage: .toolbar(.copyImage)
    case .saveImage: .toolbar(.saveImage)
    case .search: .toolbar(.search)
    case .selection: .toolbar(.selectionMode)
    case .zoomOut: .toolbar(.zoomOut)
    case .zoomActual: .toolbar(.zoomActual)
    case .zoomIn: .toolbar(.zoomIn)
    case .fitWindowToContent: .toolbar(.fitWindowToContent)
    case .followSelectionSize: .toolbar(.followSelectionSize)
    case .debug: .toolbar(.debugOverlay)
    case .docking, .opacity: nil
    }
}

enum OverlayControlBarMetrics {
    static let height = OverlayControlBarTuning.height
    static let controlHeight: CGFloat = 26
    static let iconControlWidth: CGFloat = 26
    static let applicationWidth: CGFloat = 128
    static let displayModeWidth: CGFloat = 78
    static let refreshModeWidth: CGFloat = 62
    static let dragHandleWidth: CGFloat = 26
    static let overflowWidth: CGFloat = 26
    static let closeWidth: CGFloat = 26
    static let itemSpacing: CGFloat = 5
    static let mirrorDragSpacerWidth: CGFloat = 48
    static let horizontalInset: CGFloat = 7
    static let verticalInset: CGFloat = 5
    static let minimumWidth: CGFloat = 260
    static let dockingGap: CGFloat = 0
    static let borderOutset: CGFloat = 2
}

enum OverlayControlBarDocking: Equatable {
    case aboveSelection, belowSelection
}

@MainActor
private final class OverlayControlBarGradientView: NSView {
    private let gradientLayer = CAGradientLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(gradientLayer)
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradientLayer.frame = bounds
        CATransaction.commit()
    }

    func update(color: NSColor, alpha: CGFloat, docking: OverlayControlBarDocking) {
        let clear = color.withAlphaComponent(0).cgColor
        let tint = color.withAlphaComponent(alpha).cgColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        switch docking {
        case .aboveSelection:
            gradientLayer.startPoint = CGPoint(x: 0.5, y: 0)
            gradientLayer.endPoint = CGPoint(x: 0.5, y: 1)
            gradientLayer.colors = [tint, clear]
        case .belowSelection:
            gradientLayer.startPoint = CGPoint(x: 0.5, y: 0)
            gradientLayer.endPoint = CGPoint(x: 0.5, y: 1)
            gradientLayer.colors = [clear, tint]
        }
        gradientLayer.locations = [0, 0.72]
        gradientLayer.isHidden = alpha == 0
        CATransaction.commit()
    }
}

struct OverlayControlBarResponsiveLayout: Equatable, Sendable {
    let visibleItemIDs: [OverlayControlBarItemID]
    let overflowItemIDs: [OverlayControlBarItemID]

    var showsOverflow: Bool { !overflowItemIDs.isEmpty }
}

func overlayControlBarHoverAlpha(
    isEnabled: Bool, pointerInside: Bool, mouseDown: Bool
) -> CGFloat? {
    guard isEnabled && (pointerInside || mouseDown) else { return nil }
    return mouseDown ? 0.24 : 0.16
}

private enum OverlayControlBarHoverBackground {
    static let cornerRadius: CGFloat = 6

    static func draw(in bounds: CGRect, alpha: CGFloat?) {
        guard let alpha else { return }
        NSColor.labelColor.withAlphaComponent(alpha).setFill()
        NSBezierPath(
            roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius
        ).fill()
    }
}

@MainActor
private final class OverlayControlBarControlHost: NSView {
    private var pointerInside = false
    private var mouseDownActive = false
    private var controlEnabled = true

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { nil }

    func updateInteraction(pointerInside: Bool, mouseDown: Bool, isEnabled: Bool) {
        guard self.pointerInside != pointerInside
            || mouseDownActive != mouseDown
            || controlEnabled != isEnabled else { return }
        self.pointerInside = pointerInside
        mouseDownActive = mouseDown
        controlEnabled = isEnabled
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        OverlayControlBarHoverBackground.draw(in: bounds, alpha: overlayControlBarHoverAlpha(
            isEnabled: controlEnabled, pointerInside: pointerInside, mouseDown: mouseDownActive
        ))
    }
}

@MainActor
private final class OverlayControlBarVisualGroup: NSView {
    let stack = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let drawingAppearance = window?.effectiveAppearance ?? effectiveAppearance
        drawingAppearance.performAsCurrentDrawingAppearance {
            drawGroupDecoration()
        }
    }

    private func drawGroupDecoration() {
        let outline = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5.5, yRadius: 5.5
        )
        NSColor.controlBackgroundColor.withAlphaComponent(0.06).setFill()
        outline.fill()
        NSColor.separatorColor.withAlphaComponent(0.18).setStroke()
        outline.lineWidth = 1
        outline.stroke()

        let visibleViews = stack.arrangedSubviews.filter { !$0.isHidden }
        guard visibleViews.count > 1 else { return }
        NSColor.separatorColor.withAlphaComponent(0.14).setStroke()
        for view in visibleViews.dropLast() {
            let x = view.frame.maxX + stack.spacing / 2
            let path = NSBezierPath()
            path.lineWidth = 1
            path.move(to: CGPoint(x: x, y: 4))
            path.line(to: CGPoint(x: x, y: bounds.maxY - 4))
            path.stroke()
        }
    }
}

func overlayControlBarIsEmphasized(pointerInside: Bool, dragging: Bool) -> Bool {
    pointerInside || dragging
}

func overlayControlBarResponsiveLayout(
    width: CGFloat, items: [OverlayControlBarItemDefinition], includesChrome: Bool = true,
    minimumSpacerWidth: CGFloat = 0
) -> OverlayControlBarResponsiveLayout {
    func requiredWidth(visibleCount: Int, includesOverflow: Bool) -> CGFloat {
        let chromeCount = includesChrome ? 2 : 0
        let arrangedViewCount = chromeCount + visibleCount + (includesOverflow ? 1 : 0)
        return OverlayControlBarMetrics.horizontalInset * 2
            + max(0, minimumSpacerWidth)
            + (includesChrome ? OverlayControlBarMetrics.dragHandleWidth : 0)
            + (includesChrome ? OverlayControlBarMetrics.closeWidth : 0)
            + (includesOverflow ? OverlayControlBarMetrics.overflowWidth : 0)
            + items.prefix(visibleCount).reduce(0) { $0 + $1.width }
            + CGFloat(max(0, arrangedViewCount - 1)) * OverlayControlBarMetrics.itemSpacing
    }

    if requiredWidth(visibleCount: items.count, includesOverflow: false) <= width {
        return OverlayControlBarResponsiveLayout(
            visibleItemIDs: items.map(\.id), overflowItemIDs: []
        )
    }
    guard !items.isEmpty else {
        return OverlayControlBarResponsiveLayout(
            visibleItemIDs: [], overflowItemIDs: []
        )
    }

    var visibleCount = 0
    for count in 1 ... items.count {
        guard requiredWidth(visibleCount: count, includesOverflow: true) <= width else {
            break
        }
        visibleCount = count
    }
    return OverlayControlBarResponsiveLayout(
        visibleItemIDs: Array(items.prefix(visibleCount).map(\.id)),
        overflowItemIDs: Array(items.dropFirst(visibleCount).map(\.id))
    )
}

@MainActor
private final class OverlayControlBarInteractionTracker: NSObject {
    var onPointerActivity: (() -> Void)?
    var onHoverChange: ((Bool) -> Void)?
    var onStateChange: ((Bool, Bool, Bool) -> Void)?
    var onInteractionBegin: (() -> Void)?
    private var pointerInside = false
    private var mouseDownActive = false
    private var controlEnabled = true

    func setEnabled(_ enabled: Bool) {
        controlEnabled = enabled
        notifyState()
    }

    func beginInteraction() {
        onInteractionBegin?()
        mouseDownActive = true
        notifyState()
    }

    func endInteraction(in view: NSView) {
        mouseDownActive = false
        if let window = view.window {
            let point = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            pointerInside = !view.isHidden && view.bounds.contains(point)
        } else {
            pointerInside = false
        }
        notifyState()
    }

    func mouseEntered() {
        pointerInside = true
        notifyState()
        onPointerActivity?()
        onHoverChange?(true)
    }

    func mouseExited() {
        pointerInside = false
        notifyState()
        onPointerActivity?()
        onHoverChange?(false)
    }

    private func notifyState() {
        onStateChange?(pointerInside, mouseDownActive, controlEnabled)
    }
}

@MainActor
private final class OverlayControlBarButton: NSButton {
    let interactionTracker = OverlayControlBarInteractionTracker()
    private var trackingAreaReference: NSTrackingArea?

    override var isEnabled: Bool {
        didSet { interactionTracker.setEnabled(isEnabled) }
    }

    override func updateTrackingAreas() {
        if let trackingAreaReference { removeTrackingArea(trackingAreaReference) }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(trackingArea)
        trackingAreaReference = trackingArea
        super.updateTrackingAreas()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseEntered(with event: NSEvent) {
        interactionTracker.mouseEntered()
    }

    override func mouseExited(with event: NSEvent) {
        interactionTracker.mouseExited()
    }

    override func mouseDown(with event: NSEvent) {
        interactionTracker.beginInteraction()
        defer { interactionTracker.endInteraction(in: self) }
        super.mouseDown(with: event)
    }
}

@MainActor
private final class OverlayControlBarPopupButton: NSPopUpButton {
    let interactionTracker = OverlayControlBarInteractionTracker()
    private var trackingAreaReference: NSTrackingArea?

    override var isEnabled: Bool {
        didSet { interactionTracker.setEnabled(isEnabled) }
    }

    override func updateTrackingAreas() {
        if let trackingAreaReference { removeTrackingArea(trackingAreaReference) }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(trackingArea)
        trackingAreaReference = trackingArea
        super.updateTrackingAreas()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseEntered(with event: NSEvent) {
        interactionTracker.mouseEntered()
    }

    override func mouseExited(with event: NSEvent) {
        interactionTracker.mouseExited()
    }

    override func mouseDown(with event: NSEvent) {
        interactionTracker.beginInteraction()
        defer { interactionTracker.endInteraction(in: self) }
        super.mouseDown(with: event)
    }
}

@MainActor
private final class OverlayControlBarHintPanel: NSPanel {
    init(text: String, alignment: NSTextAlignment = .center) {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        label.textColor = .labelColor
        label.alignment = alignment
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.preferredMaxLayoutWidth = 360
        label.translatesAutoresizingMaskIntoConstraints = false

        let background = NSVisualEffectView()
        background.material = .toolTip
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 5
        background.layer?.cornerCurve = .continuous
        background.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(label)

        super.init(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        animationBehavior = .none
        ignoresMouseEvents = true
        hidesOnDeactivate = true
        collectionBehavior = [.fullScreenAuxiliary, .stationary]
        contentView = background
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -5),
            label.topAnchor.constraint(equalTo: background.topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -3),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 360)
        ])
        background.layoutSubtreeIfNeeded()
        setContentSize(background.fittingSize)
    }

    required init?(coder: NSCoder) { nil }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class OverlayControlBarWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class OverlayControlBarController: NSObject, NSMenuDelegate {
    enum Hosting {
        case overlayPanel
        case mirrorToolbar
    }

    private let hosting: Hosting
    private let panel: OverlayControlBarWindow?
    private var screenFrame: CGRect
    private var visibleFrame: CGRect
    private var selectionFrame: CGRect
    private var pointerInsideControlBar = false
    private var appIsActive = true
    private var dragging = false
    private var dragStartSelection: CGRect?
    private var dragStartPoint: CGPoint?
    private var backgroundOpacity: CGFloat
    private var activeBackgroundOpacity: CGFloat
    private var overlayOpacity: CGFloat
    private var activeOverlayOpacity: CGFloat
    private var translationBackgroundOpacity: CGFloat
    private var regionBorderOpacity: CGFloat
    private var displayMode: TranslationDisplayMode
    private var translationDirection = TranslationDirection.load()
    private var protectsNonSourceText = TranslationTextProtection.load()
    private var refreshMode: RefreshMode = .automatic
    private var paused = false
    private var docking: OverlayControlBarDocking = .aboveSelection
    private var selectionModeEnabled = false
    private var ignoresSelectionMouseEvents: Bool
    private var copyAllEnabled = false
    private var debugFeaturesEnabled = DebugFeatures.load()
    private var ocrDebugOverlayEnabled = false
    private var applications: [CaptureApplication] = []
    private var selectedApplication: CaptureApplication?
    private var alwaysOnTop = MirrorAlwaysOnTop.load()
    private var followsSelectionSize = MirrorFollowsSelectionSize.load()
    private var mirrorDocking = MirrorDockingState.load()
    private var embeddedInMirrorToolbar = false
    private var commandHoldMonitor: Any?
    private var commandHoldWorkItem: DispatchWorkItem?
    private var shortcutHintPanels: [OverlayControlBarHintPanel] = []
    private var hoverToolTipWorkItem: DispatchWorkItem?
    private weak var pendingHoverToolTipView: NSView?
    private weak var visibleHoverToolTipView: NSView?
    private var hoverToolTipPanel: OverlayControlBarHintPanel?
    private var tooltipTextByView: [ObjectIdentifier: String] = [:]

    private let container = OverlayControlBarContainerView()
    private let backgroundView = NSVisualEffectView()
    private let gradientView = OverlayControlBarGradientView()
    private let expandedStack = NSStackView()
    private let leadingControlsStack = NSStackView()
    private let trailingControlsStack = NSStackView()
    private let executionControlsGroup = OverlayControlBarVisualGroup()
    private let resultControlsGroup = OverlayControlBarVisualGroup()
    private let sizeControlsGroup = OverlayControlBarVisualGroup()
    private let flexibleSpacer = NSView()
    private var flexibleSpacerMinimumWidthConstraint: NSLayoutConstraint?
    private let applicationPopup = OverlayControlBarPopupButton(
        frame: .zero, pullsDown: false
    )
    private let displayModeButton = OverlayControlBarButton()
    private let translationDirectionButton = OverlayControlBarButton()
    private let protectNonSourceTextButton = OverlayControlBarButton()
    private let refreshModeButton = OverlayControlBarButton()
    private let pauseButton = OverlayControlBarButton()
    private let translateButton = OverlayControlBarButton()
    private let copyButton = OverlayControlBarButton()
    private let copyImageButton = OverlayControlBarButton()
    private let saveImageButton = OverlayControlBarButton()
    private let searchButton = OverlayControlBarButton()
    private let selectionButton = OverlayControlBarButton()
    private let mouseEventsButton = OverlayControlBarButton()
    private let zoomOutButton = OverlayControlBarButton()
    private let zoomActualButton = OverlayControlBarButton()
    private let zoomInButton = OverlayControlBarButton()
    private let fitWindowToContentButton = OverlayControlBarButton()
    private let followSelectionSizeButton = OverlayControlBarButton()
    private let dockingButton = OverlayControlBarButton()
    private let opacityButton = OverlayControlBarButton()
    private let debugButton = OverlayControlBarButton()
    private let overflowButton = OverlayControlBarButton()
    private let overflowControlHost = OverlayControlBarControlHost()
    private let closeButton = OverlayControlBarButton()
    private let closeControlHost = OverlayControlBarControlHost()
    private let leadingDragView = OverlayControlBarDragView()
    private var controlHosts: [OverlayControlBarItemID: OverlayControlBarControlHost] = [:]
    private var responsiveLayout = OverlayControlBarResponsiveLayout(
        visibleItemIDs: [], overflowItemIDs: []
    )
    private var opacityPopover: NSPopover?
    private weak var overflowApplicationMenu: NSMenu?
    private weak var overlayOpacitySlider: NSSlider?
    private weak var translationBackgroundOpacitySlider: NSSlider?
    private weak var controlBarOpacitySlider: NSSlider?
    private weak var activeOverlayOpacitySlider: NSSlider?
    private weak var activeControlBarOpacitySlider: NSSlider?
    private weak var regionBorderOpacitySlider: NSSlider?
    private weak var overlayOpacityLabel: NSTextField?
    private weak var translationBackgroundOpacityLabel: NSTextField?
    private weak var controlBarOpacityLabel: NSTextField?
    private weak var activeOverlayOpacityLabel: NSTextField?
    private weak var activeControlBarOpacityLabel: NSTextField?
    private weak var regionBorderOpacityLabel: NSTextField?

    var onSelectionDrag: ((CGRect, NSScreen, CGPoint, Bool) -> Void)?
    var onGeometryChange: ((CGRect, OverlayControlBarDocking) -> Void)? {
        didSet { onGeometryChange?(frame, docking) }
    }
    var frame: CGRect { panel?.frame ?? .zero }
    var currentDocking: OverlayControlBarDocking { docking }
    var onDisplayModeChange: ((TranslationDisplayMode) -> Void)?
    var onTranslationDirectionChange: ((TranslationDirection) -> Void)?
    var onNonSourceTextProtectionToggle: (() -> Void)?
    var onApplicationCaptureChange: ((CaptureApplication?) -> Void)?
    var onApplicationListRequest: (() -> Void)?
    var onRefreshModeChange: ((RefreshMode) -> Void)?
    var onPauseChange: ((Bool) -> Void)?
    var onImmediateTranslation: (() -> Void)?
    var onCopyAll: (() -> Void)?
    var onCopyImage: (() -> Void)?
    var onSaveImage: (() -> Void)?
    var onSearch: (() -> Void)?
    var onSelectionModeToggle: (() -> Void)?
    var onMouseEventIgnoringToggle: (() -> Void)?
    var onAlwaysOnTopToggle: (() -> Void)?
    var onZoomOut: (() -> Void)?
    var onZoomActual: (() -> Void)?
    var onZoomIn: (() -> Void)?
    var onFitWindowToContent: (() -> Void)?
    var onFollowSelectionSizeToggle: (() -> Void)?
    var onDockingChange: ((MirrorDockingState) -> Void)?
    var onOverlayOpacityChange: ((CGFloat) -> Void)?
    var onTranslationBackgroundOpacityChange: ((CGFloat) -> Void)?
    var onControlBarOpacityChange: ((CGFloat) -> Void)?
    var onActiveOverlayOpacityChange: ((CGFloat) -> Void)?
    var onActiveControlBarOpacityChange: ((CGFloat) -> Void)?
    var onRegionBorderOpacityChange: ((CGFloat) -> Void)?
    var onOCRDebugOverlayToggle: (() -> Void)?
    var onClose: (() -> Void)?

    init(
        selection: CGRect, screen: NSScreen, displayMode: TranslationDisplayMode,
        overlayOpacity: CGFloat, translationBackgroundOpacity: CGFloat,
        controlBarOpacity: CGFloat, activeOverlayOpacity: CGFloat,
        activeControlBarOpacity: CGFloat, regionBorderOpacity: CGFloat,
        ignoresMouseEvents: Bool, hosting: Hosting = .overlayPanel
    ) {
        self.hosting = hosting
        panel = hosting == .overlayPanel
            ? OverlayControlBarWindow(
                contentRect: .zero, styleMask: [.borderless],
                backing: .buffered, defer: false
            )
            : nil
        screenFrame = screen.frame
        visibleFrame = screen.visibleFrame
        selectionFrame = selection
        self.displayMode = displayMode
        self.overlayOpacity = OverlayOpacity.clamp(overlayOpacity)
        self.activeOverlayOpacity = OverlayActiveOpacity.clamp(activeOverlayOpacity)
        self.translationBackgroundOpacity = MirrorBackgroundOpacity.clamp(
            translationBackgroundOpacity
        )
        backgroundOpacity = OverlayControlBarOpacity.clamp(controlBarOpacity)
        activeBackgroundOpacity = OverlayControlBarActiveOpacity.clamp(
            activeControlBarOpacity
        )
        self.regionBorderOpacity = RegionBorderOpacity.clamp(regionBorderOpacity)
        ignoresSelectionMouseEvents = ignoresMouseEvents
        super.init()
        if let panel {
            panel.level = RegionWindowLevel.controlBar
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.hidesOnDeactivate = false
            panel.becomesKeyOnlyIfNeeded = true
            panel.isMovableByWindowBackground = false
            panel.acceptsMouseMovedEvents = true
            panel.collectionBehavior = [.fullScreenAuxiliary, .stationary]
        }

        configureViewHierarchy()
        configureControls()
        configureCallbacks()
        configureAppActiveObservers()
        configureCommandHoldHints()
        updateAllPresentation()
        updateFrame(display: false)
    }

    func close() {
        cancelCommandHoldHints()
        if let commandHoldMonitor {
            NSEvent.removeMonitor(commandHoldMonitor)
            self.commandHoldMonitor = nil
        }
        panel?.close()
    }

    func ownsTranslationSessionWindow(_ window: NSWindow?) -> Bool {
        window === panel || opacityPopover?.contentViewController?.view.window === window
    }

    private func configureViewHierarchy() {
        container.wantsLayer = true
        backgroundView.material = .hudWindow
        backgroundView.blendingMode = .withinWindow
        backgroundView.wantsLayer = true
        backgroundView.translatesAutoresizingMaskIntoConstraints = false
        gradientView.translatesAutoresizingMaskIntoConstraints = false
        expandedStack.orientation = .horizontal
        expandedStack.alignment = .centerY
        // The two control groups manage their own item spacing. Keeping the
        // outer stack gap-free makes the center view a true flexible spacer.
        expandedStack.spacing = 0
        expandedStack.edgeInsets = NSEdgeInsets(
            top: OverlayControlBarMetrics.verticalInset,
            left: OverlayControlBarMetrics.horizontalInset,
            bottom: OverlayControlBarMetrics.verticalInset,
            right: OverlayControlBarMetrics.horizontalInset
        )
        expandedStack.translatesAutoresizingMaskIntoConstraints = false
        [leadingControlsStack, trailingControlsStack].forEach { stack in
            stack.orientation = .horizontal
            stack.alignment = .centerY
            stack.spacing = OverlayControlBarMetrics.itemSpacing
        }
        container.windowDragRegion = flexibleSpacer
        flexibleSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        flexibleSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        flexibleSpacerMinimumWidthConstraint = flexibleSpacer.widthAnchor.constraint(
            greaterThanOrEqualToConstant: OverlayControlBarMetrics.itemSpacing
        )
        flexibleSpacerMinimumWidthConstraint?.isActive = true
        container.addSubview(backgroundView)
        container.addSubview(gradientView)
        container.addSubview(expandedStack)
        panel?.contentView = container
        NSLayoutConstraint.activate([
            backgroundView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            backgroundView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            backgroundView.topAnchor.constraint(equalTo: container.topAnchor),
            backgroundView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            gradientView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            gradientView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            gradientView.topAnchor.constraint(equalTo: container.topAnchor),
            gradientView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            expandedStack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            expandedStack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            expandedStack.topAnchor.constraint(equalTo: container.topAnchor),
            expandedStack.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
    }

    private func configureControls() {
        leadingDragView.translatesAutoresizingMaskIntoConstraints = false
        setTooltip(L10n.text("번역 영역 이동"), for: leadingDragView)
        leadingDragView.setAccessibilityLabel(L10n.text("번역 영역 이동"))
        leadingDragView.widthAnchor.constraint(
            equalToConstant: OverlayControlBarMetrics.dragHandleWidth
        ).isActive = true

        configureNativeControlAppearance(applicationPopup)
        applicationPopup.focusRingType = .default
        applicationPopup.target = self
        applicationPopup.action = #selector(applicationCaptureChanged(_:))
        setTooltip(toolbarShortcutToolTip(
            L10n.text("캡처할 앱 선택"), action: .applicationCapture
        ), for: applicationPopup)
        applicationPopup.menu?.delegate = self

        configureButton(
            displayModeButton, symbol: "macwindow", toolTip: L10n.text("미러 모드로 전환"),
            action: #selector(toggleDisplayMode)
        )
        displayModeButton.imagePosition = .imageLeading
        displayModeButton.imageHugsTitle = true
        displayModeButton.alignment = .center
        configureButton(
            translationDirectionButton, symbol: "arrow.left.arrow.right", toolTip: L10n.text("번역 방향 전환"),
            action: #selector(toggleTranslationDirection)
        )
        translationDirectionButton.imagePosition = .imageLeading
        translationDirectionButton.imageHugsTitle = true
        translationDirectionButton.alignment = .center
        configureButton(
            protectNonSourceTextButton, symbol: "shield.lefthalf.filled",
            toolTip: L10n.text("원문 외 텍스트 보호 전환"),
            action: #selector(toggleNonSourceTextProtection)
        )
        configureButton(
            refreshModeButton, symbol: "arrow.clockwise", toolTip: L10n.text("갱신 모드 전환"),
            action: #selector(toggleRefreshMode)
        )
        refreshModeButton.imagePosition = .imageLeading
        refreshModeButton.imageHugsTitle = true
        refreshModeButton.alignment = .center
        configureButton(
            pauseButton, symbol: "pause.fill", toolTip: L10n.text("자동 갱신 일시정지"),
            action: #selector(togglePause)
        )
        configureButton(
            translateButton, symbol: "bolt.fill", toolTip: immediateTranslationHotKeyToolTip(
                L10n.text("현재 영역 즉시 번역")
            ),
            action: #selector(translateImmediately)
        )
        configureButton(
            copyButton, symbol: "doc.on.doc", toolTip: toolbarShortcutToolTip(
                L10n.text("텍스트 전체 복사"), action: .copyAll
            ),
            action: #selector(copyAll)
        )
        configureButton(
            copyImageButton, symbol: "photo.on.rectangle", toolTip: toolbarShortcutToolTip(
                L10n.text("번역 영역 이미지 복사"), action: .copyImage
            ),
            action: #selector(copyImage)
        )
        configureButton(
            saveImageButton, symbol: "photo.badge.arrow.down", toolTip: toolbarShortcutToolTip(
                L10n.text("번역 영역 이미지 저장"), action: .saveImage
            ),
            action: #selector(saveImage)
        )
        copyImageButton.isEnabled = false
        configureButton(
            searchButton, symbol: "text.magnifyingglass", toolTip: toolbarShortcutToolTip(
                L10n.text("텍스트 검색"), action: .search
            ), action: #selector(showSearch)
        )
        configureButton(
            selectionButton, symbol: "text.viewfinder", toolTip: toolbarShortcutToolTip(
                L10n.text("텍스트 선택 모드"), action: .selectionMode
            ),
            action: #selector(toggleSelectionMode)
        )
        configureButton(
        mouseEventsButton, symbol: "cursorarrow.rays", toolTip: toolbarShortcutToolTip(
                L10n.text("선택 영역 마우스 무시 안 하기"), action: .modeSpecificDisplayControl
            ),
            action: #selector(toggleMouseEventIgnoring)
        )
        configureButton(
            zoomOutButton, symbol: "minus.magnifyingglass",
            toolTip: toolbarShortcutToolTip(L10n.text("미러 축소"), action: .zoomOut),
            action: #selector(zoomOut)
        )
        configureButton(
            zoomActualButton, symbol: "1.magnifyingglass",
            toolTip: toolbarShortcutToolTip(
                L10n.text("미러를 원본 크기 100%로 복원"), action: .zoomActual
            ), action: #selector(zoomActual)
        )
        configureButton(
            zoomInButton, symbol: "plus.magnifyingglass",
            toolTip: toolbarShortcutToolTip(L10n.text("미러 확대"), action: .zoomIn),
            action: #selector(zoomIn)
        )
        configureButton(
            fitWindowToContentButton,
            symbol: "arrow.down.right.and.arrow.up.left.rectangle",
            toolTip: toolbarShortcutToolTip(L10n.text("여백 제거"), action: .fitWindowToContent),
            action: #selector(fitWindowToContent)
        )
        configureButton(
            followSelectionSizeButton, symbol: "link",
            toolTip: toolbarShortcutToolTip(
                L10n.text("선택 영역 크기 연동"), action: .followSelectionSize
            ), action: #selector(toggleFollowSelectionSize)
        )
        configureButton(
            dockingButton, symbol: mirrorDocking.symbolName,
            toolTip: L10n.text("미러 도킹"), action: #selector(showDockingMenu(_:))
        )
        configureButton(
            opacityButton, symbol: opacityControlSymbolName, toolTip: L10n.text("불투명도 조절"),
            action: #selector(showOpacityControlsFromButton(_:))
        )
        configureButton(
            debugButton, symbol: "ladybug.fill", toolTip: toolbarShortcutToolTip(
                L10n.text("OCR 디버그 오버레이"), action: .debugOverlay
            ),
            action: #selector(toggleOCRDebugOverlay)
        )
        configureButton(
            overflowButton, symbol: "ellipsis.circle", toolTip: L10n.text("모든 컨트롤"),
            action: #selector(showOverflowMenu(_:))
        )
        configureButton(
            closeButton, symbol: "xmark", toolTip: toolbarShortcutToolTip(
                L10n.text("번역 종료"), action: .stopTranslation
            ),
            action: #selector(closeTranslation)
        )

        leadingControlsStack.addArrangedSubview(leadingDragView)
        for definition in OverlayControlBarCatalog.items {
            let host = OverlayControlBarControlHost()
            configureControlHost(
                host, control: control(for: definition.id), width: definition.width
            )
            controlHosts[definition.id] = host
        }
        configureItemGrouping()
        configureControlHost(
            overflowControlHost, control: overflowButton,
            width: OverlayControlBarMetrics.overflowWidth
        )
        configureControlHost(
            closeControlHost, control: closeButton,
            width: OverlayControlBarMetrics.closeWidth
        )
        trailingControlsStack.addArrangedSubview(overflowControlHost)
        trailingControlsStack.addArrangedSubview(closeControlHost)
        [leadingControlsStack, flexibleSpacer, trailingControlsStack]
            .forEach(expandedStack.addArrangedSubview)
        rebuildApplicationPopup()
    }

    private func configureItemGrouping() {
        switch OverlayControlBarTuning.itemGrouping {
        case .legacy:
            for definition in OverlayControlBarCatalog.items {
                guard let host = controlHosts[definition.id] else { continue }
                switch definition.group {
                case .leading: leadingControlsStack.addArrangedSubview(host)
                case .trailing: trailingControlsStack.addArrangedSubview(host)
                }
            }
        case .grouped:
            let executionIDs: Set<OverlayControlBarItemID> = [.pause, .translate]
            let resultIDs: Set<OverlayControlBarItemID> = [
                .copyAll, .copyImage, .saveImage, .search, .selection
            ]
            let sizeIDs: Set<OverlayControlBarItemID> = [
                .zoomOut, .zoomActual, .zoomIn, .fitWindowToContent,
                .followSelectionSize, .docking
            ]
            for definition in OverlayControlBarCatalog.items {
                guard let host = controlHosts[definition.id] else { continue }
                if definition.group == .leading {
                    leadingControlsStack.addArrangedSubview(host)
                } else if executionIDs.contains(definition.id) {
                    executionControlsGroup.stack.addArrangedSubview(host)
                } else if resultIDs.contains(definition.id) {
                    resultControlsGroup.stack.addArrangedSubview(host)
                } else if sizeIDs.contains(definition.id) {
                    sizeControlsGroup.stack.addArrangedSubview(host)
                } else {
                    trailingControlsStack.addArrangedSubview(host)
                }
            }
            trailingControlsStack.insertArrangedSubview(executionControlsGroup, at: 0)
            trailingControlsStack.insertArrangedSubview(resultControlsGroup, at: 1)
            trailingControlsStack.insertArrangedSubview(sizeControlsGroup, at: 2)
        }
    }

    private func configureButton(
        _ button: OverlayControlBarButton, symbol symbolName: String, toolTip: String,
        action: Selector
    ) {
        button.image = symbol(symbolName, description: toolTip)
        button.imagePosition = .imageOnly
        configureNativeControlAppearance(button)
        button.target = self
        button.action = action
        setTooltip(toolTip, for: button)
        button.setAccessibilityLabel(toolTip)
    }

    private func setTooltip(_ text: String, for view: NSView) {
        if visibleHoverToolTipView === view {
            dismissHoverToolTip()
        }
        tooltipTextByView[ObjectIdentifier(view)] = text
        view.toolTip = nil
    }

    private func tooltipText(for view: NSView) -> String? {
        tooltipTextByView[ObjectIdentifier(view)]
    }

    private func configureControlHost(
        _ host: OverlayControlBarControlHost, control: NSView, width: CGFloat
    ) {
        host.translatesAutoresizingMaskIntoConstraints = false
        host.widthAnchor.constraint(equalToConstant: width).isActive = true
        host.heightAnchor.constraint(
            equalToConstant: OverlayControlBarMetrics.controlHeight
        ).isActive = true
        control.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(control)
        NSLayoutConstraint.activate([
            control.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            control.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            control.topAnchor.constraint(equalTo: host.topAnchor),
            control.bottomAnchor.constraint(equalTo: host.bottomAnchor)
        ])
    }

    private func configureNativeControlAppearance(_ button: NSButton) {
        button.controlSize = .small
        button.isBordered = false
        button.contentTintColor = .labelColor
    }

    private func control(for id: OverlayControlBarItemID) -> NSButton {
        switch id {
        case .application: applicationPopup
        case .displayMode: displayModeButton
        case .translationDirection: translationDirectionButton
        case .protectNonSourceText: protectNonSourceTextButton
        case .refreshMode: refreshModeButton
        case .pause: pauseButton
        case .translate: translateButton
        case .copyAll: copyButton
        case .copyImage: copyImageButton
        case .saveImage: saveImageButton
        case .search: searchButton
        case .selection: selectionButton
        case .mouseEvents: mouseEventsButton
        case .zoomOut: zoomOutButton
        case .zoomActual: zoomActualButton
        case .zoomIn: zoomInButton
        case .fitWindowToContent: fitWindowToContentButton
        case .followSelectionSize: followSelectionSizeButton
        case .docking: dockingButton
        case .opacity: opacityButton
        case .debug: debugButton
        }
    }

    private func interactionTracker(
        for id: OverlayControlBarItemID
    ) -> OverlayControlBarInteractionTracker {
        if id == .application { return applicationPopup.interactionTracker }
        return (control(for: id) as! OverlayControlBarButton).interactionTracker
    }

    private func configureCallbacks() {
        container.onPointerActivity = { [weak self] in
            self?.refreshControlBarPointerState()
        }
        for definition in OverlayControlBarCatalog.items {
            guard let host = controlHosts[definition.id] else { continue }
            let control = control(for: definition.id)
            let tracker = interactionTracker(for: definition.id)
            tracker.onPointerActivity = { [weak self] in
                self?.refreshControlBarPointerState()
            }
            tracker.onHoverChange = { [weak self, weak control] inside in
                self?.handleHoverChange(inside, for: control)
            }
            tracker.onStateChange = { [weak host] pointerInside, mouseDown, isEnabled in
                host?.updateInteraction(
                    pointerInside: pointerInside, mouseDown: mouseDown, isEnabled: isEnabled
                )
            }
            tracker.onInteractionBegin = { [weak self] in
                self?.dismissHoverToolTip()
                self?.activateForInteraction()
            }
            tracker.setEnabled(control.isEnabled)
        }
        [overflowButton, closeButton].forEach { button in
            let host = button === overflowButton ? overflowControlHost : closeControlHost
            button.interactionTracker.onPointerActivity = { [weak self] in
                self?.refreshControlBarPointerState()
            }
            button.interactionTracker.onHoverChange = { [weak self, weak button] inside in
                self?.handleHoverChange(inside, for: button)
            }
            button.interactionTracker.onStateChange = {
                [weak host] pointerInside, mouseDown, isEnabled in
                host?.updateInteraction(
                    pointerInside: pointerInside, mouseDown: mouseDown, isEnabled: isEnabled
                )
            }
            button.interactionTracker.onInteractionBegin = {
                [weak self] in
                self?.dismissHoverToolTip()
                self?.activateForInteraction()
            }
            button.interactionTracker.setEnabled(button.isEnabled)
        }
        leadingDragView.onDrag = { [weak self] phase, point in
            self?.handleDrag(phase: phase, point: point)
        }
        leadingDragView.onHoverChange = { [weak self, weak leadingDragView] inside in
            self?.handleHoverChange(inside, for: leadingDragView)
        }
        container.onDrag = { [weak self] phase, point in
            self?.handleDrag(phase: phase, point: point)
        }
    }

    private func configureAppActiveObservers() {
        appIsActive = NSApp.isActive
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppDidResignActive),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
    }

    private func configureCommandHoldHints() {
        commandHoldMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.flagsChanged, .keyDown]
        ) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                self.cancelCommandHoldHints()
                return event
            }
            let relevant = event.modifierFlags.intersection([
                .command, .option, .control, .shift
            ])
            if relevant == [.command], NSApp.isActive {
                self.scheduleCommandHoldHints()
            } else {
                self.cancelCommandHoldHints()
            }
            return event
        }
    }

    private func scheduleCommandHoldHints() {
        guard commandHoldWorkItem == nil, shortcutHintPanels.isEmpty else { return }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.commandHoldWorkItem = nil
            let relevant = NSEvent.modifierFlags.intersection([
                .command, .option, .control, .shift
            ])
            guard relevant == [.command], NSApp.isActive,
                  self.container.window?.isVisible == true else { return }
            self.showShortcutHints()
        }
        commandHoldWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + OverlayControlBarTuning.commandHoldHintDelay,
            execute: workItem
        )
    }

    private func cancelCommandHoldHints() {
        commandHoldWorkItem?.cancel()
        commandHoldWorkItem = nil
        closeShortcutHints()
        dismissHoverToolTip()
    }

    private func handleHoverChange(_ inside: Bool, for view: NSView?) {
        guard let view else { return }
        if inside {
            scheduleHoverToolTip(for: view)
        } else if pendingHoverToolTipView === view || visibleHoverToolTipView === view {
            dismissHoverToolTip()
        }
    }

    private func scheduleHoverToolTip(for view: NSView) {
        dismissHoverToolTip()
        guard let text = tooltipText(for: view), !text.isEmpty else { return }
        guard NSApp.isActive, view.window?.isVisible == true else { return }

        pendingHoverToolTipView = view
        let workItem = DispatchWorkItem { [weak self, weak view] in
            self?.hoverToolTipWorkItem = nil
            guard let self, let view,
                  self.pendingHoverToolTipView === view,
                  NSApp.isActive,
                  view.window?.isVisible == true,
                  let text = self.tooltipText(for: view), !text.isEmpty else { return }
            let panel = OverlayControlBarHintPanel(text: text, alignment: .left)
            panel.level = self.panel?.level ?? RegionWindowLevel.controlBar
            self.hoverToolTipPanel = panel
            self.visibleHoverToolTipView = view
            self.positionShortcutHint(panel, relativeTo: view)
            panel.orderFrontRegardless()
        }
        hoverToolTipWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + OverlayControlBarTuning.hoverToolTipDelay,
            execute: workItem
        )
    }

    private func dismissHoverToolTip() {
        hoverToolTipWorkItem?.cancel()
        hoverToolTipWorkItem = nil
        pendingHoverToolTipView = nil
        visibleHoverToolTipView = nil
        hoverToolTipPanel?.close()
        hoverToolTipPanel = nil
    }

    private func shortcutTitle(for source: OverlayControlBarShortcutSource) -> String? {
        switch source {
        case .toolbar(let action):
            let hotKey = ToolbarHotKey.load(action: action)
            guard hotKey.isEnabled else { return nil }
            if action == .sessionControlSingleKey, refreshMode != .automatic {
                // The single-key session control pauses only in automatic mode,
                // so its hint is not shown on the disabled pause button in manual mode.
                return nil
            }
            return hotKey.title
        case .immediateTranslation:
            // In manual mode the single-key action performs immediate translation.
            let singleKey = ToolbarHotKey.load(action: .sessionControlSingleKey)
            if refreshMode == .manual, singleKey.isEnabled {
                return singleKey.title
            }
            let hotKey = ImmediateTranslationHotKey.load()
            return hotKey.isEnabled ? hotKey.title : nil
        }
    }

    private func showShortcutHints() {
        closeShortcutHints()
        container.layoutSubtreeIfNeeded()
        let visibleIDs = Set(responsiveLayout.visibleItemIDs)
        for definition in OverlayControlBarCatalog.items
            where visibleIDs.contains(definition.id) {
            guard let source = overlayControlBarShortcutSource(for: definition.id),
                  let title = shortcutTitle(for: source),
                  let host = controlHosts[definition.id], !host.isHidden else { continue }
            let hint = OverlayControlBarHintPanel(text: title)
            hint.level = panel?.level ?? RegionWindowLevel.controlBar
            shortcutHintPanels.append(hint)
            positionShortcutHint(hint, relativeTo: host)
            hint.orderFrontRegardless()
        }
        if !closeControlHost.isHidden,
           let title = shortcutTitle(for: .toolbar(.stopTranslation)) {
            let hint = OverlayControlBarHintPanel(text: title)
            shortcutHintPanels.append(hint)
            hint.level = panel?.level ?? RegionWindowLevel.controlBar
            positionShortcutHint(hint, relativeTo: closeControlHost)
            hint.orderFrontRegardless()
        }
    }

    private func positionShortcutHint(
        _ hint: OverlayControlBarHintPanel, relativeTo host: NSView
    ) {
        guard let hostWindow = container.window else { return }
        let hostInWindow = host.convert(host.bounds, to: nil)
        let hostOnScreen = hostWindow.convertToScreen(hostInWindow)
        let gap: CGFloat = 4
        let y: CGFloat
        if embeddedInMirrorToolbar {
            y = hostOnScreen.minY - hint.frame.height - gap
        } else {
            y = docking == .aboveSelection
                ? frame.maxY + gap
                : frame.minY - hint.frame.height - gap
        }
        hint.setFrameOrigin(CGPoint(
            x: hostOnScreen.midX - hint.frame.width / 2, y: y
        ))
    }

    private func closeShortcutHints() {
        shortcutHintPanels.forEach { $0.close() }
        shortcutHintPanels.removeAll()
    }

    @objc private func handleAppDidBecomeActive() {
        appIsActive = true
        updateBackgroundPresentation()
    }

    @objc private func handleAppDidResignActive() {
        appIsActive = false
        cancelCommandHoldHints()
        refreshControlBarPointerState()
    }

    private func symbol(_ name: String, description: String) -> NSImage {
        let configuration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: description)
            ?? NSImage(systemSymbolName: "ellipsis", accessibilityDescription: description)
            ?? NSImage()
        return image.withSymbolConfiguration(configuration) ?? image
    }

    func show() {
        guard let panel else { return }
        updateFrame(display: false)
        panel.orderFrontRegardless()
        panel.makeFirstResponder(nil)
    }

    func hide() {
        cancelCommandHoldHints()
        opacityPopover?.close()
        opacityPopover = nil
        panel?.orderOut(nil)
    }

    func takeContentViewForMirrorToolbar(width: CGFloat) -> NSView {
        precondition(hosting == .mirrorToolbar)
        embeddedInMirrorToolbar = true
        updateFlexibleSpacerMinimumWidth()
        container.translatesAutoresizingMaskIntoConstraints = false
        opacityPopover?.close()
        opacityPopover = nil
        leadingDragView.isHidden = true
        closeControlHost.isHidden = true
        container.usesStandardWindowDrag = true
        backgroundView.isHidden = true
        gradientView.isHidden = true
        backgroundView.layer?.maskedCorners = [
            .layerMinXMinYCorner, .layerMaxXMinYCorner,
            .layerMinXMaxYCorner, .layerMaxXMaxYCorner
        ]
        container.frame = CGRect(
            x: 0, y: 0, width: max(1, width), height: OverlayControlBarMetrics.height
        )
        updateResponsivePresentation(for: container.frame.width)
        updateBackgroundPresentation()
        return container
    }

    func releaseContentViewFromMirrorToolbar() {
        precondition(hosting == .mirrorToolbar)
        embeddedInMirrorToolbar = false
        updateFlexibleSpacerMinimumWidth()
        container.removeFromSuperview()
    }

    func updateMirrorToolbarWidth(_ width: CGFloat) {
        guard embeddedInMirrorToolbar else { return }
        dismissHoverToolTip()
        container.setFrameSize(CGSize(
            width: max(1, width), height: OverlayControlBarMetrics.height
        ))
        updateResponsivePresentation(for: container.frame.width)
    }

    func closeForSessionStop() {
        cancelCommandHoldHints()
        opacityPopover?.close()
        opacityPopover = nil
        close()
    }

    func setSelectionFrame(_ rect: CGRect) {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) {
            screenFrame = screen.frame
            visibleFrame = screen.visibleFrame
        }
        selectionFrame = rect
        if !embeddedInMirrorToolbar {
            updateFrame(display: true)
        }
    }

    func setApplicationCapture(
        applications: [CaptureApplication], selected: CaptureApplication?
    ) {
        self.applications = applications
        selectedApplication = selected
        rebuildApplicationPopup()
        if let overflowApplicationMenu {
            rebuildOverflowApplicationMenu(overflowApplicationMenu)
        }
    }

    func showApplicationCapturePopup() {
        if !embeddedInMirrorToolbar {
            panel?.makeKeyAndOrderFront(nil)
            panel?.makeFirstResponder(applicationPopup)
        }
        applicationPopup.performClick(nil)
    }

    func setDisplayMode(_ mode: TranslationDisplayMode) {
        displayMode = mode
        updateAllPresentation()
    }

    func setTranslationDirection(_ direction: TranslationDirection) {
        translationDirection = direction
        translationDirectionButton.title = direction.title
        setTooltip(toolbarShortcutToolTip(
            L10n.format("번역 방향: %@ (클릭하여 전환)", direction.title),
            action: .translationDirection
        ), for: translationDirectionButton)
        translationDirectionButton.setAccessibilityLabel(translationDirectionButton.toolTip ?? direction.title)
    }

    func setProtectsNonSourceText(_ enabled: Bool) {
        protectsNonSourceText = enabled
        let label = enabled
            ? L10n.text("원문 외 텍스트 보호 끄기")
            : L10n.text("원문 외 텍스트 보호 켜기")
        protectNonSourceTextButton.image = symbol(
            "shield.lefthalf.filled", description: label
        )
        protectNonSourceTextButton.contentTintColor = enabled
            ? .controlAccentColor : .labelColor
        setTooltip(toolbarShortcutToolTip(
            label, action: .protectNonSourceText
        ), for: protectNonSourceTextButton)
        protectNonSourceTextButton.setAccessibilityLabel(label)
    }

    func setRefreshMode(_ mode: RefreshMode) {
        refreshMode = mode
        updateRefreshPresentation()
    }

    func setPaused(_ value: Bool) {
        paused = value
        updateRefreshPresentation()
        updatePausePresentation()
    }

    func setCopyAllEnabled(_ enabled: Bool) {
        copyAllEnabled = enabled
        copyButton.isEnabled = enabled
    }

    func setCopyImageEnabled(_ enabled: Bool) {
        copyImageButton.isEnabled = enabled
        saveImageButton.isEnabled = enabled
    }

    func setSelectionMode(_ enabled: Bool) {
        selectionModeEnabled = enabled
        updateSelectionPresentation()
    }

    func setIgnoresSelectionMouseEvents(_ enabled: Bool) {
        ignoresSelectionMouseEvents = enabled
        updateMouseEventIgnoringPresentation()
    }

    func setAlwaysOnTop(_ enabled: Bool) {
        alwaysOnTop = enabled
        updateMouseEventIgnoringPresentation()
    }

    func setFollowSelectionSize(_ enabled: Bool) {
        followsSelectionSize = enabled
        let label = enabled
            ? L10n.text("선택 영역 크기 연동 끄기")
            : L10n.text("선택 영역 크기 연동 켜기")
        followSelectionSizeButton.image = symbol(
            "link",
            description: label
        )
        followSelectionSizeButton.contentTintColor = enabled
            ? .controlAccentColor : .labelColor
        setTooltip(toolbarShortcutToolTip(
            label, action: .followSelectionSize
        ), for: followSelectionSizeButton)
        followSelectionSizeButton.setAccessibilityLabel(label)
    }

    func setMirrorDocking(_ state: MirrorDockingState) {
        mirrorDocking = state
        let label = state == .undocked
            ? L10n.text("미러 도킹") : L10n.format("미러 도킹: %@", state.title)
        dockingButton.image = symbol(state.symbolName, description: label)
        setTooltip(dockingToolTip(label), for: dockingButton)
        dockingButton.setAccessibilityLabel(label)
        dockingButton.contentTintColor = .labelColor
    }

    private func dockingToolTip(_ label: String) -> String {
        let shortcuts = [MirrorDockingState.top, .bottom, .left, .right].compactMap {
            state -> String? in
            guard let action = state.shortcutAction else { return nil }
            let hotKey = ToolbarHotKey.load(action: action)
            return hotKey.isEnabled ? "\(state.title)  \(hotKey.title)" : nil
        }
        return ([label] + shortcuts).joined(separator: "\n")
    }

    func setDebugFeaturesEnabled(_ enabled: Bool) {
        debugFeaturesEnabled = enabled
        if !enabled { setOCRDebugOverlay(false) }
        updateResponsivePresentation(
            for: embeddedInMirrorToolbar ? container.frame.width : desiredFrame().frame.width
        )
    }

    func setOCRDebugOverlay(_ enabled: Bool) {
        ocrDebugOverlayEnabled = enabled
        debugButton.contentTintColor = enabled ? .controlAccentColor : .labelColor
    }

    func setOverlayOpacity(_ opacity: CGFloat) {
        overlayOpacity = OverlayOpacity.clamp(opacity)
        overlayOpacitySlider?.doubleValue = Double(overlayOpacity)
        overlayOpacityLabel?.stringValue = percent(overlayOpacity)
    }

    func setActiveOverlayOpacity(_ opacity: CGFloat) {
        activeOverlayOpacity = OverlayActiveOpacity.clamp(opacity)
        activeOverlayOpacitySlider?.doubleValue = Double(activeOverlayOpacity)
        activeOverlayOpacityLabel?.stringValue = percent(activeOverlayOpacity)
    }

    func setTranslationBackgroundOpacity(_ opacity: CGFloat) {
        translationBackgroundOpacity = MirrorBackgroundOpacity.clamp(opacity)
        translationBackgroundOpacitySlider?.doubleValue = Double(translationBackgroundOpacity)
        translationBackgroundOpacityLabel?.stringValue = percent(translationBackgroundOpacity)
    }

    func setControlBarOpacity(_ opacity: CGFloat) {
        backgroundOpacity = OverlayControlBarOpacity.clamp(opacity)
        controlBarOpacitySlider?.doubleValue = Double(backgroundOpacity)
        controlBarOpacityLabel?.stringValue = percent(backgroundOpacity)
        updateBackgroundPresentation()
    }

    func setActiveControlBarOpacity(_ opacity: CGFloat) {
        activeBackgroundOpacity = OverlayControlBarActiveOpacity.clamp(opacity)
        activeControlBarOpacitySlider?.doubleValue = Double(activeBackgroundOpacity)
        activeControlBarOpacityLabel?.stringValue = percent(activeBackgroundOpacity)
        updateBackgroundPresentation()
    }

    func setRegionBorderOpacity(_ opacity: CGFloat) {
        regionBorderOpacity = RegionBorderOpacity.clamp(opacity)
        regionBorderOpacitySlider?.doubleValue = Double(regionBorderOpacity)
        regionBorderOpacityLabel?.stringValue = percent(regionBorderOpacity)
    }

    private func updateAllPresentation() {
        backgroundView.layer?.cornerRadius = 10
        updateDockedAppearance()
        updateBackgroundPresentation()
        updateResponsivePresentation(
            for: embeddedInMirrorToolbar ? container.frame.width : desiredFrame().frame.width
        )
        updateDisplayModePresentation()
        setTranslationDirection(translationDirection)
        setProtectsNonSourceText(protectsNonSourceText)
        updateRefreshPresentation()
        updatePausePresentation()
        updateSelectionPresentation()
        updateMouseEventIgnoringPresentation()
        setFollowSelectionSize(followsSelectionSize)
        setMirrorDocking(mirrorDocking)
        copyButton.isEnabled = copyAllEnabled
    }

    private func updateBackgroundPresentation() {
        if embeddedInMirrorToolbar {
            expandedStack.alphaValue = 1
            return
        }
        let emphasized = overlayControlBarIsEmphasized(
            pointerInside: pointerInsideControlBar, dragging: dragging
        )
        if appIsActive {
            backgroundView.state = .active
            backgroundView.alphaValue = emphasized ? 1.0 : activeBackgroundOpacity
        } else {
            backgroundView.state = .inactive
            backgroundView.alphaValue = emphasized ? activeBackgroundOpacity : backgroundOpacity
        }
        expandedStack.alphaValue = emphasized
            ? 1.0
            : (appIsActive ? activeBackgroundOpacity : backgroundOpacity)
        panel?.hasShadow = appIsActive
        updateGradientPresentation(emphasized: emphasized)
    }

    private func refreshControlBarPointerState() {
        guard let hostWindow = container.window ?? panel else { return }
        let windowPoint = hostWindow.convertPoint(fromScreen: NSEvent.mouseLocation)
        let containerPoint = container.convert(windowPoint, from: nil)
        pointerInsideControlBar = container.bounds.contains(containerPoint)
        updateBackgroundPresentation()
    }

    private func updateDisplayModePresentation() {
        let isOverlay = displayMode == .overlay
        displayModeButton.image = symbol(
            isOverlay ? "macwindow" : "macwindow.on.rectangle",
            description: isOverlay
                ? L10n.text("미러 모드로 전환") : L10n.text("오버레이 모드로 전환")
        )
        displayModeButton.title = isOverlay ? L10n.text("오버레이") : L10n.text("미러")
        setTooltip(toolbarShortcutToolTip(isOverlay
            ? L10n.text("현재 오버레이 모드 · 미러로 전환")
            : L10n.text("현재 미러 모드 · 오버레이로 전환"), action: .displayMode),
            for: displayModeButton)
        displayModeButton.setAccessibilityLabel(
            isOverlay ? L10n.text("오버레이 모드") : L10n.text("미러 모드")
        )
    }

    private func updateRefreshPresentation() {
        let automatic = refreshMode == .automatic
        let presentationState: RegionBorderController.PresentationState = automatic
            ? (paused ? .automaticPaused : .automatic) : .manual
        refreshModeButton.image = symbol(
            automatic ? "arrow.clockwise" : "hand.tap",
            description: automatic ? L10n.text("자동 갱신") : L10n.text("수동 갱신")
        )
        refreshModeButton.title = automatic ? L10n.text("자동") : L10n.text("수동")
        setTooltip(toolbarShortcutToolTip(automatic
            ? L10n.text("자동 갱신 · 클릭하여 수동으로 전환")
            : L10n.text("수동 갱신 · 클릭하여 자동으로 전환"), action: .refreshMode),
            for: refreshModeButton)
        pauseButton.isEnabled = automatic
        refreshModeButton.contentTintColor = regionPresentationColor(for: presentationState)
        translateButton.contentTintColor = automatic
            ? .labelColor : regionPresentationColor(for: .manual)
        updateGradientPresentation()
    }

    private func updatePausePresentation() {
        let label = paused ? L10n.text("자동 갱신 재개") : L10n.text("자동 갱신 일시정지")
        pauseButton.image = symbol(paused ? "play.fill" : "pause.fill", description: label)
        setTooltip(toolbarShortcutToolTip(label, action: .sessionControlSingleKey), for: pauseButton)
        pauseButton.contentTintColor = paused
            ? regionPresentationColor(for: .automaticPaused) : .labelColor
    }

    private func updateSelectionPresentation() {
        selectionButton.contentTintColor = selectionModeEnabled
            ? .controlAccentColor : .labelColor
        setTooltip(toolbarShortcutToolTip(selectionModeEnabled
            ? L10n.text("텍스트 선택 모드 끄기") : L10n.text("텍스트 선택 모드 켜기")
            , action: .selectionMode), for: selectionButton)
    }

    private func updateMouseEventIgnoringPresentation() {
        if displayMode == .mirror {
            let label = alwaysOnTop ? L10n.text("항상 위 켜짐") : L10n.text("항상 위 꺼짐")
            mouseEventsButton.image = symbol(
                alwaysOnTop ? "pin.fill" : "pin.slash", description: label
            )
            mouseEventsButton.contentTintColor = .labelColor
            setTooltip(toolbarShortcutToolTip(
                alwaysOnTop
                    ? L10n.text("미러창을 항상 위에 두지 않기")
                    : L10n.text("미러창을 항상 위에 두기"),
                action: .modeSpecificDisplayControl
            ), for: mouseEventsButton)
            mouseEventsButton.setAccessibilityLabel(label)
            return
        }
        mouseEventsButton.image = symbol(
            "cursorarrow.rays", description: L10n.text("선택 영역 마우스 무시 안 하기")
        )
        let doesNotIgnoreMouseEvents = !ignoresSelectionMouseEvents
        mouseEventsButton.contentTintColor = doesNotIgnoreMouseEvents
            ? .controlAccentColor : .labelColor
        setTooltip(toolbarShortcutToolTip(
            doesNotIgnoreMouseEvents
                ? L10n.text("마우스 무시 안 함 · 클릭하여 무시")
                : L10n.text("마우스 무시 중 · 클릭하여 무시 안 함"),
            action: .modeSpecificDisplayControl
        ), for: mouseEventsButton)
        mouseEventsButton.setAccessibilityLabel(
            doesNotIgnoreMouseEvents
                ? L10n.text("마우스 무시 안 하기 켜짐")
                : L10n.text("마우스 무시 안 하기 꺼짐")
        )
    }

    func refreshShortcutToolTips() {
        updateDisplayModePresentation()
        setTranslationDirection(translationDirection)
        setProtectsNonSourceText(protectsNonSourceText)
        updateRefreshPresentation()
        updatePausePresentation()
        updateSelectionPresentation()
        updateMouseEventIgnoringPresentation()
        setTooltip(toolbarShortcutToolTip(
            L10n.text("캡처할 앱 선택"), action: .applicationCapture
        ), for: applicationPopup)
        setTooltip(immediateTranslationHotKeyToolTip(
            L10n.text("현재 영역 즉시 번역")
        ), for: translateButton)
        setTooltip(toolbarShortcutToolTip(L10n.text("텍스트 전체 복사"), action: .copyAll), for: copyButton)
        setTooltip(toolbarShortcutToolTip(L10n.text("번역 영역 이미지 복사"), action: .copyImage), for: copyImageButton)
        setTooltip(toolbarShortcutToolTip(L10n.text("번역 영역 이미지 저장"), action: .saveImage), for: saveImageButton)
        setTooltip(toolbarShortcutToolTip(L10n.text("텍스트 검색"), action: .search), for: searchButton)
        setTooltip(toolbarShortcutToolTip(L10n.text("미러 축소"), action: .zoomOut), for: zoomOutButton)
        setTooltip(toolbarShortcutToolTip(
            L10n.text("미러를 원본 크기 100%로 복원"), action: .zoomActual
        ), for: zoomActualButton)
        setTooltip(toolbarShortcutToolTip(L10n.text("미러 확대"), action: .zoomIn), for: zoomInButton)
        setTooltip(toolbarShortcutToolTip(
            L10n.text("여백 제거"), action: .fitWindowToContent
        ), for: fitWindowToContentButton)
        setFollowSelectionSize(followsSelectionSize)
        setMirrorDocking(mirrorDocking)
        setTooltip(L10n.text("불투명도 조절"), for: opacityButton)
        setTooltip(toolbarShortcutToolTip(
            L10n.text("OCR 디버그 오버레이"), action: .debugOverlay
        ), for: debugButton)
        setTooltip(toolbarShortcutToolTip(
            L10n.text("번역 종료"), action: .stopTranslation
        ), for: closeButton)
    }

    func refreshLocalization() {
        opacityPopover?.close()
        opacityPopover = nil
        setTooltip(L10n.text("번역 영역 이동"), for: leadingDragView)
        leadingDragView.setAccessibilityLabel(L10n.text("번역 영역 이동"))
        setTooltip(toolbarShortcutToolTip(
            L10n.text("캡처할 앱 선택"), action: .applicationCapture
        ), for: applicationPopup)
        rebuildApplicationPopup()
        updateAllPresentation()
        refreshShortcutToolTips()
    }

    private func updateResponsivePresentation(for width: CGFloat) {
        let availableItems = OverlayControlBarCatalog.availableItems(
            displayMode: displayMode,
            debugFeaturesEnabled: debugFeaturesEnabled
        )
        responsiveLayout = overlayControlBarResponsiveLayout(
            width: width,
            items: availableItems,
            includesChrome: !embeddedInMirrorToolbar,
            minimumSpacerWidth: embeddedInMirrorToolbar
                ? OverlayControlBarMetrics.mirrorDragSpacerWidth : 0
        )
        let visibleIDs = Set(responsiveLayout.visibleItemIDs)
        for definition in OverlayControlBarCatalog.items {
            controlHosts[definition.id]?.isHidden = !visibleIDs.contains(definition.id)
        }
        if OverlayControlBarTuning.itemGrouping == .grouped {
            executionControlsGroup.isHidden = ![.pause, .translate].contains {
                visibleIDs.contains($0)
            }
            resultControlsGroup.isHidden = ![
                .copyAll, .copyImage, .saveImage, .search, .selection
            ].contains {
                visibleIDs.contains($0)
            }
            sizeControlsGroup.isHidden = ![
                .zoomOut, .zoomActual, .zoomIn, .fitWindowToContent,
                .followSelectionSize, .docking
            ].contains {
                visibleIDs.contains($0)
            }
            executionControlsGroup.needsDisplay = true
            resultControlsGroup.needsDisplay = true
            sizeControlsGroup.needsDisplay = true
        }
        overflowControlHost.isHidden = !responsiveLayout.showsOverflow
    }

    private func desiredFrame() -> (frame: CGRect, docking: OverlayControlBarDocking) {
        let height = OverlayControlBarMetrics.height
        let preferredWidth = selectionFrame.width + OverlayControlBarMetrics.borderOutset * 2
        let width = min(max(1, visibleFrame.width), preferredWidth)
        var x = selectionFrame.midX - width / 2
        x = min(max(visibleFrame.minX, x), visibleFrame.maxX - width)

        let aboveY = selectionFrame.maxY + OverlayControlBarMetrics.borderOutset
            + OverlayControlBarMetrics.dockingGap
        let belowY = selectionFrame.minY - OverlayControlBarMetrics.borderOutset
            - OverlayControlBarMetrics.dockingGap - height
        let availableAbove = visibleFrame.maxY - aboveY
        let availableBelow = belowY + height - visibleFrame.minY
        let y: CGFloat
        let docking: OverlayControlBarDocking
        if aboveY + height <= visibleFrame.maxY {
            y = aboveY
            docking = .aboveSelection
        } else if belowY >= visibleFrame.minY || availableBelow >= availableAbove {
            y = belowY
            docking = .belowSelection
        } else {
            y = aboveY
            docking = .aboveSelection
        }
        return (CGRect(x: x, y: y, width: width, height: height), docking)
    }

    private func updateFrame(display: Bool) {
        dismissHoverToolTip()
        let target = desiredFrame()
        docking = target.docking
        updateResponsivePresentation(for: target.frame.width)
        panel?.setFrame(target.frame, display: display)
        updateDockedAppearance()
        onGeometryChange?(frame, docking)
        refreshControlBarPointerState()
    }

    private func updateFlexibleSpacerMinimumWidth() {
        flexibleSpacerMinimumWidthConstraint?.constant = embeddedInMirrorToolbar
            ? OverlayControlBarMetrics.mirrorDragSpacerWidth
            : OverlayControlBarMetrics.itemSpacing
    }

    private func updateDockedAppearance() {
        let allCorners: CACornerMask = [
            .layerMinXMinYCorner, .layerMaxXMinYCorner,
            .layerMinXMaxYCorner, .layerMaxXMaxYCorner
        ]
        switch docking {
        case .aboveSelection:
            backgroundView.layer?.maskedCorners = [
                .layerMinXMaxYCorner, .layerMaxXMaxYCorner
            ]
            panel?.hasShadow = appIsActive
        case .belowSelection:
            backgroundView.layer?.maskedCorners = [
                .layerMinXMinYCorner, .layerMaxXMinYCorner
            ]
            panel?.hasShadow = appIsActive
        }
        gradientView.layer?.cornerRadius = backgroundView.layer?.cornerRadius ?? 0
        gradientView.layer?.maskedCorners = backgroundView.layer?.maskedCorners ?? allCorners
        updateGradientPresentation()
    }

    private func updateGradientPresentation(emphasized: Bool? = nil) {
        let emphasized = emphasized ?? overlayControlBarIsEmphasized(
            pointerInside: pointerInsideControlBar, dragging: dragging
        )
        let state: RegionBorderController.PresentationState
        if refreshMode == .manual {
            state = .manual
        } else {
            state = paused ? .automaticPaused : .automatic
        }
        let alpha: CGFloat
        if appIsActive {
            alpha = emphasized
                ? OverlayControlBarTuning.emphasizedGradientAlpha
                : OverlayControlBarTuning.gradientAlpha
        } else {
            alpha = pointerInsideControlBar
                ? OverlayControlBarTuning.emphasizedGradientAlpha : 0
        }
        gradientView.update(
            color: regionPresentationColor(for: state), alpha: alpha, docking: docking
        )
    }

    private func handleDrag(phase: OverlayControlBarDragView.Phase, point: CGPoint) {
        switch phase {
        case .began:
            dismissHoverToolTip()
            activateForInteraction()
            dragStartSelection = selectionFrame
            dragStartPoint = point
            dragging = true
            updateBackgroundPresentation()
        case .changed, .ended:
            guard let startRect = dragStartSelection, let startPoint = dragStartPoint else {
                return
            }
            let rawDelta = CGPoint(x: point.x - startPoint.x, y: point.y - startPoint.y)
            var rect = startRect.offsetBy(dx: rawDelta.x, dy: rawDelta.y)
            let targetScreen = NSScreen.screens.first(where: { $0.frame.contains(point) })
                ?? NSScreen.screens.first(where: { $0.frame.intersects(rect) })
            if let targetScreen {
                screenFrame = targetScreen.frame
                visibleFrame = targetScreen.visibleFrame
            }
            let maximumX = max(screenFrame.minX, screenFrame.maxX - rect.width)
            let maximumY = max(screenFrame.minY, screenFrame.maxY - rect.height)
            rect.origin.x = min(max(screenFrame.minX, rect.minX), maximumX)
            rect.origin.y = min(max(screenFrame.minY, rect.minY), maximumY)
            let cumulativeDelta = CGPoint(
                x: rect.minX - startRect.minX,
                y: rect.minY - startRect.minY
            )
            selectionFrame = rect
            updateFrame(display: true)
            onSelectionDrag?(rect, targetScreen ?? NSScreen.main ?? NSScreen.screens[0], cumulativeDelta, phase == .ended)
            if phase == .ended {
                dragStartSelection = nil
                dragStartPoint = nil
                dragging = false
                updateBackgroundPresentation()
            }
        }
    }

    private func activateForInteraction() {
        NSApp.activate(ignoringOtherApps: true)
        if embeddedInMirrorToolbar {
            container.window?.makeKeyAndOrderFront(nil)
        } else {
            panel?.makeKeyAndOrderFront(nil)
        }
    }

    private func rebuildApplicationPopup() {
        applicationPopup.removeAllItems()
        applicationPopup.addItem(withTitle: L10n.text("모든 앱"))
        applicationPopup.item(at: 0)?.image = symbol(
            "square.stack.3d.up", description: L10n.text("모든 앱")
        )
        for application in applications {
            applicationPopup.addItem(withTitle: application.name)
            let item = applicationPopup.item(at: applicationPopup.numberOfItems - 1)
            item?.image = applicationIcon(for: application)
            item?.representedObject = String(describing: application.processID)
        }
        if let selectedApplication,
           let index = applications.firstIndex(where: {
               $0.processID == selectedApplication.processID
           }) {
            applicationPopup.selectItem(at: index + 1)
        } else {
            applicationPopup.selectItem(at: 0)
        }
    }

    private func applicationIcon(for application: CaptureApplication) -> NSImage {
        let icon = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: application.bundleIdentifier
        ).map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? symbol("app", description: application.name)
        let result = (icon.copy() as? NSImage) ?? icon
        result.size = CGSize(width: 16, height: 16)
        result.accessibilityDescription = application.name
        return result
    }

    func menuWillOpen(_ menu: NSMenu) {
        if menu === applicationPopup.menu { onApplicationListRequest?() }
    }

    @objc private func applicationCaptureChanged(_ sender: NSPopUpButton) {
        guard let identifier = sender.selectedItem?.representedObject as? String else {
            onApplicationCaptureChange?(nil)
            return
        }
        guard let application = applications.first(where: {
            String(describing: $0.processID) == identifier
        }) else { return }
        onApplicationCaptureChange?(application)
    }

    @objc private func toggleDisplayMode() {
        onDisplayModeChange?(displayMode == .overlay ? .mirror : .overlay)
    }

    @objc private func toggleTranslationDirection() {
        onTranslationDirectionChange?(translationDirection.toggled)
    }

    @objc private func toggleNonSourceTextProtection() {
        onNonSourceTextProtectionToggle?()
    }

    @objc private func toggleRefreshMode() {
        onRefreshModeChange?(refreshMode == .automatic ? .manual : .automatic)
    }

    @objc private func togglePause() { onPauseChange?(!paused) }
    @objc private func translateImmediately() { onImmediateTranslation?() }
    @objc private func copyAll() { onCopyAll?() }
    @objc private func copyImage() { onCopyImage?() }
    @objc private func saveImage() { onSaveImage?() }
    @objc private func showSearch() { onSearch?() }
    @objc private func toggleSelectionMode() { onSelectionModeToggle?() }
    @objc private func toggleMouseEventIgnoring() {
        if displayMode == .mirror { onAlwaysOnTopToggle?() }
        else { onMouseEventIgnoringToggle?() }
    }
    @objc private func zoomOut() { onZoomOut?() }
    @objc private func zoomActual() { onZoomActual?() }
    @objc private func zoomIn() { onZoomIn?() }
    @objc private func fitWindowToContent() { onFitWindowToContent?() }
    @objc private func toggleFollowSelectionSize() { onFollowSelectionSizeToggle?() }
    @objc private func showDockingMenu(_ sender: NSButton) {
        let menu = makeDockingMenu()
        menu.popUp(positioning: nil, at: CGPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
    }

    private func makeDockingMenu() -> NSMenu {
        let menu = NSMenu(title: L10n.text("미러 도킹"))
        for state in MirrorDockingState.allCases {
            let item = actionMenuItem(
                state.title, symbol: state.symbolName,
                action: #selector(selectDockingFromMenu(_:))
            )
            item.representedObject = state.rawValue
            item.state = mirrorDocking == state ? .on : .off
            if let action = state.shortcutAction {
                applyMenuShortcut(ToolbarHotKey.load(action: action), to: item)
            }
            menu.addItem(item)
        }
        return menu
    }

    @objc private func selectDockingFromMenu(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let state = MirrorDockingState(rawValue: rawValue) else { return }
        onDockingChange?(state)
    }
    @objc private func closeTranslation() { onClose?() }

    @objc private func showOverflowMenu(_ sender: NSButton) {
        onApplicationListRequest?()
        let menu = makeOverflowMenu()
        menu.popUp(positioning: nil, at: CGPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
    }

    private func makeOverflowMenu() -> NSMenu {
        let menu = NSMenu(title: L10n.text("번역 세션 제어"))
        for id in responsiveLayout.overflowItemIDs {
            guard let definition = OverlayControlBarCatalog.items.first(where: {
                $0.id == id
            }) else { continue }
            let item = overflowMenuItem(for: definition)
            item.representedObject = id.rawValue
            applyOverflowMenuShortcut(for: id, to: item)
            menu.addItem(item)
        }
        return menu
    }

    private func applyOverflowMenuShortcut(
        for id: OverlayControlBarItemID, to item: NSMenuItem
    ) {
        guard let source = overlayControlBarShortcutSource(for: id) else { return }
        switch source {
        case .toolbar(let action):
            if action == .sessionControlSingleKey, refreshMode != .automatic {
                clearMenuShortcut(item)
            } else {
                applyMenuShortcut(ToolbarHotKey.load(action: action), to: item)
            }
        case .immediateTranslation:
            if refreshMode == .manual {
                applyMenuShortcut(
                    ToolbarHotKey.load(action: .sessionControlSingleKey), to: item
                )
            } else {
                applyMenuShortcut(ImmediateTranslationHotKey.load(), to: item)
            }
        }
    }

    private func overflowMenuItem(
        for definition: OverlayControlBarItemDefinition
    ) -> NSMenuItem {
        switch definition.overflowPresentation {
        case .applicationMenu:
            let applicationItem = menuItem(L10n.text("캡처 앱"), symbol: "app.badge")
            let applicationMenu = NSMenu(title: L10n.text("캡처 앱"))
            rebuildOverflowApplicationMenu(applicationMenu)
            overflowApplicationMenu = applicationMenu
            applicationItem.submenu = applicationMenu
            return applicationItem
        case .displayModeAction:
            return actionMenuItem(
                displayMode == .overlay
                    ? L10n.text("미러 모드로 전환") : L10n.text("오버레이 모드로 전환"),
                symbol: displayMode == .overlay ? "macwindow" : "macwindow.on.rectangle",
                action: #selector(toggleDisplayMode)
            )
        case .translationDirectionAction:
            return actionMenuItem(
                "번역 방향: \(translationDirection.title)", symbol: "arrow.left.arrow.right",
                action: #selector(toggleTranslationDirection)
            )
        case .protectNonSourceTextAction:
            let item = actionMenuItem(
                protectsNonSourceText
                    ? L10n.text("원문 외 텍스트 보호 끄기")
                    : L10n.text("원문 외 텍스트 보호 켜기"),
                symbol: "shield.lefthalf.filled",
                action: #selector(toggleNonSourceTextProtection)
            )
            item.state = protectsNonSourceText ? .on : .off
            return item
        case .refreshModeMenu:
            let refreshItem = menuItem(L10n.text("갱신 모드"), symbol: "arrow.clockwise")
            let refreshMenu = NSMenu(title: L10n.text("갱신 모드"))
            let automaticItem = actionMenuItem(
                L10n.text("자동 갱신"), symbol: "arrow.clockwise",
                action: #selector(selectRefreshModeFromMenu(_:))
            )
            automaticItem.tag = 0
            automaticItem.state = refreshMode == .automatic ? .on : .off
            let manualItem = actionMenuItem(
                L10n.text("수동 갱신"), symbol: "hand.tap",
                action: #selector(selectRefreshModeFromMenu(_:))
            )
            manualItem.tag = 1
            manualItem.state = refreshMode == .manual ? .on : .off
            refreshMenu.items = [automaticItem, manualItem]
            refreshItem.submenu = refreshMenu
            return refreshItem
        case .pauseAction:
            let pauseItem = actionMenuItem(
                paused ? L10n.text("재개") : L10n.text("일시정지"),
                symbol: paused ? "play.fill" : "pause.fill",
                action: #selector(togglePause)
            )
            pauseItem.isEnabled = refreshMode == .automatic
            return pauseItem
        case .translateAction:
            return actionMenuItem(
                L10n.text("즉시 번역"), symbol: "bolt.fill", action: #selector(translateImmediately)
            )
        case .copyAllAction:
            let copyItem = actionMenuItem(
                L10n.text("텍스트 전체 복사"), symbol: "doc.on.doc", action: #selector(copyAll)
            )
            copyItem.isEnabled = copyAllEnabled
            return copyItem
        case .copyImageAction:
            let copyImageItem = actionMenuItem(
                L10n.text("이미지 복사"), symbol: "photo.on.rectangle", action: #selector(copyImage)
            )
            copyImageItem.isEnabled = copyImageButton.isEnabled
            return copyImageItem
        case .saveImageAction:
            let saveImageItem = actionMenuItem(
                L10n.text("이미지 저장"), symbol: "photo.badge.arrow.down", action: #selector(saveImage)
            )
            saveImageItem.isEnabled = saveImageButton.isEnabled
            return saveImageItem
        case .searchAction:
            return actionMenuItem(
                L10n.text("텍스트 검색"), symbol: "text.magnifyingglass", action: #selector(showSearch)
            )
        case .selectionAction:
            let selectionItem = actionMenuItem(
                L10n.text("텍스트 선택 모드"), symbol: "text.viewfinder",
                action: #selector(toggleSelectionMode)
            )
            selectionItem.state = selectionModeEnabled ? .on : .off
            return selectionItem
        case .mouseEventsAction:
            if displayMode == .mirror {
                let item = actionMenuItem(
                    alwaysOnTop ? L10n.text("항상 위 끄기") : L10n.text("항상 위 켜기"),
                    symbol: alwaysOnTop ? "pin.fill" : "pin.slash",
                    action: #selector(toggleMouseEventIgnoring)
                )
                return item
            }
            let mouseEventsItem = actionMenuItem(
                L10n.text("마우스 무시 안 하기"), symbol: "cursorarrow.rays",
                action: #selector(toggleMouseEventIgnoring)
            )
            mouseEventsItem.state = ignoresSelectionMouseEvents ? .off : .on
            return mouseEventsItem
        case .zoomOutAction:
            return actionMenuItem(
                L10n.text("축소"), symbol: "minus.magnifyingglass", action: #selector(zoomOut)
            )
        case .zoomActualAction:
            return actionMenuItem(
                L10n.text("실제 크기"), symbol: "1.magnifyingglass", action: #selector(zoomActual)
            )
        case .zoomInAction:
            return actionMenuItem(
                L10n.text("확대"), symbol: "plus.magnifyingglass", action: #selector(zoomIn)
            )
        case .fitWindowToContentAction:
            return actionMenuItem(
                L10n.text("여백 제거"),
                symbol: "arrow.down.right.and.arrow.up.left.rectangle",
                action: #selector(fitWindowToContent)
            )
        case .followSelectionSizeAction:
            let item = actionMenuItem(
                L10n.text("선택 영역 크기 연동"),
                symbol: "link",
                action: #selector(toggleFollowSelectionSize)
            )
            item.image?.isTemplate = true
            item.state = followsSelectionSize ? .on : .off
            return item
        case .dockingMenu:
            let item = menuItem(L10n.text("미러 도킹"), symbol: mirrorDocking.symbolName)
            item.submenu = makeDockingMenu()
            return item
        case .opacityPopover:
            return actionMenuItem(
                L10n.text("불투명도 조절…"), symbol: opacityControlSymbolName,
                action: #selector(showOpacityControlsFromMenu)
            )
        case .debugAction:
            let debugItem = actionMenuItem(
                L10n.text("OCR 디버그 오버레이"), symbol: "ladybug",
                action: #selector(toggleOCRDebugOverlay)
            )
            debugItem.state = ocrDebugOverlayEnabled ? .on : .off
            return debugItem
        }
    }

    private func rebuildOverflowApplicationMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let allApplicationsItem = actionMenuItem(
            L10n.text("모든 앱"), symbol: "square.stack.3d.up",
            action: #selector(selectApplicationFromMenu(_:))
        )
        allApplicationsItem.state = selectedApplication == nil ? .on : .off
        menu.addItem(allApplicationsItem)
        for application in applications {
            let item = actionMenuItem(
                application.name, symbol: nil,
                action: #selector(selectApplicationFromMenu(_:))
            )
            item.image = applicationIcon(for: application)
            item.representedObject = String(describing: application.processID)
            item.state = application.processID == selectedApplication?.processID ? .on : .off
            menu.addItem(item)
        }
    }

    private func menuItem(_ title: String, symbol symbolName: String?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        if let symbolName { item.image = symbol(symbolName, description: title) }
        return item
    }

    private func actionMenuItem(
        _ title: String, symbol symbolName: String?, action: Selector
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        if let symbolName { item.image = symbol(symbolName, description: title) }
        return item
    }

    @objc private func selectApplicationFromMenu(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? String else {
            onApplicationCaptureChange?(nil)
            return
        }
        guard let application = applications.first(where: {
            String(describing: $0.processID) == identifier
        }) else { return }
        onApplicationCaptureChange?(application)
    }

    @objc private func selectRefreshModeFromMenu(_ sender: NSMenuItem) {
        onRefreshModeChange?(sender.tag == 0 ? .automatic : .manual)
    }

    @objc private func toggleOCRDebugOverlay() { onOCRDebugOverlayToggle?() }

    @objc private func showOpacityControlsFromMenu() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.presentOpacityPopover(relativeTo: self.overflowButton)
        }
    }

    @objc private func showOpacityControlsFromButton(_ sender: NSButton) {
        presentOpacityPopover(relativeTo: sender)
    }

    private func presentOpacityPopover(relativeTo anchor: NSView) {
        opacityPopover?.close()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        let controller = NSViewController()
        let title = NSTextField(labelWithString: L10n.text("불투명도"))
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        var rows: [NSView] = [title]
        if displayMode == .mirror {
            let backgroundRow = makeOpacityRow(
                title: L10n.text("번역 배경"), value: translationBackgroundOpacity,
                minimum: 0, action: #selector(translationBackgroundOpacityChanged(_:))
            )
            translationBackgroundOpacitySlider = backgroundRow.slider
            translationBackgroundOpacityLabel = backgroundRow.valueLabel
            let borderRow = makeOpacityRow(
                title: L10n.text("선택 영역 테두리"), value: regionBorderOpacity,
                minimum: 0, action: #selector(regionBorderOpacityChanged(_:))
            )
            regionBorderOpacitySlider = borderRow.slider
            regionBorderOpacityLabel = borderRow.valueLabel
            rows.append(contentsOf: [backgroundRow.view, borderRow.view])
        } else {
            let overlayRow = makeOpacityRow(
                title: L10n.text("비활성 번역 표시 영역"), value: overlayOpacity,
                minimum: OverlayOpacity.range.lowerBound,
                action: #selector(overlayOpacityChanged(_:))
            )
            overlayOpacitySlider = overlayRow.slider
            overlayOpacityLabel = overlayRow.valueLabel
            let activeOverlayRow = makeOpacityRow(
                title: L10n.text("활성 번역 표시 영역"), value: activeOverlayOpacity,
                minimum: OverlayActiveOpacity.range.lowerBound,
                action: #selector(activeOverlayOpacityChanged(_:))
            )
            activeOverlayOpacitySlider = activeOverlayRow.slider
            activeOverlayOpacityLabel = activeOverlayRow.valueLabel
            let controlBarRow = makeOpacityRow(
                title: L10n.text("비활성 컨트롤 바"), value: backgroundOpacity,
                minimum: OverlayControlBarOpacity.range.lowerBound,
                action: #selector(controlBarOpacityChanged(_:))
            )
            controlBarOpacitySlider = controlBarRow.slider
            controlBarOpacityLabel = controlBarRow.valueLabel
            let activeControlBarRow = makeOpacityRow(
                title: L10n.text("활성 컨트롤 바"), value: activeBackgroundOpacity,
                minimum: OverlayControlBarActiveOpacity.range.lowerBound,
                action: #selector(activeControlBarOpacityChanged(_:))
            )
            activeControlBarOpacitySlider = activeControlBarRow.slider
            activeControlBarOpacityLabel = activeControlBarRow.valueLabel
            let borderRow = makeOpacityRow(
                title: L10n.text("선택 영역 테두리"), value: regionBorderOpacity,
                minimum: 0, action: #selector(regionBorderOpacityChanged(_:))
            )
            regionBorderOpacitySlider = borderRow.slider
            regionBorderOpacityLabel = borderRow.valueLabel
            rows.append(contentsOf: [
                overlayRow.view, activeOverlayRow.view, controlBarRow.view,
                activeControlBarRow.view, borderRow.view
            ])
        }

        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = OpacityPopoverMetrics.verticalSpacing
        let inset = OpacityPopoverMetrics.edgeInset
        stack.edgeInsets = NSEdgeInsets(top: inset, left: inset, bottom: inset, right: inset)
        stack.frame = CGRect(
            x: 0, y: 0, width: OpacityPopoverMetrics.width,
            height: displayMode == .mirror
                ? OpacityPopoverMetrics.doubleRowHeight
                : OpacityPopoverMetrics.fiveRowHeight
        )
        controller.view = stack
        popover.contentViewController = controller
        popover.contentSize = stack.frame.size
        opacityPopover = popover
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
    }

    private func makeOpacityRow(
        title: String, value: CGFloat, minimum: CGFloat, action: Selector
    ) -> (view: NSView, slider: NSSlider, valueLabel: NSTextField) {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 11)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.widthAnchor.constraint(equalToConstant: OpacityPopoverMetrics.titleWidth).isActive = true
        let slider = NSSlider(
            value: Double(value), minValue: Double(minimum), maxValue: 1,
            target: self, action: action
        )
        slider.isContinuous = true
        slider.widthAnchor.constraint(equalToConstant: OpacityPopoverMetrics.sliderWidth).isActive = true
        let valueLabel = NSTextField(labelWithString: percent(value))
        valueLabel.alignment = .right
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        valueLabel.widthAnchor.constraint(equalToConstant: OpacityPopoverMetrics.valueWidth).isActive = true
        let row = NSStackView(views: [titleLabel, slider, valueLabel])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = OpacityPopoverMetrics.rowSpacing
        return (row, slider, valueLabel)
    }

    private func percent(_ value: CGFloat) -> String { "\(Int(value * 100))%" }

    @objc private func overlayOpacityChanged(_ sender: NSSlider) {
        let value = OverlayOpacity.clamp(CGFloat(sender.doubleValue))
        overlayOpacity = value
        overlayOpacityLabel?.stringValue = percent(value)
        onOverlayOpacityChange?(value)
    }

    @objc private func translationBackgroundOpacityChanged(_ sender: NSSlider) {
        let value = MirrorBackgroundOpacity.clamp(CGFloat(sender.doubleValue))
        translationBackgroundOpacity = value
        translationBackgroundOpacityLabel?.stringValue = percent(value)
        onTranslationBackgroundOpacityChange?(value)
    }

    @objc private func activeOverlayOpacityChanged(_ sender: NSSlider) {
        let value = OverlayActiveOpacity.clamp(CGFloat(sender.doubleValue))
        activeOverlayOpacity = value
        activeOverlayOpacityLabel?.stringValue = percent(value)
        onActiveOverlayOpacityChange?(value)
    }

    @objc private func controlBarOpacityChanged(_ sender: NSSlider) {
        let value = OverlayControlBarOpacity.clamp(CGFloat(sender.doubleValue))
        backgroundOpacity = value
        controlBarOpacityLabel?.stringValue = percent(value)
        updateBackgroundPresentation()
        onControlBarOpacityChange?(value)
    }


    @objc private func activeControlBarOpacityChanged(_ sender: NSSlider) {
        let value = OverlayControlBarActiveOpacity.clamp(CGFloat(sender.doubleValue))
        activeBackgroundOpacity = value
        activeControlBarOpacityLabel?.stringValue = percent(value)
        updateBackgroundPresentation()
        onActiveControlBarOpacityChange?(value)
    }

    @objc private func regionBorderOpacityChanged(_ sender: NSSlider) {
        let value = RegionBorderOpacity.clamp(CGFloat(sender.doubleValue))
        regionBorderOpacity = value
        regionBorderOpacityLabel?.stringValue = percent(value)
        onRegionBorderOpacityChange?(value)
    }

    func layoutContractViolationsForSelfTest() -> [String] {
        var violations: [String] = []
        let overlayDebugIDs = OverlayControlBarCatalog.availableItems(
            displayMode: .overlay, debugFeaturesEnabled: true
        ).map(\.id)
        let overlayReleaseIDs = OverlayControlBarCatalog.availableItems(
            displayMode: .overlay, debugFeaturesEnabled: false
        ).map(\.id)

        func record(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() { violations.append(message) }
        }

        func itemIDs(in stack: NSStackView) -> [OverlayControlBarItemID] {
            stack.arrangedSubviews.flatMap { view -> [OverlayControlBarItemID] in
                if let id = controlHosts.first(where: { $0.value === view })?.key {
                    return [id]
                }
                if let group = view as? OverlayControlBarVisualGroup {
                    return itemIDs(in: group.stack)
                }
                return []
            }
        }

        let leadingIDs = OverlayControlBarCatalog.items.compactMap {
            $0.group == .leading ? $0.id : nil
        }
        let trailingIDs = OverlayControlBarCatalog.items.compactMap {
            $0.group == .trailing ? $0.id : nil
        }
        record(
            leadingControlsStack.arrangedSubviews.first === leadingDragView,
            "overlay control bar: drag handle is not the first leading view"
        )
        record(
            itemIDs(in: leadingControlsStack) == leadingIDs,
            "overlay control bar: leading item order differs from the catalog"
        )
        record(
            itemIDs(in: trailingControlsStack) == trailingIDs,
            "overlay control bar: trailing item order differs from the catalog"
        )
        record(
            trailingControlsStack.arrangedSubviews.suffix(2).elementsEqual(
                [overflowControlHost, closeControlHost], by: { $0 === $1 }
            ),
            "overlay control bar: overflow and close controls are not fixed at the trailing edge"
        )
        record(applicationPopup.focusRingType == .default,
               "overlay control bar: application focus ring policy changed")
        record(panel?.canBecomeKey == true, "overlay control bar: panel must be able to become key")
        record(panel?.canBecomeMain == false, "overlay control bar: panel must not become main")
        record(
            OverlayControlBarTuning.hoverToolTipDelay.isFinite
                && OverlayControlBarTuning.hoverToolTipDelay >= 0,
            "overlay control bar: hover tooltip delay must be finite and non-negative"
        )
        for definition in OverlayControlBarCatalog.items {
            let control = control(for: definition.id)
            record(
                control.toolTip == nil,
                "overlay control bar: native tooltip remains enabled for \(definition.id.rawValue)"
            )
            record(
                tooltipText(for: control)?.isEmpty == false,
                "overlay control bar: custom tooltip text is missing for \(definition.id.rawValue)"
            )
        }
        for (control, id) in [
            (overflowButton as NSView, "overflow"), (closeButton as NSView, "close"),
            (leadingDragView as NSView, "drag")
        ] {
            record(
                control.toolTip == nil,
                "overlay control bar: native tooltip remains enabled for \(id)"
            )
            record(
                tooltipText(for: control)?.isEmpty == false,
                "overlay control bar: custom tooltip text is missing for \(id)"
            )
        }
        let expectedTranslationDirectionTooltip = toolbarShortcutToolTip(
            L10n.format("번역 방향: %@ (클릭하여 전환)", translationDirection.title),
            action: .translationDirection
        )
        record(
            tooltipText(for: translationDirectionButton) == expectedTranslationDirectionTooltip,
            "overlay control bar: translation direction tooltip does not include its shortcut"
        )
        let hintPanel = OverlayControlBarHintPanel(text: "test")
        defer { hintPanel.close() }
        record(
            hintPanel.ignoresMouseEvents,
            "overlay control bar: tooltip panel must ignore mouse events"
        )
        record(
            !hintPanel.canBecomeKey && !hintPanel.canBecomeMain,
            "overlay control bar: tooltip panel must not become key or main"
        )
        record(
            hintPanel.animationBehavior == .none,
            "overlay control bar: tooltip panel must not animate when ordered"
        )

        let wideWidth: CGFloat = 800
        setDebugFeaturesEnabled(true)
        panel?.setFrame(
            CGRect(x: 0, y: 0, width: wideWidth, height: OverlayControlBarMetrics.height),
            display: false
        )
        updateResponsivePresentation(for: wideWidth)
        container.layoutSubtreeIfNeeded()
        record(
            responsiveLayout.visibleItemIDs == overlayDebugIDs,
            "overlay control bar: wide layout does not expose every item"
        )
        record(!responsiveLayout.showsOverflow,
               "overlay control bar: wide layout unexpectedly shows overflow")
        record(overflowControlHost.isHidden,
               "overlay control bar: overflow host is visible in the wide layout")
        record(!closeControlHost.isHidden,
               "overlay control bar: close host must always remain visible")
        record(
            abs(leadingControlsStack.frame.minX - OverlayControlBarMetrics.horizontalInset) < 0.5,
            "overlay control bar: leading group is not aligned to the leading inset"
        )
        record(
            abs(
                trailingControlsStack.frame.maxX
                    - (expandedStack.bounds.maxX - OverlayControlBarMetrics.horizontalInset)
            ) < 0.5,
            "overlay control bar: trailing group is not aligned to the trailing inset"
        )
        record(
            flexibleSpacer.frame.width >= OverlayControlBarMetrics.itemSpacing - 0.5,
            "overlay control bar: flexible center spacer is too narrow"
        )
        if OverlayControlBarTuning.itemGrouping == .grouped {
            let sizeIDs: [OverlayControlBarItemID] = [
                .zoomOut, .zoomActual, .zoomIn, .fitWindowToContent,
                .followSelectionSize, .docking
            ]
            record(
                itemIDs(in: sizeControlsGroup.stack) == sizeIDs,
                "overlay control bar: size controls are not grouped in catalog order"
            )
            record(
                !executionControlsGroup.dataWithPDF(
                    inside: executionControlsGroup.bounds
                ).isEmpty,
                "overlay control bar: grouped controls cannot be rendered"
            )
        }

        for definition in OverlayControlBarCatalog.items {
            guard let host = controlHosts[definition.id] else {
                violations.append("overlay control bar: missing host for \(definition.id.rawValue)")
                continue
            }
            record(
                abs(host.frame.width - definition.width) < 0.5,
                "overlay control bar: \(definition.id.rawValue) host width differs from catalog"
            )
            record(
                abs(host.frame.height - OverlayControlBarMetrics.controlHeight) < 0.5,
                "overlay control bar: \(definition.id.rawValue) host height is not 26pt"
            )
            record(
                control(for: definition.id).superview === host,
                "overlay control bar: \(definition.id.rawValue) control is outside its host"
            )
        }

        let overflowWidth: CGFloat = 570
        panel?.setFrame(
            CGRect(x: 0, y: 0, width: overflowWidth, height: OverlayControlBarMetrics.height),
            display: false
        )
        updateResponsivePresentation(for: overflowWidth)
        container.layoutSubtreeIfNeeded()
        let menuItemIDs = makeOverflowMenu().items.compactMap { item in
            (item.representedObject as? String).flatMap(OverlayControlBarItemID.init(rawValue:))
        }
        record(
            menuItemIDs == responsiveLayout.overflowItemIDs,
            "overlay control bar: overflow menu does not match hidden item IDs"
        )
        record(!overflowControlHost.isHidden,
               "overlay control bar: overflow host is hidden when items overflow")
        record(!closeControlHost.isHidden,
               "overlay control bar: close host was hidden by responsive layout")

        updateResponsivePresentation(for: 1)
        let allOverflowMenuItemIDs = makeOverflowMenu().items.compactMap { item in
            (item.representedObject as? String).flatMap(OverlayControlBarItemID.init(rawValue:))
        }
        record(
            allOverflowMenuItemIDs == overlayDebugIDs,
            "overlay control bar: one or more catalog items lack overflow menu representation"
        )

        setDebugFeaturesEnabled(false)
        updateResponsivePresentation(for: 800)
        record(
            responsiveLayout.visibleItemIDs == overlayReleaseIDs,
            "overlay control bar: release layout item set differs from the catalog"
        )
        record(
            controlHosts[.debug]?.isHidden == true,
            "overlay control bar: debug host remains visible when debug features are disabled"
        )
        return violations
    }

    func mirrorEmbeddingContractViolationsForSelfTest() -> [String] {
        var violations: [String] = []
        setDisplayMode(.mirror)
        _ = takeContentViewForMirrorToolbar(width: 1200)
        container.layoutSubtreeIfNeeded()
        let mirrorIDs = OverlayControlBarCatalog.availableItems(
            displayMode: .mirror, debugFeaturesEnabled: debugFeaturesEnabled
        ).map(\.id)
        if !leadingDragView.isHidden {
            violations.append("mirror control bar must hide the overlay drag handle")
        }
        if !closeControlHost.isHidden {
            violations.append("mirror control bar must hide the duplicate close button")
        }
        if !container.usesStandardWindowDrag {
            violations.append("mirror control bar must use AppKit standard window dragging")
        }
        if !backgroundView.isHidden || !gradientView.isHidden {
            violations.append("mirror control bar must expose the native titlebar background")
        }
        if expandedStack.alphaValue != 1 {
            violations.append("mirror control bar controls must remain fully opaque")
        }
        if flexibleSpacer.frame.width
            < OverlayControlBarMetrics.mirrorDragSpacerWidth - 0.5 {
            violations.append("mirror control bar spacer is too narrow for window dragging")
        }
        let spacerPoint = flexibleSpacer.convert(
            CGPoint(x: flexibleSpacer.bounds.midX, y: flexibleSpacer.bounds.midY),
            to: container
        )
        if container.hitTest(spacerPoint) !== container {
            violations.append("mirror control bar spacer does not route to window dragging")
        }
        if panel != nil {
            violations.append("mirror control bar must not create an overlay panel")
        }
        updateResponsivePresentation(for: 1)
        let expectedNarrowLayout = overlayControlBarResponsiveLayout(
            width: 1,
            items: OverlayControlBarCatalog.availableItems(
                displayMode: .mirror, debugFeaturesEnabled: debugFeaturesEnabled
            ),
            includesChrome: false,
            minimumSpacerWidth: OverlayControlBarMetrics.mirrorDragSpacerWidth
        )
        if responsiveLayout != expectedNarrowLayout
            || responsiveLayout.visibleItemIDs + responsiveLayout.overflowItemIDs != mirrorIDs {
            violations.append("mirror control bar overflow differs from its mode catalog")
        }
        return violations
    }

    var isEmbeddedInMirrorToolbarForSelfTest: Bool { embeddedInMirrorToolbar }
    var ownsPanelContentForSelfTest: Bool { panel?.contentView === container }
    var hasOverlayPanelForSelfTest: Bool { panel != nil }
}

@MainActor
func overlayControlBarContractViolationsForSelfTest() -> [String] {
    guard let screen = NSScreen.main ?? NSScreen.screens.first else {
        return ["overlay control bar: no screen is available for layout verification"]
    }
    let panel = OverlayControlBarController(
        selection: CGRect(x: 100, y: 100, width: 800, height: 400),
        screen: screen,
        displayMode: .overlay,
        overlayOpacity: 1,
        translationBackgroundOpacity: 1,
        controlBarOpacity: 0.8,
        activeOverlayOpacity: 1,
        activeControlBarOpacity: 1,
        regionBorderOpacity: 1,
        ignoresMouseEvents: true
    )
    defer { panel.close() }
    return panel.layoutContractViolationsForSelfTest()
}

@MainActor
func mirrorControlBarContractViolationsForSelfTest() -> [String] {
    guard let screen = NSScreen.main ?? NSScreen.screens.first else {
        return ["mirror control bar: no screen is available for layout verification"]
    }
    let panel = OverlayControlBarController(
        selection: CGRect(x: 100, y: 100, width: 800, height: 400),
        screen: screen,
        displayMode: .mirror,
        overlayOpacity: 1,
        translationBackgroundOpacity: 1,
        controlBarOpacity: 0.2,
        activeOverlayOpacity: 1,
        activeControlBarOpacity: 0.4,
        regionBorderOpacity: 1,
        ignoresMouseEvents: true,
        hosting: .mirrorToolbar
    )
    defer { panel.close() }
    return panel.mirrorEmbeddingContractViolationsForSelfTest()
}
