import AppKit

enum RegionWindowLevel {
    /// Visual-only border ring; no mouse events.
    static let visual = NSWindow.Level(
        rawValue: NSWindow.Level.floating.rawValue + 1
    )
    /// Resize edge panels. These stay above the control bar so the shared
    /// visual edge remains draggable from the first mouse-down, and above the
    /// move handle so the border attached to it stays resizable.
    static let interaction = NSWindow.Level(
        rawValue: NSWindow.Level.floating.rawValue + 3
    )
    /// Overlay control bar, above the visual border but below interaction handles.
    static let controlBar = NSWindow.Level(
        rawValue: NSWindow.Level.floating.rawValue + 2
    )
    /// Move handle. Deliberately one level BELOW the interaction panels: the
    /// edge panels must always win wherever they overlap the handle, and a
    /// level gap makes that structural instead of relying on re-ordering
    /// after every path that can bring the handle to the front (key-window
    /// restoration on activation, drag starts, future code). The handle's
    /// interactive grab sits inside the selection, away from the control bar,
    /// so sharing the control bar's level is safe.
    static let moveHandle = NSWindow.Level(
        rawValue: NSWindow.Level.floating.rawValue + 2
    )
    /// Settings window – above all translation UI so it is never obscured.
    static let settings = NSWindow.Level(
        rawValue: NSWindow.Level.floating.rawValue + 4
    )
}

func regionPresentationColor(
    for state: RegionBorderController.PresentationState
) -> NSColor {
    switch state {
    case .automatic: .systemBlue
    case .automaticPaused: .systemOrange
    case .manual: .systemPurple
    }
}

@MainActor
private func regionHoverColor(_ color: NSColor, opacity: CGFloat) -> NSColor {
    let brighterColor = color.blended(
        withFraction: RegionBorderTuning.hoverWhiteBlend, of: .white
    ) ?? color
    return brighterColor.withAlphaComponent(min(
        1, opacity + RegionBorderTuning.hoverAlphaBoost
    ))
}

@MainActor
final class RegionBorderController: NSObject {
    enum Edge: Equatable { case top, bottom, left, right, topLeft, topRight, bottomLeft, bottomRight }
    enum Change: Equatable { case move(delta: CGPoint), resize(Edge) }
    enum PresentationState: Equatable { case automatic, automaticPaused, manual }

    // The border's hit band (inward/outward from the selection edge) lives
    // in RegionBorderTuning — tune the line-relative values there; the move
    // handle's resize strips mirror these exact widths.
    private let inwardHitWidth = RegionBorderTuning.inwardHitWidth
    private let outwardHitWidth = RegionBorderTuning.outwardHitWidth
    private let visualBorder = RegionVisualBorderPanel()
    private let dockingSeam = MirrorDockingSeamPanel()
    private let moveHandle = RegionMoveHandlePanel()
    private let endButton = RegionEndButtonPanel()
    private var panels: [Edge: RegionEdgePanel] = [:]
    private(set) var selection: CGRect
    private var screen: NSScreen
    private var activationObservers: [NSObjectProtocol] = []
    private var hoveredEdge: Edge?
    private var overlayDocking: OverlayControlBarDocking?
    private var overlayControlBarFrame: CGRect?
    private var mirrorDocking: MirrorDockingState = .undocked
    private var mirrorSeamFrame: CGRect?
    var onChange: ((CGRect, NSScreen, Change, Bool) -> Void)?
    /// Fired when the border's end-translation button is clicked.
    var onEndTranslation: (() -> Void)?

    init(selection: CGRect, screen: NSScreen, opacity: CGFloat) {
        self.selection = selection
        self.screen = screen
        super.init()
        visualBorder.setOpacity(opacity)
        // Four edge panels. Each is a band (inwardHitWidth inside, outwardHitWidth
        // outside) extended past the outline corners, so corner diagonal zones
        // are covered by the same panels and no corner windows are needed.
        for edge in [Edge.top, .bottom, .left, .right] {
            let panel = RegionEdgePanel(edge: edge)
            panel.onDrag = { [weak self] edge, startRect, startPoint, point, finished in
                self?.drag(edge: edge, startRect: startRect, startPoint: startPoint,
                           point: point, move: false, finished: finished)
            }
            panel.onHover = { [weak self] edge in self?.setHoveredEdge(edge) }
            panels[edge] = panel
        }
        moveHandle.onDrag = { [weak self] startRect, startPoint, point, finished in
            self?.drag(edge: .top, startRect: startRect, startPoint: startPoint,
                       point: point, move: true, finished: finished)
        }
        moveHandle.onHover = { [weak self] hovering in
            self?.setHoveredEdge(nil)
        }
        // The handle's hover/drag highlight is drawn by the visual border
        // panel now.
        moveHandle.onHighlightChange = { [weak self] highlighted in
            self?.visualBorder.setHandleHighlighted(highlighted)
        }
        endButton.onActivate = { [weak self] in
            self?.onEndTranslation?()
        }
        endButton.onHover = { [weak self] hovering in
            self?.setHoveredEdge(nil)
        }
        // The button's hover/press highlight is drawn by the visual border
        // panel too.
        endButton.onHighlightChange = { [weak self] highlighted in
            self?.visualBorder.setEndButtonHighlighted(highlighted)
        }
        layout(selection)
        visualBorder.orderFrontRegardless()
        panels.values.forEach { $0.orderFrontRegardless() }
        installActivationObservers()
        updateForApplicationActivation()
    }

    func setSelection(_ rect: CGRect) { selection = rect; layout(rect) }

    func setScreen(_ screen: NSScreen) { self.screen = screen }

    /// Shows or hides the mirror-mode border chrome: the move handle welded
    /// to the selection's top-left corner and the end-translation button
    /// welded to the top-right corner. Both exist only in mirror mode.
    func setChromeVisible(_ visible: Bool) {
        moveHandle.setExternallyVisible(visible)
        endButton.setExternallyVisible(visible)
        if visible {
            // The panels are a level above the chrome structurally; keep them
            // fronted within their level anyway.
            panels.values.forEach { $0.orderFrontRegardless() }
        }
        updateChromeDrawing()
    }

    func setOverlayControlBarFrame(
        _ frame: CGRect?, docking: OverlayControlBarDocking?
    ) {
        overlayControlBarFrame = frame
        overlayDocking = docking
        updateHiddenEdge()
        layout(selection)
    }

    func setMirrorDocking(_ docking: MirrorDockingState, seamFrame: CGRect?) {
        mirrorDocking = docking
        mirrorSeamFrame = seamFrame
        updateHiddenEdge()
        if docking == .undocked || seamFrame == nil {
            dockingSeam.orderOut(nil)
        } else if let seamFrame {
            dockingSeam.setFrame(seamFrame, display: true)
            dockingSeam.setDirection(docking)
            dockingSeam.orderFrontRegardless()
        }
    }

    private func updateHiddenEdge() {
        // Only the overlay control bar join hides a border edge. Mirror
        // docking leaves the region border completely unchanged — the
        // docking seam is drawn on top of the border instead.
        if let overlayDocking {
            visualBorder.setHiddenEdge(
                overlayDocking == .aboveSelection ? .top : .bottom
            )
        } else {
            visualBorder.setHiddenEdge(nil)
        }
    }

    func setOpacity(_ opacity: CGFloat) {
        visualBorder.setOpacity(opacity)
    }

    func setPresentationState(_ state: PresentationState) {
        visualBorder.setPresentationState(state)
        // The docking seam follows the border color so it reads as part of
        // the selection UI, matching the drag-time dock preview.
        dockingSeam.setColor(regionPresentationColor(for: state))
    }

    /// Forwards the chrome shapes (the move handle and the end button, in the
    /// visual panel's coordinates) for drawing, or clears each when it is
    /// hidden or unavailable.
    private func updateChromeDrawing() {
        if let shape = moveHandle.handleShapeFrame, moveHandle.isShown {
            visualBorder.setHandleShape(shape.offsetBy(
                dx: -visualBorder.frame.minX, dy: -visualBorder.frame.minY
            ))
        } else {
            visualBorder.setHandleShape(nil)
        }
        if let shape = endButton.endButtonShapeFrame, endButton.isShown {
            visualBorder.setEndButtonShape(shape.offsetBy(
                dx: -visualBorder.frame.minX, dy: -visualBorder.frame.minY
            ))
        } else {
            visualBorder.setEndButtonShape(nil)
        }
    }

    func ownsInteractionWindow(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        return window === moveHandle || window === endButton
            || panels.values.contains { $0 === window }
    }

    fileprivate func interactionWindowOwnershipViolationsForSelfTest() -> [String] {
        var violations: [String] = []
        if !ownsInteractionWindow(moveHandle) {
            violations.append("region move panel must belong to the translation session")
        }
        if !ownsInteractionWindow(endButton) {
            violations.append("region end button panel must belong to the translation session")
        }
        if panels.values.contains(where: { !ownsInteractionWindow($0) }) {
            violations.append("region edge panels must belong to the translation session")
        }
        if ownsInteractionWindow(visualBorder) {
            violations.append("visual-only region border must not become a session key window")
        }
        return violations
    }

    /// The move handle's outline sits exactly on the selection's border lines
    /// (selection edge + borderOutset), leaving no gap, and the shape stays
    /// within the selection. Only checked while the handle is actually shown.
    fileprivate func moveHandleGeometryViolationsForSelfTest() -> [String] {
        guard let shapeFrame = moveHandle.handleShapeFrame else { return [] }
        var violations: [String] = []
        let outset = RegionBorderTuning.borderOutset
        if abs(shapeFrame.minX - (selection.minX - outset)) > 0.5
            || abs(shapeFrame.maxY - (selection.maxY + outset)) > 0.5 {
            violations.append("region move handle outline must merge with the border lines")
        }
        if shapeFrame.maxX > selection.maxX + 0.5 || shapeFrame.minY < selection.minY - 0.5 {
            violations.append("region move handle shape must stay within the selection bounds")
        }
        if let handleView = moveHandle.contentView as? RegionMoveHandleView {
            // The whole handle window is the move grab; its interior must be
            // interactive.
            if handleView.hitTest(CGPoint(x: handleView.bounds.midX, y: handleView.bounds.midY)) !== handleView {
                violations.append("region move handle must grab moves in its interior")
            }
        }
        return violations
    }

    /// Regression guard for the "resize doesn't work on the border attached
    /// to the move handle" bug. The handle's interaction window is exactly its
    /// drawn shape (the move grab): its interior must stay panel-free so the
    /// click reaches the handle and moves, the border band over the handle's
    /// welded edges must stay covered by the edge panels (so resizing works
    /// there), the shape must not protrude beyond the panels' extent, and the
    /// edge panels must stay ordered above the handle (structurally, by window
    /// level) so the border clicks reach them directly instead of relying on
    /// hit-test fall-through through the handle window.
    fileprivate func moveHandleInteractionViolationsForSelfTest() -> [String] {
        guard let shape = moveHandle.handleShapeFrame, moveHandle.isVisible else { return [] }
        var violations: [String] = []
        // The handle window is the grab; its interior must be panel-free so
        // clicking it moves. The top/left edges are welded to the border and
        // may be covered by the band (the panels win there — resize), so only
        // the interior is probed.
        for interior in [
            CGPoint(x: shape.midX, y: shape.midY),
            CGPoint(x: shape.midX, y: shape.minY + 6),
            CGPoint(x: shape.minX + 6, y: shape.midY)
        ] {
            if panels.values.contains(where: { $0.frame.contains(interior) }) {
                violations.append("move handle interior must not overlap the border band")
            }
        }
        // The border band over the handle's welded edges must be covered by a
        // panel, so the border attached to the handle stays resizable.
        for bandPoint in [
            CGPoint(x: shape.midX, y: shape.maxY),      // top edge (on the border line)
            CGPoint(x: shape.minX, y: shape.midY)       // left edge (on the border line)
        ] {
            if !panels.values.contains(where: { $0.frame.contains(bandPoint) }) {
                violations.append("border band over the move handle must be covered by an edge panel")
            }
        }
        // The handle must not protrude beyond the resize panels' extent (the
        // window includes the grab-edge margin).
        let panelsBounds = panels.values.reduce(CGRect.null) { $0.union($1.frame) }
        if !panelsBounds.insetBy(dx: -1, dy: -1).contains(moveHandle.frame) {
            violations.append("move handle window must stay within the resize panels' extent")
        }
        // The edge panels must stay above the handle in window z-order so the
        // border clicks reach the panels directly (the historical fix for
        // this bug relied on this ordering, not on hit-test fall-through).
        if let orderedNumbers = NSWindow.windowNumbers(options: []),
           let handleIndex = orderedNumbers.firstIndex(of: NSNumber(value: moveHandle.windowNumber)),
           let frontmostPanelIndex = panels.values
               .compactMap({ orderedNumbers.firstIndex(of: NSNumber(value: $0.windowNumber)) })
               .min(),
           handleIndex < frontmostPanelIndex {
            violations.append("edge panels must stay ordered above the move handle")
        }
        // The handle sits one window level below the panels, so even bringing
        // it to the front (as key-window restoration on reactivation does)
        // must leave the panels above it — resize on the border attached to
        // the handle must never rely on per-path re-ordering.
        moveHandle.makeKeyAndOrderFront(nil)
        updateForApplicationActivation()
        if let orderedNumbers = NSWindow.windowNumbers(options: []),
           let handleIndex = orderedNumbers.firstIndex(of: NSNumber(value: moveHandle.windowNumber)),
           let frontmostPanelIndex = panels.values
               .compactMap({ orderedNumbers.firstIndex(of: NSNumber(value: $0.windowNumber)) })
               .min(),
           handleIndex < frontmostPanelIndex {
            violations.append("edge panels must stay ordered above the move handle after activation")
        }
        return violations
    }

    /// The end-translation button's outline sits exactly on the selection's
    /// border lines (selection edge + borderOutset), leaving no gap, and the
    /// shape stays within the selection. Only checked while the button is
    /// actually shown.
    fileprivate func endButtonGeometryViolationsForSelfTest() -> [String] {
        guard let shapeFrame = endButton.endButtonShapeFrame else { return [] }
        var violations: [String] = []
        let outset = RegionBorderTuning.borderOutset
        if abs(shapeFrame.maxX - (selection.maxX + outset)) > 0.5
            || abs(shapeFrame.maxY - (selection.maxY + outset)) > 0.5 {
            violations.append("region end button outline must merge with the border lines")
        }
        if shapeFrame.minX < selection.minX - 0.5 || shapeFrame.minY < selection.minY - 0.5 {
            violations.append("region end button shape must stay within the selection bounds")
        }
        if let buttonView = endButton.contentView as? RegionEndButtonView {
            // The whole button window is the click target; its interior must
            // be interactive.
            if buttonView.hitTest(CGPoint(x: buttonView.bounds.midX, y: buttonView.bounds.midY)) !== buttonView {
                violations.append("region end button must receive clicks in its interior")
            }
        }
        return violations
    }

    /// The end button mirrors the move handle's interaction contract on the
    /// top-right corner: the button window is exactly its drawn shape (the
    /// click target), its interior must stay panel-free so the click reaches
    /// the button, the border band over its welded edges must stay covered by
    /// the edge panels (so resizing works there), and the edge panels must
    /// stay ordered above it (structurally, by window level).
    fileprivate func endButtonInteractionViolationsForSelfTest() -> [String] {
        guard let shape = endButton.endButtonShapeFrame, endButton.isVisible else { return [] }
        var violations: [String] = []
        // The top/right edges are welded to the border and may be covered by
        // the band (the panels win there — resize), so only the interior is
        // probed.
        for interior in [
            CGPoint(x: shape.midX, y: shape.midY),
            CGPoint(x: shape.midX, y: shape.minY + 6),
            CGPoint(x: shape.maxX - 6, y: shape.midY)
        ] {
            if panels.values.contains(where: { $0.frame.contains(interior) }) {
                violations.append("end button interior must not overlap the border band")
            }
        }
        // The border band over the button's welded edges must be covered by a
        // panel, so the border attached to the button stays resizable.
        for bandPoint in [
            CGPoint(x: shape.midX, y: shape.maxY),      // top edge (on the border line)
            CGPoint(x: shape.maxX, y: shape.midY)       // right edge (on the border line)
        ] {
            if !panels.values.contains(where: { $0.frame.contains(bandPoint) }) {
                violations.append("border band over the end button must be covered by an edge panel")
            }
        }
        // The button must not protrude beyond the resize panels' extent (the
        // window includes the grab-edge margin).
        let panelsBounds = panels.values.reduce(CGRect.null) { $0.union($1.frame) }
        if !panelsBounds.insetBy(dx: -1, dy: -1).contains(endButton.frame) {
            violations.append("end button window must stay within the resize panels' extent")
        }
        // The edge panels must stay above the button in window z-order so the
        // border clicks reach the panels directly, mirroring the move handle.
        if let orderedNumbers = NSWindow.windowNumbers(options: []),
           let buttonIndex = orderedNumbers.firstIndex(of: NSNumber(value: endButton.windowNumber)),
           let frontmostPanelIndex = panels.values
               .compactMap({ orderedNumbers.firstIndex(of: NSNumber(value: $0.windowNumber)) })
               .min(),
           buttonIndex < frontmostPanelIndex {
            violations.append("edge panels must stay ordered above the end button")
        }
        // The button sits one window level below the panels, so even bringing
        // it to the front (as key-window restoration on reactivation does)
        // must leave the panels above it.
        endButton.makeKeyAndOrderFront(nil)
        updateForApplicationActivation()
        if let orderedNumbers = NSWindow.windowNumbers(options: []),
           let buttonIndex = orderedNumbers.firstIndex(of: NSNumber(value: endButton.windowNumber)),
           let frontmostPanelIndex = panels.values
               .compactMap({ orderedNumbers.firstIndex(of: NSNumber(value: $0.windowNumber)) })
               .min(),
           buttonIndex < frontmostPanelIndex {
            violations.append("edge panels must stay ordered above the end button after activation")
        }
        return violations
    }

    /// The border's hit zones: each edge panel is a band spanning
    /// `inwardHitWidth` inside and `outwardHitWidth` outside the selection
    /// edge (measured from the visible border line), extended past the
    /// outline corners. The outside of the border — edges and corner
    /// diagonals — must resolve to the matching edge/corner, and points
    /// beyond the band plus the selection interior must stay click-through.
    /// Probe offsets are derived from the actual hit widths, so the checks
    /// stay valid whenever the widths are retuned.
    fileprivate func borderHitZoneViolationsForSelfTest() -> [String] {
        var violations: [String] = []
        let outward = outwardHitWidth
        let inward = inwardHitWidth
        // The outside band must be thick enough to probe.
        guard outward >= 2 else { return violations }
        // `probe` lands inside the outside band, `far` clearly beyond it.
        let probe = min(4, outward - 1)
        let far = max(outward, inward) + 2
        // Along-edge corner reach measured from the outline corners.
        let cornerReach = min(18, selection.width / 3, selection.height / 3)
        // An in-band point along the top edge inside the corner zone, offset
        // so it stays within the corner zone for any outward < cornerReach.
        let inBandCornerX = max(1, cornerReach - outward - 2)
        var probes: [(String, CGPoint, Edge?)] = [
            ("top-left diagonal", CGPoint(x: selection.minX - probe, y: selection.maxY + probe), .topLeft),
            ("top-right diagonal", CGPoint(x: selection.maxX + probe, y: selection.maxY + probe), .topRight),
            ("bottom-left diagonal", CGPoint(x: selection.minX - probe, y: selection.minY - probe), .bottomLeft),
            ("bottom-right diagonal", CGPoint(x: selection.maxX + probe, y: selection.minY - probe), .bottomRight),
            ("top in-band edge", CGPoint(x: selection.minX + 40, y: selection.maxY + probe), .top),
            ("top outside", CGPoint(x: selection.midX, y: selection.maxY + probe), .top),
            ("bottom outside", CGPoint(x: selection.midX, y: selection.minY - probe), .bottom),
            ("left outside", CGPoint(x: selection.minX - probe, y: selection.midY), .left),
            ("right outside", CGPoint(x: selection.maxX + probe, y: selection.midY), .right),
            ("top-left far outside", CGPoint(x: selection.minX - far, y: selection.maxY + far), nil),
            ("edge far outside", CGPoint(x: selection.midX, y: selection.maxY + far), nil),
            ("selection interior", CGPoint(x: selection.midX, y: selection.midY), nil)
        ]
        if outward < cornerReach - 1 {
            probes.insert(
                ("top-left in-band corner",
                 CGPoint(x: selection.minX + inBandCornerX, y: selection.maxY + probe),
                 .topLeft),
                at: 4
            )
        }
        // Every corner zone must extend exactly `cornerReach` along each edge
        // from the outline corner — symmetric on all four corners. One probe
        // just inside the reach must resolve the corner, one just outside
        // must resolve the plain edge; this guards the corner-detection base
        // against offset drift (a past regression made some corners grab
        // short and others long).
        let cr = cornerReach
        probes.append(contentsOf: [
            ("top-left corner reach", CGPoint(x: selection.minX + cr - 1, y: selection.maxY + probe), .topLeft),
            ("top-left past corner", CGPoint(x: selection.minX + cr + 1, y: selection.maxY + probe), .top),
            ("top-right corner reach", CGPoint(x: selection.maxX - cr + 1, y: selection.maxY + probe), .topRight),
            ("top-right past corner", CGPoint(x: selection.maxX - cr - 1, y: selection.maxY + probe), .top),
            ("bottom-left corner reach", CGPoint(x: selection.minX + cr - 1, y: selection.minY - probe), .bottomLeft),
            ("bottom-left past corner", CGPoint(x: selection.minX + cr + 1, y: selection.minY - probe), .bottom),
            ("bottom-right corner reach", CGPoint(x: selection.maxX - cr + 1, y: selection.minY - probe), .bottomRight),
            ("bottom-right past corner", CGPoint(x: selection.maxX - cr - 1, y: selection.minY - probe), .bottom),
            ("top-left side corner reach", CGPoint(x: selection.minX - probe, y: selection.maxY - cr + 1), .topLeft),
            ("top-left side past corner", CGPoint(x: selection.minX - probe, y: selection.maxY - cr - 1), .left),
            ("top-right side corner reach", CGPoint(x: selection.maxX + probe, y: selection.maxY - cr + 1), .topRight),
            ("top-right side past corner", CGPoint(x: selection.maxX + probe, y: selection.maxY - cr - 1), .right),
            ("bottom-left side corner reach", CGPoint(x: selection.minX - probe, y: selection.minY + cr - 1), .bottomLeft),
            ("bottom-left side past corner", CGPoint(x: selection.minX - probe, y: selection.minY + cr + 1), .left),
            ("bottom-right side corner reach", CGPoint(x: selection.maxX + probe, y: selection.minY + cr - 1), .bottomRight),
            ("bottom-right side past corner", CGPoint(x: selection.maxX + probe, y: selection.minY + cr + 1), .right)
        ])
        for (label, point, expected) in probes {
            let resolving = panels.values.compactMap { panel -> Edge? in
                guard panel.frame.contains(point),
                      let view = panel.contentView as? RegionEdgeView else { return nil }
                return view.resolvedEdge(at: CGPoint(
                    x: point.x - panel.frame.minX, y: point.y - panel.frame.minY
                ))
            }
            if let expected {
                if !resolving.contains(expected) {
                    violations.append("border hit zone: \(label) must resolve to \(expected)")
                }
            } else if !resolving.isEmpty {
                violations.append("border hit zone: \(label) must be click-through")
            }
        }
        return violations
    }

    func close() {
        activationObservers.forEach(NotificationCenter.default.removeObserver)
        activationObservers.removeAll()
        visualBorder.close()
        dockingSeam.close()
        moveHandle.close()
        endButton.close()
        panels.values.forEach { $0.close() }
        panels.removeAll()
    }

    private func installActivationObservers() {
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            let observer = NotificationCenter.default.addObserver(
                forName: name, object: NSApp, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.updateForApplicationActivation() }
            }
            activationObservers.append(observer)
        }
    }

    private func updateForApplicationActivation() {
        panels.values.forEach {
            $0.rebuildCursorRects()
        }
        // No re-ordering needed here: the move handle sits one window level
        // below the edge panels, so nothing that brings it to the front
        // (key-window restoration on activation, drag starts) can shadow them.
        visualBorder.setInteraction(active: true, hoveredEdge: hoveredEdge)
    }

    private func setHoveredEdge(_ edge: Edge?) {
        hoveredEdge = edge
        visualBorder.setInteraction(active: true, hoveredEdge: edge)
    }

    private func layout(_ rect: CGRect) {
        let hitWidth = outwardHitWidth + inwardHitWidth
        visualBorder.setSelection(rect)
        panels.values.forEach { $0.logicalSelection = rect }
        moveHandle.setSelection(rect)
        // The end button must not overlap the move handle on narrow
        // selections; it stays available only when the handle plus the button
        // fit side by side along the top edge.
        endButton.setSelection(rect, moveHandleWidth: moveHandle.handleShapeFrame?.width)
        if mirrorDocking != .undocked, let mirrorSeamFrame {
            dockingSeam.setFrame(mirrorSeamFrame, display: false)
        }
        let combinedFrame = overlayControlBarFrame.map { rect.union($0) } ?? rect
        let topY = overlayDocking == .aboveSelection
            ? combinedFrame.maxY - inwardHitWidth
            : rect.maxY - inwardHitWidth
        let bottomY = overlayDocking == .belowSelection
            ? combinedFrame.minY - outwardHitWidth
            : rect.minY - outwardHitWidth
        // Each edge panel is a 9pt band (1.5pt inward, 7.5pt outward; 3pt/6pt
        // from the visible border line) that also extends past the outline's
        // corners by the outward width, so the corner diagonal zones are
        // covered by the two adjacent panels and the whole outer border is
        // grabbable without extra windows.
        panels[.top]?.setFrame(CGRect(
            x: combinedFrame.minX - outwardHitWidth, y: topY,
            width: combinedFrame.width + 2 * outwardHitWidth, height: hitWidth
        ), display: false)
        panels[.bottom]?.setFrame(CGRect(
            x: combinedFrame.minX - outwardHitWidth, y: bottomY,
            width: combinedFrame.width + 2 * outwardHitWidth, height: hitWidth
        ), display: false)
        panels[.left]?.setFrame(CGRect(
            x: combinedFrame.minX - outwardHitWidth,
            y: combinedFrame.minY - outwardHitWidth,
            width: hitWidth, height: combinedFrame.height + 2 * outwardHitWidth
        ), display: false)
        panels[.right]?.setFrame(CGRect(
            x: combinedFrame.maxX - inwardHitWidth,
            y: combinedFrame.minY - outwardHitWidth,
            width: hitWidth, height: combinedFrame.height + 2 * outwardHitWidth
        ), display: false)
        panels.values.forEach { $0.setExternallyVisible(true) }
        // Set the outline after the frames so the views receive it offset
        // into their own (current) coordinates for corner detection.
        panels.values.forEach { $0.logicalOutline = combinedFrame }
        // The move handle and end button are a window level below, so the
        // border attached to them stays resizable no matter what re-orders
        // them; keep the panels fronted within their level anyway.
        panels.values.forEach { $0.orderFrontRegardless() }
        updateChromeDrawing()
    }

    private func drag(
        edge: Edge, startRect: CGRect, startPoint: CGPoint, point: CGPoint,
        move: Bool, finished: Bool
    ) {
        let delta = CGPoint(x: point.x - startPoint.x, y: point.y - startPoint.y)
        var rect = startRect
        if move {
            rect.origin.x += delta.x
            rect.origin.y += delta.y
            if let target = NSScreen.screens.first(where: { $0.frame.contains(point) }) {
                screen = target
            }
            rect.origin.x = min(max(screen.frame.minX, rect.origin.x), screen.frame.maxX - rect.width)
            rect.origin.y = min(max(screen.frame.minY, rect.origin.y), screen.frame.maxY - rect.height)
        } else {
            switch edge {
            case .top: rect.size.height = max(20, startRect.height + delta.y)
            case .bottom:
                let maxY = startRect.maxY
                rect.origin.y = min(maxY - 20, startRect.minY + delta.y)
                rect.size.height = maxY - rect.minY
            case .left:
                let maxX = startRect.maxX
                rect.origin.x = min(maxX - 32, startRect.minX + delta.x)
                rect.size.width = maxX - rect.minX
            case .right: rect.size.width = max(32, startRect.width + delta.x)
            case .topLeft:
                let maxX = startRect.maxX
                rect.origin.x = min(maxX - 32, startRect.minX + delta.x)
                rect.size.width = maxX - rect.minX
                rect.size.height = max(20, startRect.height + delta.y)
            case .topRight:
                rect.size.width = max(32, startRect.width + delta.x)
                rect.size.height = max(20, startRect.height + delta.y)
            case .bottomLeft:
                let maxX = startRect.maxX, maxY = startRect.maxY
                rect.origin.x = min(maxX - 32, startRect.minX + delta.x)
                rect.origin.y = min(maxY - 20, startRect.minY + delta.y)
                rect.size = CGSize(width: maxX - rect.minX, height: maxY - rect.minY)
            case .bottomRight:
                let maxY = startRect.maxY
                rect.origin.y = min(maxY - 20, startRect.minY + delta.y)
                rect.size = CGSize(width: max(32, startRect.width + delta.x), height: maxY - rect.minY)
            }
            rect = rect.intersection(screen.frame)
        }
        guard rect.width >= 32, rect.height >= 20 else { return }
        selection = rect
        layout(rect)
        let change: Change = move
            ? .move(delta: CGPoint(x: rect.minX - startRect.minX, y: rect.minY - startRect.minY))
            : .resize(edge)
        onChange?(rect, screen, change, finished)
    }
}

@MainActor
private final class RegionVisualBorderPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = RegionWindowLevel.visual
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        collectionBehavior = [.fullScreenAuxiliary, .stationary]
        contentView = RegionVisualBorderView()
    }

    func setSelection(_ rect: CGRect) {
        let inset = RegionBorderTuning.effectInset
        setFrame(rect.insetBy(dx: -inset, dy: -inset), display: true)
    }

    func setInteraction(active: Bool, hoveredEdge: RegionBorderController.Edge?) {
        (contentView as? RegionVisualBorderView)?.setInteraction(active: active, hoveredEdge: hoveredEdge)
    }

    func setPresentationState(_ state: RegionBorderController.PresentationState) {
        (contentView as? RegionVisualBorderView)?.setPresentationState(state)
    }

    func setHiddenEdge(_ edge: RegionBorderController.Edge?) {
        (contentView as? RegionVisualBorderView)?.hiddenEdge = edge
    }

    func setOpacity(_ opacity: CGFloat) {
        (contentView as? RegionVisualBorderView)?.opacity = RegionBorderOpacity.clamp(opacity)
    }

    /// The move handle's shape in this panel's view coordinates (nil = not
    /// drawn). The handle's drawing lives here with the border so the two
    /// share one coordinate space and stay exactly aligned.
    func setHandleShape(_ shape: CGRect?) {
        (contentView as? RegionVisualBorderView)?.handleShape = shape
    }

    /// Hover/drag highlight state for the drawn move handle.
    func setHandleHighlighted(_ highlighted: Bool) {
        (contentView as? RegionVisualBorderView)?.handleHighlighted = highlighted
    }

    /// The end-translation button's shape in this panel's view coordinates
    /// (nil = not drawn), drawn with the same effect stack as the handle.
    func setEndButtonShape(_ shape: CGRect?) {
        (contentView as? RegionVisualBorderView)?.endButtonShape = shape
    }

    /// Hover/press highlight state for the drawn end-translation button.
    func setEndButtonHighlighted(_ highlighted: Bool) {
        (contentView as? RegionVisualBorderView)?.endButtonHighlighted = highlighted
    }

}

@MainActor
private final class RegionVisualBorderView: NSView {
    private var active = false
    private var hoveredEdge: RegionBorderController.Edge?
    private var presentationState: RegionBorderController.PresentationState = .automatic
    var opacity = RegionBorderOpacity.defaultValue { didSet { needsDisplay = true } }
    var hiddenEdge: RegionBorderController.Edge? { didSet { needsDisplay = true } }
    /// The move handle's shape in this view's coordinates (nil = not drawn).
    var handleShape: CGRect? = nil { didSet { needsDisplay = true } }
    /// Hover or drag state for the drawn move handle.
    var handleHighlighted = false { didSet { needsDisplay = true } }
    /// The end-translation button's shape in this view's coordinates (nil =
    /// not drawn).
    var endButtonShape: CGRect? = nil { didSet { needsDisplay = true } }
    /// Hover or press state for the drawn end-translation button.
    var endButtonHighlighted = false { didSet { needsDisplay = true } }

    private var borderColor: NSColor {
        regionPresentationColor(for: presentationState)
    }

    func setInteraction(active: Bool, hoveredEdge: RegionBorderController.Edge?) {
        self.active = active
        self.hoveredEdge = hoveredEdge
        needsDisplay = true
    }

    func setPresentationState(_ state: RegionBorderController.PresentationState) {
        guard presentationState != state else { return }
        presentationState = state
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let joinsControlBar = hiddenEdge != nil
        // The material's faint inner edge sits one point outside the logical
        // selection; the darker NSWindow shadow extends farther outward.
        let pathInset = RegionBorderTuning.effectInset
            - RegionBorderTuning.borderOutset
        let rect = bounds.insetBy(dx: pathInset, dy: pathInset)
        let radius: CGFloat = 10
        let path: NSBezierPath
        var joinedPath: NSBezierPath?
        var effectRect = rect
        switch hiddenEdge {
        case .top:
            // Put the full 1pt stroke just inside the control bar frame: its
            // outer edge lands exactly on the window boundary at selection+2.
            effectRect.size.height += RegionBorderTuning.joinedEdgeExtension
            path = NSBezierPath()
            path.move(to: CGPoint(x: rect.minX, y: effectRect.maxY))
            path.line(to: CGPoint(x: rect.minX, y: rect.minY + radius))
            path.curve(to: CGPoint(x: rect.minX + radius, y: rect.minY),
                       controlPoint1: CGPoint(x: rect.minX, y: rect.minY + radius / 2),
                       controlPoint2: CGPoint(x: rect.minX + radius / 2, y: rect.minY))
            path.line(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
            path.curve(to: CGPoint(x: rect.maxX, y: rect.minY + radius),
                       controlPoint1: CGPoint(x: rect.maxX - radius / 2, y: rect.minY),
                       controlPoint2: CGPoint(x: rect.maxX, y: rect.minY + radius / 2))
            path.line(to: CGPoint(x: rect.maxX, y: effectRect.maxY))
            joinedPath = NSBezierPath()
            joinedPath?.move(to: CGPoint(x: rect.minX, y: effectRect.maxY))
            joinedPath?.line(to: CGPoint(x: rect.maxX, y: effectRect.maxY))
        case .bottom:
            let extensionAmount = RegionBorderTuning.joinedEdgeExtension
            effectRect.origin.y -= extensionAmount
            effectRect.size.height += extensionAmount
            path = NSBezierPath()
            path.move(to: CGPoint(x: rect.minX, y: effectRect.minY))
            path.line(to: CGPoint(x: rect.minX, y: rect.maxY - radius))
            path.curve(to: CGPoint(x: rect.minX + radius, y: rect.maxY),
                       controlPoint1: CGPoint(x: rect.minX, y: rect.maxY - radius / 2),
                       controlPoint2: CGPoint(x: rect.minX + radius / 2, y: rect.maxY))
            path.line(to: CGPoint(x: rect.maxX - radius, y: rect.maxY))
            path.curve(to: CGPoint(x: rect.maxX, y: rect.maxY - radius),
                       controlPoint1: CGPoint(x: rect.maxX - radius / 2, y: rect.maxY),
                       controlPoint2: CGPoint(x: rect.maxX, y: rect.maxY - radius / 2))
            path.line(to: CGPoint(x: rect.maxX, y: effectRect.minY))
            joinedPath = NSBezierPath()
            joinedPath?.move(to: CGPoint(x: rect.minX, y: effectRect.minY))
            joinedPath?.line(to: CGPoint(x: rect.maxX, y: effectRect.minY))
        case .left:
            path = NSBezierPath()
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.line(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
            path.curve(to: CGPoint(x: rect.maxX, y: rect.minY + radius),
                       controlPoint1: CGPoint(x: rect.maxX - radius / 2, y: rect.minY),
                       controlPoint2: CGPoint(x: rect.maxX, y: rect.minY + radius / 2))
            path.line(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
            path.curve(to: CGPoint(x: rect.maxX - radius, y: rect.maxY),
                       controlPoint1: CGPoint(x: rect.maxX, y: rect.maxY - radius / 2),
                       controlPoint2: CGPoint(x: rect.maxX - radius / 2, y: rect.maxY))
            path.line(to: CGPoint(x: rect.minX, y: rect.maxY))
        case .right:
            path = NSBezierPath()
            path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.line(to: CGPoint(x: rect.minX + radius, y: rect.minY))
            path.curve(to: CGPoint(x: rect.minX, y: rect.minY + radius),
                       controlPoint1: CGPoint(x: rect.minX + radius / 2, y: rect.minY),
                       controlPoint2: CGPoint(x: rect.minX, y: rect.minY + radius / 2))
            path.line(to: CGPoint(x: rect.minX, y: rect.maxY - radius))
            path.curve(to: CGPoint(x: rect.minX + radius, y: rect.maxY),
                       controlPoint1: CGPoint(x: rect.minX, y: rect.maxY - radius / 2),
                       controlPoint2: CGPoint(x: rect.minX + radius / 2, y: rect.maxY))
            path.line(to: CGPoint(x: rect.maxX, y: rect.maxY))
        default:
            path = NSBezierPath()
            path.move(to: CGPoint(x: rect.minX, y: rect.minY + radius))
            path.curve(to: CGPoint(x: rect.minX + radius, y: rect.minY),
                       controlPoint1: CGPoint(x: rect.minX, y: rect.minY + radius / 2),
                       controlPoint2: CGPoint(x: rect.minX + radius / 2, y: rect.minY))
            path.line(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
            path.curve(to: CGPoint(x: rect.maxX, y: rect.minY + radius),
                       controlPoint1: CGPoint(x: rect.maxX - radius / 2, y: rect.minY),
                       controlPoint2: CGPoint(x: rect.maxX, y: rect.minY + radius / 2))
            path.line(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
            path.curve(to: CGPoint(x: rect.maxX - radius, y: rect.maxY),
                       controlPoint1: CGPoint(x: rect.maxX, y: rect.maxY - radius / 2),
                       controlPoint2: CGPoint(x: rect.maxX - radius / 2, y: rect.maxY))
            path.line(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
            path.curve(to: CGPoint(x: rect.minX, y: rect.maxY - radius),
                       controlPoint1: CGPoint(x: rect.minX + radius / 2, y: rect.maxY),
                       controlPoint2: CGPoint(x: rect.minX, y: rect.maxY - radius / 2))
            path.close()
        }
        let effectShape = path.copy() as! NSBezierPath
        effectShape.close()
        path.lineWidth = RegionBorderTuning.borderLineWidth
        joinedPath?.lineWidth = RegionBorderTuning.borderLineWidth
        RegionBorderDrawing.drawOuterShadow(
            path: path, shape: effectShape, in: bounds,
            layers: RegionBorderTuning.borderShadowLayers, opacity: opacity
        )
        RegionBorderDrawing.drawInnerGlow(
            shape: effectShape, in: bounds, color: borderColor,
            blur: RegionBorderTuning.innerGlowBlur,
            alpha: opacity * RegionBorderTuning.innerGlowAlpha
        )
        if joinsControlBar, let joinedPath, let hiddenEdge {
            drawJoinedEffects(path: joinedPath, edge: hiddenEdge)
        }
        borderColor.withAlphaComponent(opacity).setStroke()
        path.stroke()
        joinedPath?.stroke()
        if active, RegionBorderTuning.hoverHighlightEnabled,
           let hoveredEdge,
           !(hiddenEdge == .top && [.top, .topLeft, .topRight].contains(hoveredEdge)),
           !(hiddenEdge == .bottom && [.bottom, .bottomLeft, .bottomRight].contains(hoveredEdge)) {
            let length = RegionBorderTuning.hoverSegmentLength
            // Draw over the base border's centerline so hover changes only
            // color, never the visual thickness or the selection's apparent
            // bounds.
            regionHoverColor(borderColor, opacity: opacity).setStroke()
        let hoverPath = NSBezierPath()
        hoverPath.lineWidth = RegionBorderTuning.hoverLineWidth
        hoverPath.lineCapStyle = .round
        let roundsTopCorners = hiddenEdge != .top
        let roundsBottomCorners = hiddenEdge != .bottom
        switch hoveredEdge {
        case .top: hoverPath.move(to: CGPoint(x: rect.minX + length, y: rect.maxY)); hoverPath.line(to: CGPoint(x: rect.maxX - length, y: rect.maxY))
        case .bottom: hoverPath.move(to: CGPoint(x: rect.minX + length, y: rect.minY)); hoverPath.line(to: CGPoint(x: rect.maxX - length, y: rect.minY))
        case .left:
            hoverPath.move(to: CGPoint(
                x: rect.minX, y: hiddenEdge == .bottom ? rect.minY : rect.minY + length
            ))
            hoverPath.line(to: CGPoint(
                x: rect.minX, y: hiddenEdge == .top ? rect.maxY : rect.maxY - length
            ))
        case .right:
            hoverPath.move(to: CGPoint(
                x: rect.maxX, y: hiddenEdge == .bottom ? rect.minY : rect.minY + length
            ))
            hoverPath.line(to: CGPoint(
                x: rect.maxX, y: hiddenEdge == .top ? rect.maxY : rect.maxY - length
            ))
        case .topLeft:
            hoverPath.move(to: CGPoint(x: rect.minX, y: rect.maxY - length))
            if roundsTopCorners {
                hoverPath.line(to: CGPoint(x: rect.minX, y: rect.maxY - radius))
                hoverPath.curve(to: CGPoint(x: rect.minX + radius, y: rect.maxY),
                                controlPoint1: CGPoint(x: rect.minX, y: rect.maxY - radius / 2),
                                controlPoint2: CGPoint(x: rect.minX + radius / 2, y: rect.maxY))
            } else {
                hoverPath.line(to: CGPoint(x: rect.minX, y: rect.maxY))
            }
            hoverPath.line(to: CGPoint(x: rect.minX + length, y: rect.maxY))
        case .topRight:
            hoverPath.move(to: CGPoint(x: rect.maxX - length, y: rect.maxY))
            if roundsTopCorners {
                hoverPath.line(to: CGPoint(x: rect.maxX - radius, y: rect.maxY))
                hoverPath.curve(to: CGPoint(x: rect.maxX, y: rect.maxY - radius),
                                controlPoint1: CGPoint(x: rect.maxX - radius / 2, y: rect.maxY),
                                controlPoint2: CGPoint(x: rect.maxX, y: rect.maxY - radius / 2))
            } else {
                hoverPath.line(to: CGPoint(x: rect.maxX, y: rect.maxY))
            }
            hoverPath.line(to: CGPoint(x: rect.maxX, y: rect.maxY - length))
        case .bottomLeft:
            hoverPath.move(to: CGPoint(x: rect.minX, y: rect.minY + length))
            if roundsBottomCorners {
                hoverPath.line(to: CGPoint(x: rect.minX, y: rect.minY + radius))
                hoverPath.curve(to: CGPoint(x: rect.minX + radius, y: rect.minY),
                                controlPoint1: CGPoint(x: rect.minX, y: rect.minY + radius / 2),
                                controlPoint2: CGPoint(x: rect.minX + radius / 2, y: rect.minY))
            } else {
                hoverPath.line(to: CGPoint(x: rect.minX, y: rect.minY))
            }
            hoverPath.line(to: CGPoint(x: rect.minX + length, y: rect.minY))
        case .bottomRight:
            hoverPath.move(to: CGPoint(x: rect.maxX - length, y: rect.minY))
            if roundsBottomCorners {
                hoverPath.line(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
                hoverPath.curve(to: CGPoint(x: rect.maxX, y: rect.minY + radius),
                                controlPoint1: CGPoint(x: rect.maxX - radius / 2, y: rect.minY),
                                controlPoint2: CGPoint(x: rect.maxX, y: rect.minY + radius / 2))
            } else {
                hoverPath.line(to: CGPoint(x: rect.maxX, y: rect.minY))
            }
            hoverPath.line(to: CGPoint(x: rect.maxX, y: rect.minY + length))
        }
            hoverPath.stroke()
        }
        // The move handle renders on top of the border and its hover
        // highlight (its own window used to sit a level above the visual
        // panel), and stays welded to the border lines by construction. The
        // end-translation button mirrors it on the top-right corner.
        if let handleShape {
            drawMoveHandle(shape: handleShape)
        }
        if let endButtonShape {
            drawEndButton(shape: endButtonShape)
        }
    }

    // MARK: - Move handle drawing

    /// The left remnant of a titlebar: the top-left and bottom-right corners
    /// share the border's corner radius; the top-right and bottom-left
    /// corners stay square.
    private func handleShapePath(in rect: CGRect) -> NSBezierPath {
        let radius = RegionBorderTuning.cornerRadius
        let path = NSBezierPath()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.line(to: CGPoint(x: rect.minX, y: rect.maxY - radius))
        path.curve(
            to: CGPoint(x: rect.minX + radius, y: rect.maxY),
            controlPoint1: CGPoint(x: rect.minX, y: rect.maxY - radius / 2),
            controlPoint2: CGPoint(x: rect.minX + radius / 2, y: rect.maxY)
        )
        path.line(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.line(to: CGPoint(x: rect.maxX, y: rect.minY + radius))
        path.curve(
            to: CGPoint(x: rect.maxX - radius, y: rect.minY),
            controlPoint1: CGPoint(x: rect.maxX, y: rect.minY + radius / 2),
            controlPoint2: CGPoint(x: rect.maxX - radius / 2, y: rect.minY)
        )
        path.close()
        return path
    }

    /// Open path of the right and bottom edges only. The handle is welded to
    /// the selection border on its top and left, so those edges must not be
    /// drawn again — drawing them would double the border's line and glow.
    /// This path drives both the outer shadow and the outline stroke.
    private func handleShadowPath(in rect: CGRect) -> NSBezierPath {
        let radius = RegionBorderTuning.cornerRadius
        let path = NSBezierPath()
        path.move(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.line(to: CGPoint(x: rect.maxX, y: rect.minY + radius))
        path.curve(
            to: CGPoint(x: rect.maxX - radius, y: rect.minY),
            controlPoint1: CGPoint(x: rect.maxX, y: rect.minY + radius / 2),
            controlPoint2: CGPoint(x: rect.maxX - radius / 2, y: rect.minY)
        )
        path.line(to: CGPoint(x: rect.minX, y: rect.minY))
        return path
    }

    /// The region whose shadow casts the inner glow along the handle's right
    /// and bottom edges: the padding-wide bands right of and below the shape.
    /// The bands above the top edge and left of the left edge are excluded —
    /// they would glow along the shared edges and double the border's own
    /// glow.
    private func handleGlowSourcePath(shape: CGRect) -> NSBezierPath {
        let padding = RegionBorderTuning.moveHandleShadowPadding
        let source = NSBezierPath()
        source.append(NSBezierPath(rect: CGRect(
            x: shape.maxX, y: bounds.minY,
            width: padding, height: bounds.maxY - bounds.minY
        )))
        source.append(NSBezierPath(rect: CGRect(
            x: bounds.minX, y: bounds.minY,
            width: bounds.width, height: padding
        )))
        return source
    }

    /// Draws the move handle bar with the border's own effect stack: interior
    /// tint on hover/drag, the layered outer shadow and inverse-fill inner
    /// glow along the free (right/bottom) edges, then the base stroke.
    private func drawMoveHandle(shape handleShape: CGRect) {
        let highlights = handleHighlighted && RegionBorderTuning.hoverHighlightEnabled
        let shape = handleShapePath(in: handleShape)
        let outline = handleShadowPath(in: handleShape)

        // Interior: completely empty at idle so content shows through, with a
        // soft tint on hover/drag that signals the handle can be grabbed and
        // moved — deliberately not a solid fill. The fill is inset by half
        // the border line so it meets the top/left border lines and the
        // handle's right/bottom outline exactly, without painting over either.
        let fillPath = handleShapePath(
            in: handleShape.insetBy(
                dx: RegionBorderTuning.borderLineWidth / 2,
                dy: RegionBorderTuning.borderLineWidth / 2
            )
        )
        let fillAlpha = opacity * (highlights
            ? RegionBorderTuning.moveHandleHoverFillAlpha
            : RegionBorderTuning.moveHandleIdleFillAlpha)
        if fillAlpha > 0 {
            borderColor.withAlphaComponent(fillAlpha).setFill()
            fillPath.fill()
        }

        // Only the right and bottom outline is drawn, with the same effect
        // stack as the selection border — the layered outer shadow outside,
        // the inverse-fill inner glow inside, then the base stroke at the
        // border's width and opacity. The top and left stay untouched so the
        // border's own line and glow there remain single.
        RegionBorderDrawing.drawOuterShadow(
            path: outline, shape: shape, in: bounds,
            layers: RegionBorderTuning.borderShadowLayers, opacity: opacity
        )
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        let context = NSGraphicsContext.current!.cgContext
        context.setShadow(
            offset: .zero, blur: RegionBorderTuning.innerGlowBlur,
            color: borderColor
                .withAlphaComponent(opacity * RegionBorderTuning.innerGlowAlpha)
                .cgColor
        )
        NSColor.black.setFill()
        handleGlowSourcePath(shape: handleShape).fill()
        NSGraphicsContext.restoreGraphicsState()
        // Unclipped so the full border line width is visible (clipping would
        // cut the outer half of the stroke along the boundary).
        borderColor.withAlphaComponent(opacity).setStroke()
        outline.lineWidth = RegionBorderTuning.borderLineWidth
        outline.stroke()
        // The grip dots stay visible at all times so the handle reads as
        // grabbable even at idle; they brighten while hovering or dragging.
        drawGripDots(shape: handleShape, highlighted: highlights)
    }

    /// 2×3 grip dots at the handle's center, matching the overlay control
    /// bar's drag grip. Idle dots use the border color at the border's
    /// opacity; hovering or dragging brightens them like the hover highlight
    /// so they read as "grab here".
    private func drawGripDots(shape handleShape: CGRect, highlighted: Bool) {
        let color = highlighted
            ? regionHoverColor(borderColor, opacity: opacity)
            : borderColor.withAlphaComponent(opacity)
        color.setFill()
        let radius: CGFloat = 1.25
        let spacing: CGFloat = 5
        let rect = handleShape.insetBy(
            dx: RegionBorderTuning.borderLineWidth / 2,
            dy: RegionBorderTuning.borderLineWidth / 2
        )
        for column in 0 ..< 2 {
            for row in 0 ..< 3 {
                let center = CGPoint(
                    x: rect.midX + CGFloat(column * 2 - 1) * spacing / 2,
                    y: rect.midY + CGFloat(row - 1) * spacing
                )
                NSBezierPath(ovalIn: CGRect(
                    x: center.x - radius, y: center.y - radius,
                    width: radius * 2, height: radius * 2
                )).fill()
            }
        }
    }

    // MARK: - End-translation button drawing

    /// The mirror of the move handle's titlebar remnant, welded to the
    /// selection's top-right corner: the top-right and bottom-left corners
    /// share the border's corner radius; the top-left and bottom-right
    /// corners stay square.
    private func endButtonShapePath(in rect: CGRect) -> NSBezierPath {
        let radius = RegionBorderTuning.cornerRadius
        let path = NSBezierPath()
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.line(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.curve(
            to: CGPoint(x: rect.maxX - radius, y: rect.maxY),
            controlPoint1: CGPoint(x: rect.maxX, y: rect.maxY - radius / 2),
            controlPoint2: CGPoint(x: rect.maxX - radius / 2, y: rect.maxY)
        )
        path.line(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.line(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.curve(
            to: CGPoint(x: rect.minX + radius, y: rect.minY),
            controlPoint1: CGPoint(x: rect.minX, y: rect.minY + radius / 2),
            controlPoint2: CGPoint(x: rect.minX + radius / 2, y: rect.minY)
        )
        path.close()
        return path
    }

    /// Open path of the bottom and left edges only. The button is welded to
    /// the selection border on its top and right, so those edges must not be
    /// drawn again — drawing them would double the border's line and glow.
    /// This path drives both the outer shadow and the outline stroke.
    private func endButtonShadowPath(in rect: CGRect) -> NSBezierPath {
        let radius = RegionBorderTuning.cornerRadius
        let path = NSBezierPath()
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.line(to: CGPoint(x: rect.minX + radius, y: rect.minY))
        path.curve(
            to: CGPoint(x: rect.minX, y: rect.minY + radius),
            controlPoint1: CGPoint(x: rect.minX + radius / 2, y: rect.minY),
            controlPoint2: CGPoint(x: rect.minX, y: rect.minY + radius / 2)
        )
        path.line(to: CGPoint(x: rect.minX, y: rect.maxY))
        return path
    }

    /// The region whose shadow casts the inner glow along the button's left
    /// and bottom edges: the padding-wide bands left of and below the shape.
    /// The bands above the top edge and right of the right edge are excluded —
    /// they would glow along the shared edges and double the border's own
    /// glow.
    private func endButtonGlowSourcePath(shape: CGRect) -> NSBezierPath {
        let padding = RegionBorderTuning.moveHandleShadowPadding
        let source = NSBezierPath()
        source.append(NSBezierPath(rect: CGRect(
            x: shape.minX - padding, y: bounds.minY,
            width: padding, height: bounds.maxY - bounds.minY
        )))
        source.append(NSBezierPath(rect: CGRect(
            x: bounds.minX, y: bounds.minY,
            width: bounds.width, height: padding
        )))
        return source
    }

    /// Draws the end-translation button with the border's own effect stack,
    /// mirroring the move handle: interior tint on hover/press, the layered
    /// outer shadow and inverse-fill inner glow along the free (bottom/left)
    /// edges, the base stroke, then the always-visible X mark.
    private func drawEndButton(shape endButtonShape: CGRect) {
        let highlights = endButtonHighlighted && RegionBorderTuning.hoverHighlightEnabled
        let shape = endButtonShapePath(in: endButtonShape)
        let outline = endButtonShadowPath(in: endButtonShape)

        // Interior: empty at idle, soft tint on hover/press — deliberately
        // not a solid fill. The fill is inset by half the border line so it
        // meets the top/right border lines and the button's bottom/left
        // outline exactly, without painting over either.
        let fillPath = endButtonShapePath(
            in: endButtonShape.insetBy(
                dx: RegionBorderTuning.borderLineWidth / 2,
                dy: RegionBorderTuning.borderLineWidth / 2
            )
        )
        let fillAlpha = opacity * (highlights
            ? RegionBorderTuning.moveHandleHoverFillAlpha
            : RegionBorderTuning.moveHandleIdleFillAlpha)
        if fillAlpha > 0 {
            borderColor.withAlphaComponent(fillAlpha).setFill()
            fillPath.fill()
        }

        // Only the bottom and left outline is drawn, with the same effect
        // stack as the selection border — the layered outer shadow outside,
        // the inverse-fill inner glow inside, then the base stroke at the
        // border's width and opacity. The top and right stay untouched so the
        // border's own line and glow there remain single.
        RegionBorderDrawing.drawOuterShadow(
            path: outline, shape: shape, in: bounds,
            layers: RegionBorderTuning.borderShadowLayers, opacity: opacity
        )
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        let context = NSGraphicsContext.current!.cgContext
        context.setShadow(
            offset: .zero, blur: RegionBorderTuning.innerGlowBlur,
            color: borderColor
                .withAlphaComponent(opacity * RegionBorderTuning.innerGlowAlpha)
                .cgColor
        )
        NSColor.black.setFill()
        endButtonGlowSourcePath(shape: endButtonShape).fill()
        NSGraphicsContext.restoreGraphicsState()
        // Unclipped so the full border line width is visible (clipping would
        // cut the outer half of the stroke along the boundary).
        borderColor.withAlphaComponent(opacity).setStroke()
        outline.lineWidth = RegionBorderTuning.borderLineWidth
        outline.stroke()
        // The X mark stays visible at all times so the button reads as
        // "end translation" even at idle; it brightens while hovering or
        // pressing.
        drawEndButtonMark(shape: endButtonShape, highlighted: highlights)
    }

    /// Always-visible X mark at the button's center, in the border color at
    /// the border's opacity, brightened like the grip dots while hovering or
    /// pressing.
    private func drawEndButtonMark(shape: CGRect, highlighted: Bool) {
        let color = highlighted
            ? regionHoverColor(borderColor, opacity: opacity)
            : borderColor.withAlphaComponent(opacity)
        color.setStroke()
        let center = CGPoint(x: shape.midX, y: shape.midY)
        let arm = RegionBorderTuning.endButtonMarkArm
        let path = NSBezierPath()
        path.move(to: CGPoint(x: center.x - arm, y: center.y - arm))
        path.line(to: CGPoint(x: center.x + arm, y: center.y + arm))
        path.move(to: CGPoint(x: center.x + arm, y: center.y - arm))
        path.line(to: CGPoint(x: center.x - arm, y: center.y + arm))
        path.lineWidth = RegionBorderTuning.endButtonMarkLineWidth
        path.lineCapStyle = .round
        path.stroke()
    }

    private func drawJoinedEffects(
        path: NSBezierPath, edge: RegionBorderController.Edge
    ) {
        guard opacity > 0 else { return }

        // Keep every effect pixel inside the higher-level control bar window.
        // This preserves natural occlusion at 100% opacity while revealing the
        // complete joined edge as the material becomes transparent.
        let clipRect: CGRect
        switch edge {
        case .top:
            let boundary = path.bounds.maxY + 0.5
            clipRect = CGRect(
                x: bounds.minX, y: boundary,
                width: bounds.width, height: bounds.maxY - boundary
            )
        case .bottom:
            let boundary = path.bounds.minY - 0.5
            clipRect = CGRect(
                x: bounds.minX, y: bounds.minY,
                width: bounds.width, height: boundary - bounds.minY
            )
        default:
            return
        }

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: clipRect).addClip()
        let shadowPath = path.copy() as! NSBezierPath
        for (width, alpha) in RegionBorderTuning.borderShadowLayers {
            shadowPath.lineWidth = width
            NSColor.black.withAlphaComponent(opacity * alpha).setStroke()
            shadowPath.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}

@MainActor
private final class MirrorDockingSeamPanel: NSPanel {
    private let seamView = MirrorDockingSeamView()

    init() {
        super.init(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        level = RegionWindowLevel.visual
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        collectionBehavior = [.fullScreenAuxiliary, .stationary]
        contentView = seamView
    }

    func setDirection(_ direction: MirrorDockingState) {
        seamView.direction = direction
    }

    func setColor(_ color: NSColor) {
        seamView.color = color
    }
}

@MainActor
private final class MirrorDockingSeamView: NSView {
    var direction: MirrorDockingState = .undocked { didSet { needsDisplay = true } }
    /// Follows the region border color so the seam reads as part of the
    /// selection UI, matching the drag-time dock preview.
    var color: NSColor = regionPresentationColor(for: .automatic) {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        RegionBorderDrawing.drawSeam(
            band: bounds, direction: direction,
            color: color,
            bandAlpha: RegionBorderTuning.seamBandAlpha,
            lineAlpha: RegionBorderTuning.seamLineAlpha
        )
    }
}

@MainActor
private final class RegionMoveHandlePanel: NSPanel {
    private let preferredWidth: CGFloat = 80
    private let trailingClearance: CGFloat = 6
    private let handleHeight: CGFloat = 26
    private let minimumUsableWidth: CGFloat = 26
    /// The grab window extends this far beyond the drawn shape on the free
    /// (bottom/right) edges, making the handle easier to catch.
    private let grabEdgeMargin: CGFloat = 2
    private var shapeFrame: CGRect = .zero
    private let handleView = RegionMoveHandleView()
    private var externallyVisible = true
    private var isAvailable = false
    private var logicalSelection: CGRect = .zero
    private var startRect: CGRect?
    private var startPoint: CGPoint?
    private var isDragging = false
    private var isHovered = false
    var onDrag: ((CGRect, CGPoint, CGPoint, Bool) -> Void)?
    /// Hover changes (clears the border's edge hover while over the handle).
    var onHover: ((Bool) -> Void)?
    /// Hover or drag state for the handle's highlight (drawn by the visual
    /// border panel).
    var onHighlightChange: ((Bool) -> Void)?

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        // One level below the edge panels: the border attached to the handle
        // must always stay resizable, and the level gap guarantees the panels
        // win over the handle no matter what re-orders the handle.
        level = RegionWindowLevel.moveHandle
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.fullScreenAuxiliary, .stationary]
        ignoresMouseEvents = true
        acceptsMouseMovedEvents = true
        contentView = handleView
        handleView.onDrag = { [weak self] phase, point in
            self?.handle(phase: phase, point: point)
        }
        handleView.onHover = { [weak self] hovering in
            guard let self else { return }
            self.isHovered = hovering
            self.onHover?(hovering)
            self.onHighlightChange?(hovering || self.isDragging)
        }
    }

    override var canBecomeKey: Bool { true }

    /// The handle reads as the left remnant of a titlebar welded to the
    /// selection: its shape's top and left edges sit exactly on the border
    /// lines (selection edge + borderOutset), leaving no gap. The window IS
    /// the grab area (the drawn shape), with no shadow padding — the handle's
    /// drawing lives in the click-through visual border panel now, so the
    /// interaction window stays inside the resize panels' extent. Because
    /// Rearview's own windows are excluded from capture, the handle never
    /// appears in the translated output.
    func setSelection(_ rect: CGRect) {
        logicalSelection = rect
        let availableWidth = max(0, rect.width - trailingClearance)
        let width = min(preferredWidth, availableWidth)
        isAvailable = width >= minimumUsableWidth
        if isAvailable {
            shapeFrame = CGRect(
                x: rect.minX - RegionBorderTuning.borderOutset,
                y: rect.maxY + RegionBorderTuning.borderOutset - handleHeight,
                width: width,
                height: handleHeight
            )
            // The interaction window is the grab: the drawn shape plus a small
            // margin on the free (bottom/right) edges so the handle is easier
            // to catch. The drawing itself stays exactly the shape (the visual
            // border panel draws it via handleShapeFrame).
            setFrame(CGRect(
                x: shapeFrame.minX,
                y: shapeFrame.minY - grabEdgeMargin,
                width: shapeFrame.width + grabEdgeMargin,
                height: shapeFrame.height + grabEdgeMargin
            ), display: true)
        }
        updatePresentation()
    }

    /// The drawn shape in screen coordinates (its outline sits on the
    /// selection's border lines); the window is this shape plus the grab-edge
    /// margin. nil when the handle is unavailable.
    var handleShapeFrame: CGRect? {
        guard isAvailable else { return nil }
        return shapeFrame
    }

    /// Whether the handle is both shown and available.
    var isShown: Bool { externallyVisible && isAvailable }

    func setExternallyVisible(_ visible: Bool) {
        guard externallyVisible != visible else { return }
        externallyVisible = visible
        updatePresentation()
    }

    private func updatePresentation() {
        let interactive = externallyVisible && isAvailable
        ignoresMouseEvents = !interactive
        if interactive {
            orderFrontRegardless()
        } else {
            orderOut(nil)
        }
    }

    private func handle(phase: RegionMoveHandleView.DragPhase, point: CGPoint) {
        switch phase {
        case .began:
            activateForInteraction()
            startRect = logicalSelection
            startPoint = point
            isDragging = true
            onHighlightChange?(true)
        case .changed, .ended:
            guard let startRect, let startPoint else { return }
            onDrag?(startRect, startPoint, point, phase == .ended)
            if phase == .ended {
                self.startRect = nil
                self.startPoint = nil
                isDragging = false
                onHighlightChange?(isHovered)
            }
        }
    }

    private func activateForInteraction() {
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
    }
}

@MainActor
private final class RegionMoveHandleView: NSView {
    enum DragPhase { case began, changed, ended }
    private var cursorTrackingArea: NSTrackingArea?
    var onDrag: ((DragPhase, CGPoint) -> Void)?
    var onHover: ((Bool) -> Void)?

    override func updateTrackingAreas() {
        if let cursorTrackingArea {
            removeTrackingArea(cursorTrackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.cursorUpdate, .mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        cursorTrackingArea = area
        super.updateTrackingAreas()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The whole window is the move grab; the visual border panel draws the
    /// handle bar.
    override func cursorUpdate(with event: NSEvent) {
        NSCursor.openHand.set()
    }

    override func mouseMoved(with event: NSEvent) {
        NSCursor.openHand.set()
        onHover?(true)
    }

    override func mouseEntered(with event: NSEvent) {
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) { onHover?(false) }

    override func mouseDown(with event: NSEvent) {
        NSCursor.closedHand.set()
        onDrag?(.began, NSEvent.mouseLocation)
    }

    override func mouseDragged(with event: NSEvent) {
        NSCursor.closedHand.set()
        onDrag?(.changed, NSEvent.mouseLocation)
    }

    override func mouseUp(with event: NSEvent) {
        onDrag?(.ended, NSEvent.mouseLocation)
        NSCursor.openHand.set()
    }
}

@MainActor
private final class RegionEndButtonPanel: NSPanel {
    private let preferredWidth = RegionBorderTuning.endButtonWidth
    private let trailingClearance: CGFloat = 6
    private let handleHeight: CGFloat = 26
    private let minimumUsableWidth: CGFloat = 26
    /// The click window extends this far beyond the drawn shape on the free
    /// (bottom/left) edges, making the button easier to catch.
    private let grabEdgeMargin: CGFloat = 2
    private var shapeFrame: CGRect = .zero
    private let buttonView = RegionEndButtonView()
    private var externallyVisible = true
    private var isAvailable = false
    private var isHovered = false
    private var isPressed = false
    var onActivate: (() -> Void)?
    /// Hover changes (clears the border's edge hover while over the button).
    var onHover: ((Bool) -> Void)?
    /// Hover or press state for the button's highlight (drawn by the visual
    /// border panel).
    var onHighlightChange: ((Bool) -> Void)?

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        // One level below the edge panels, like the move handle: the border
        // attached to the button must always stay resizable.
        level = RegionWindowLevel.moveHandle
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.fullScreenAuxiliary, .stationary]
        ignoresMouseEvents = true
        acceptsMouseMovedEvents = true
        contentView = buttonView
        buttonView.onClick = { [weak self] in
            self?.activate()
        }
        buttonView.onHover = { [weak self] hovering in
            guard let self else { return }
            self.isHovered = hovering
            self.onHover?(hovering)
            self.onHighlightChange?(hovering || self.isPressed)
        }
        buttonView.onPressChange = { [weak self] pressed in
            guard let self else { return }
            self.isPressed = pressed
            self.onHighlightChange?(pressed || self.isHovered)
        }
    }

    override var canBecomeKey: Bool { true }

    /// The button reads as the right remnant of a titlebar welded to the
    /// selection: its shape's top and right edges sit exactly on the border
    /// lines (selection edge + borderOutset), leaving no gap. The window IS
    /// the click area (the drawn shape), with no shadow padding — the button's
    /// drawing lives in the click-through visual border panel now, so the
    /// interaction window stays inside the resize panels' extent.
    /// `moveHandleWidth` is the move handle's current drawn width (nil when
    /// the handle is unavailable); the button stays available only when it
    /// fits next to the handle along the top edge.
    func setSelection(_ rect: CGRect, moveHandleWidth: CGFloat?) {
        let availableWidth = max(0, rect.width - trailingClearance)
        let width = min(preferredWidth, availableWidth)
        let handleWidth = moveHandleWidth ?? 0
        isAvailable = width >= minimumUsableWidth
            && handleWidth + width + trailingClearance <= rect.width
        if isAvailable {
            shapeFrame = CGRect(
                x: rect.maxX + RegionBorderTuning.borderOutset - width,
                y: rect.maxY + RegionBorderTuning.borderOutset - handleHeight,
                width: width,
                height: handleHeight
            )
            // The interaction window is the click target: the drawn shape
            // plus a small margin on the free (bottom/left) edges so the
            // button is easier to catch. The drawing itself stays exactly the
            // shape (the visual border panel draws it via endButtonShapeFrame).
            setFrame(CGRect(
                x: shapeFrame.minX - grabEdgeMargin,
                y: shapeFrame.minY - grabEdgeMargin,
                width: shapeFrame.width + grabEdgeMargin,
                height: shapeFrame.height + grabEdgeMargin
            ), display: true)
        }
        updatePresentation()
    }

    /// The drawn shape in screen coordinates (its outline sits on the
    /// selection's border lines); the window is this shape plus the grab-edge
    /// margin. nil when the button is unavailable.
    var endButtonShapeFrame: CGRect? {
        guard isAvailable else { return nil }
        return shapeFrame
    }

    /// Whether the button is both shown and available.
    var isShown: Bool { externallyVisible && isAvailable }

    func setExternallyVisible(_ visible: Bool) {
        guard externallyVisible != visible else { return }
        externallyVisible = visible
        updatePresentation()
    }

    private func updatePresentation() {
        let interactive = externallyVisible && isAvailable
        ignoresMouseEvents = !interactive
        if interactive {
            orderFrontRegardless()
        } else {
            orderOut(nil)
        }
    }

    private func activate() {
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
        onActivate?()
    }
}

@MainActor
private final class RegionEndButtonView: NSView {
    private var cursorTrackingArea: NSTrackingArea?
    private var isPressed = false
    var onClick: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    var onPressChange: ((Bool) -> Void)?

    override func updateTrackingAreas() {
        if let cursorTrackingArea {
            removeTrackingArea(cursorTrackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.cursorUpdate, .mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        cursorTrackingArea = area
        super.updateTrackingAreas()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The whole window is the click target; the visual border panel draws
    /// the button bar and its X mark.
    override func cursorUpdate(with event: NSEvent) {
        NSCursor.pointingHand.set()
    }

    override func mouseMoved(with event: NSEvent) {
        NSCursor.pointingHand.set()
        onHover?(true)
    }

    override func mouseEntered(with event: NSEvent) {
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        isPressed = false
        onPressChange?(false)
        onHover?(false)
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        onPressChange?(true)
    }

    override func mouseUp(with event: NSEvent) {
        let clickedInside = isPressed && bounds.contains(
            convert(event.locationInWindow, from: nil)
        )
        isPressed = false
        onPressChange?(false)
        if clickedInside { onClick?() }
    }
}


@MainActor
private final class RegionEdgePanel: NSPanel {
    let edge: RegionBorderController.Edge
    var onDrag: ((RegionBorderController.Edge, CGRect, CGPoint, CGPoint, Bool) -> Void)?
    var onHover: ((RegionBorderController.Edge?) -> Void)?
    var logicalSelection: CGRect = .zero
    /// The combined outline (selection ∪ docked control bar) in the view's
    /// own coordinates; drives the corner detection in the edge view. The
    /// offset is applied against the current frame, so set it after laying
    /// out the panel frame.
    var logicalOutline: CGRect = .zero {
        didSet {
            edgeView.logicalOutline = logicalOutline.offsetBy(
                dx: -frame.minX, dy: -frame.minY
            )
        }
    }
    private let edgeView: RegionEdgeView
    private var externallyVisible = true

    init(edge: RegionBorderController.Edge) {
        self.edge = edge
        edgeView = RegionEdgeView(edge: edge)
        super.init(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        level = RegionWindowLevel.interaction
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.fullScreenAuxiliary, .stationary]
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        contentView = edgeView
        edgeView.onDrag = { [weak self] phase, point in
            self?.handle(phase: phase, point: point)
        }
        edgeView.onHover = { [weak self] edge in self?.onHover?(edge) }
    }

    override var canBecomeKey: Bool { true }

    func rebuildCursorRects() {
        invalidateCursorRects(for: edgeView)
    }

    func setExternallyVisible(_ visible: Bool) {
        guard externallyVisible != visible else { return }
        externallyVisible = visible
        ignoresMouseEvents = !visible
        if visible { orderFrontRegardless() } else { orderOut(nil) }
    }

    private var startRect: CGRect?
    private var startPoint: CGPoint?
    private var activeEdge: RegionBorderController.Edge?

    private func handle(phase: RegionEdgeView.DragPhase, point: CGPoint) {
        switch phase {
        case .began:
            activateForInteraction()
            startRect = logicalSelection
            startPoint = point
            activeEdge = edgeView.resolvedEdge
        case .changed, .ended:
            guard let startRect, let startPoint else { return }
            onDrag?(activeEdge ?? edge, startRect, startPoint, point, phase == .ended)
            if phase == .ended {
                self.startRect = nil
                self.startPoint = nil
                activeEdge = nil
            }
        }
    }

    private func activateForInteraction() {
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
    }
}

@MainActor
private final class RegionEdgeView: NSView {
    enum DragPhase { case began, changed, ended }
    let edge: RegionBorderController.Edge
    var onDrag: ((DragPhase, CGPoint) -> Void)?
    var onHover: ((RegionBorderController.Edge?) -> Void)?
    var resolvedEdge: RegionBorderController.Edge = .top
    /// The combined outline (selection ∪ docked control bar) in this view's
    /// own coordinates; the corner detection is anchored to its corners, not
    /// the panel frame, because the frame extends past the outline.
    var logicalOutline: CGRect = .zero
    private var cursorTrackingArea: NSTrackingArea?

    init(edge: RegionBorderController.Edge) {
        self.edge = edge
        resolvedEdge = edge
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { nil }

    override func updateTrackingAreas() {
        if let cursorTrackingArea {
            removeTrackingArea(cursorTrackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.cursorUpdate, .mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        cursorTrackingArea = area
        super.updateTrackingAreas()
    }

    override func cursorUpdate(with event: NSEvent) {
        desiredCursor(at: convert(event.locationInWindow, from: nil)).set()
    }

    override func mouseMoved(with event: NSEvent) {
        desiredCursor(at: convert(event.locationInWindow, from: nil)).set()
        onHover?(resolvedEdge(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseEntered(with event: NSEvent) {
        onHover?(resolvedEdge(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseExited(with event: NSEvent) {
        onHover?(nil)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        updateResolvedEdge(event.locationInWindow)
        onDrag?(.began, NSEvent.mouseLocation)
    }
    override func mouseDragged(with event: NSEvent) {
        onDrag?(.changed, NSEvent.mouseLocation)
    }
    override func mouseUp(with event: NSEvent) {
        onDrag?(.ended, NSEvent.mouseLocation)
        desiredCursor(at: convert(event.locationInWindow, from: nil)).set()
    }

    private func updateResolvedEdge(_ point: CGPoint) {
        resolvedEdge = resolvedEdge(at: point)
    }

    private func desiredCursor(at point: CGPoint) -> NSCursor {
        return cursor(for: resolvedEdge(at: point))
    }

    /// Resolves the resize zone for a point in view coordinates. Corners are
    /// measured from the outline's corners (in-band reach unchanged at 18pt,
    /// capped at a third of the outline so corner zones never meet on small
    /// selections); the panel's extension past the outline is thereby always
    /// part of the adjacent corner zone. `logicalOutline` is in this view's
    /// own coordinates (offset by the frame origin), so the comparisons use
    /// its min/max edges — never its width/height — to keep every corner zone
    /// symmetric at the intended reach.
    fileprivate func resolvedEdge(at point: CGPoint) -> RegionBorderController.Edge {
        switch edge {
        case .top, .bottom:
            let cornerReach = min(18, logicalOutline.width / 3)
            if point.x <= logicalOutline.minX + cornerReach {
                return edge == .top ? .topLeft : .bottomLeft
            }
            if point.x >= logicalOutline.maxX - cornerReach {
                return edge == .top ? .topRight : .bottomRight
            }
            return edge
        case .left, .right:
            let cornerReach = min(18, logicalOutline.height / 3)
            if point.y <= logicalOutline.minY + cornerReach {
                return edge == .left ? .bottomLeft : .bottomRight
            }
            if point.y >= logicalOutline.maxY - cornerReach {
                return edge == .left ? .topLeft : .topRight
            }
            return edge
        case .topLeft, .topRight, .bottomLeft, .bottomRight:
            return edge
        }
    }

    private func cursor(for edge: RegionBorderController.Edge) -> NSCursor {
        switch edge {
        case .top: NSCursor.frameResize(position: .top, directions: .all)
        case .bottom: NSCursor.frameResize(position: .bottom, directions: .all)
        case .left: NSCursor.frameResize(position: .left, directions: .all)
        case .right: NSCursor.frameResize(position: .right, directions: .all)
        case .topLeft: NSCursor.frameResize(position: .topLeft, directions: .all)
        case .topRight: NSCursor.frameResize(position: .topRight, directions: .all)
        case .bottomLeft: NSCursor.frameResize(position: .bottomLeft, directions: .all)
        case .bottomRight: NSCursor.frameResize(position: .bottomRight, directions: .all)
        }
    }

}

@MainActor
func regionPanelContractViolationsForSelfTest() -> [String] {
    let visualPanel = RegionVisualBorderPanel()
    let movePanel = RegionMoveHandlePanel()
    let endPanel = RegionEndButtonPanel()
    let edgePanel = RegionEdgePanel(edge: .top)
    defer {
        visualPanel.close()
        movePanel.close()
        endPanel.close()
        edgePanel.close()
    }
    var violations: [String] = []
    if visualPanel.hidesOnDeactivate {
        violations.append("visual region border must remain visible while the app is inactive")
    }
    if !visualPanel.styleMask.contains(.nonactivatingPanel) {
        violations.append("visual region border must remain click-through while inactive")
    }
    if movePanel.styleMask.contains(.nonactivatingPanel) || !movePanel.canBecomeKey {
        violations.append("region move panel must become key for mouse interaction")
    }
    if endPanel.styleMask.contains(.nonactivatingPanel) || !endPanel.canBecomeKey {
        violations.append("region end button panel must become key for mouse interaction")
    }
    if endPanel.contentView?.acceptsFirstMouse(for: nil) != true {
        violations.append("region end button must accept the first mouse-down")
    }
    if edgePanel.hidesOnDeactivate {
        violations.append("region edge panel must remain available while the app is inactive")
    }
    if edgePanel.styleMask.contains(.nonactivatingPanel) {
        violations.append("region edge panel must activate the app when interaction begins")
    }
    if !edgePanel.canBecomeKey {
        violations.append("region edge panel must become key for mouse interaction")
    }
    if edgePanel.contentView?.acceptsFirstMouse(for: nil) != true {
        violations.append("region edge panel must accept the first mouse-down")
    }
    if edgePanel.ignoresMouseEvents {
        violations.append("region edge panel must always receive resize gestures")
    }
    if let screen = NSScreen.main ?? NSScreen.screens.first {
        let controller = RegionBorderController(
            selection: CGRect(
                x: screen.frame.midX - 200, y: screen.frame.midY - 100,
                width: 400, height: 200
            ),
            screen: screen,
            opacity: RegionBorderOpacity.defaultValue
        )
        violations.append(
            contentsOf: controller.interactionWindowOwnershipViolationsForSelfTest()
        )
        violations.append(
            contentsOf: controller.moveHandleGeometryViolationsForSelfTest()
        )
        violations.append(
            contentsOf: controller.moveHandleInteractionViolationsForSelfTest()
        )
        violations.append(
            contentsOf: controller.endButtonGeometryViolationsForSelfTest()
        )
        violations.append(
            contentsOf: controller.endButtonInteractionViolationsForSelfTest()
        )
        violations.append(
            contentsOf: controller.borderHitZoneViolationsForSelfTest()
        )
        controller.close()
    }
    return violations
}
