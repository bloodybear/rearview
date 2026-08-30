import AppKit

enum MirrorDockingState: String, CaseIterable, Sendable {
    case undocked, top, bottom, left, right

    static let defaultsKey = "mirror.dockingState"
    static let undockedFrameKey = "mirror.lastUndockedFrame"
    static let snapDistance: CGFloat = 68
    /// Maximum length of the shorter edge that may remain uncovered along
    /// the docking edge while a drag is still considered a candidate.
    static let tangentialDockingTolerance: CGFloat = 68
    static let minimumScale: CGFloat = 0.5
    /// Thickness of the docking seam band; it is centered on the visual
    /// midpoint between the border's outer edge and the docked window edge.
    static let seamThickness: CGFloat = 10
    /// The seam spans only this fraction of the shared edge, centered, so it
    /// reads as a compact connection indicator rather than a full-length bar.
    static let seamLengthFraction: CGFloat = 0.8
    /// Where the seam's center sits between the border's outer edge (0) and
    /// the window edge (1). 0.5 centers it in the gap; values above 0.5 hug
    /// the window side, values below move it toward the border.
    static let seamPosition: CGFloat = 0.4
    /// Small breathing space between the border line and the docked window
    /// edge; the docking seam spans the gap to connect the two.
    static let dockedGap: CGFloat = 5
    /// When a drag-docked window's position along the edge is within this
    /// distance of a content-based alignment, it snaps magnetically to that
    /// alignment.
    static let magneticSnapDistance: CGFloat = 68

    static func load(from defaults: UserDefaults = .standard) -> Self {
        Self(rawValue: defaults.string(forKey: defaultsKey) ?? "") ?? .undocked
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }

    var shortcutAction: ToolbarShortcutAction? {
        switch self {
        case .undocked: nil
        case .top: .dockTop
        case .bottom: .dockBottom
        case .left: .dockLeft
        case .right: .dockRight
        }
    }

    /// The single-key selection-screen shortcut for this docking direction.
    var selectionShortcutAction: SelectionShortcutAction? {
        switch self {
        case .undocked: nil
        case .top: .dockTop
        case .bottom: .dockBottom
        case .left: .dockLeft
        case .right: .dockRight
        }
    }

    var symbolName: String {
        switch self {
        case .undocked: "inset.filled.center.rectangle"
        case .top: "rectangle.tophalf.inset.filled"
        case .bottom: "rectangle.bottomhalf.inset.filled"
        case .left: "rectangle.lefthalf.inset.filled"
        case .right: "rectangle.righthalf.inset.filled"
        }
    }

    var title: String {
        switch self {
        case .undocked: L10n.text("미도킹")
        case .top: L10n.text("위쪽에 도킹")
        case .bottom: L10n.text("아래쪽에 도킹")
        case .left: L10n.text("왼쪽에 도킹")
        case .right: L10n.text("오른쪽에 도킹")
        }
    }

    func toggled(with requested: MirrorDockingState) -> MirrorDockingState {
        self == requested ? .undocked : requested
    }

    static func loadUndockedFrame(from defaults: UserDefaults = .standard) -> CGRect? {
        guard let string = defaults.string(forKey: undockedFrameKey) else { return nil }
        let rect = NSRectFromString(string)
        return rect.width > 0 && rect.height > 0 ? rect : nil
    }

    static func saveUndockedFrame(_ frame: CGRect, to defaults: UserDefaults = .standard) {
        guard frame.width > 0, frame.height > 0 else { return }
        defaults.set(NSStringFromRect(frame), forKey: undockedFrameKey)
    }
}

enum MirrorDockPreviewInteraction {
    case move
    case resize(placementMatchesCurrentFrame: Bool)
}

enum MirrorDockPreviewPresentation: Equatable {
    case seamOnly
    case seamAndGhost
}

func mirrorDockPreviewPresentation(
    for interaction: MirrorDockPreviewInteraction
) -> MirrorDockPreviewPresentation {
    switch interaction {
    case .move:
        // Movement previews communicate the docking target even when the
        // target currently overlaps the mirror window.
        .seamAndGhost
    case .resize(let placementMatchesCurrentFrame):
        placementMatchesCurrentFrame ? .seamOnly : .seamAndGhost
    }
}

struct MirrorDockingPlacement: Equatable {
    let frame: CGRect
    let scale: CGFloat
}

func mirrorUndockedFrame(
    savedFrame: CGRect?, defaultFrame: CGRect, visibleFrames: [CGRect]
) -> CGRect {
    var result = savedFrame ?? defaultFrame
    guard !visibleFrames.isEmpty else { return result }
    if let containing = visibleFrames.first(where: { $0.intersects(result) })
        ?? visibleFrames.min(by: {
            hypot($0.midX - result.midX, $0.midY - result.midY)
                < hypot($1.midX - result.midX, $1.midY - result.midY)
        }) {
        result.size.width = min(result.width, containing.width)
        result.size.height = min(result.height, containing.height)
        result.origin.x = min(max(result.minX, containing.minX), containing.maxX - result.width)
        result.origin.y = min(max(result.minY, containing.minY), containing.maxY - result.height)
    }
    return result
}

private func rectIsCovered(_ rect: CGRect, by visibleFrames: [CGRect]) -> Bool {
    guard rect.width > 0, rect.height > 0 else { return false }
    var pending = [rect]
    for visible in visibleFrames where visible.intersects(rect) {
        var next: [CGRect] = []
        for piece in pending {
            let intersection = piece.intersection(visible)
            guard !intersection.isNull, !intersection.isEmpty else {
                next.append(piece); continue
            }
            if intersection.minY > piece.minY {
                next.append(CGRect(x: piece.minX, y: piece.minY,
                                   width: piece.width, height: intersection.minY - piece.minY))
            }
            if intersection.maxY < piece.maxY {
                next.append(CGRect(x: piece.minX, y: intersection.maxY,
                                   width: piece.width, height: piece.maxY - intersection.maxY))
            }
            if intersection.minX > piece.minX {
                next.append(CGRect(x: piece.minX, y: intersection.minY,
                                   width: intersection.minX - piece.minX, height: intersection.height))
            }
            if intersection.maxX < piece.maxX {
                next.append(CGRect(x: intersection.maxX, y: intersection.minY,
                                   width: piece.maxX - intersection.maxX, height: intersection.height))
            }
        }
        pending = next.filter { $0.width > 0.01 && $0.height > 0.01 }
        if pending.isEmpty { return true }
    }
    return pending.isEmpty
}

/// The along-edge alignment of a docked window. For side docking, the
/// titlebar is excluded while any bottom chrome remains part of the docking
/// edge; top/bottom docking uses the whole frame edge.
enum MirrorDockAlignment: CaseIterable, Equatable {
    /// Content start edge matches the selection start edge: content top for
    /// side docking, content left for top/bottom docking.
    case start
    case center
    /// Content end edge matches the selection end edge: content bottom for
    /// side docking, content right for top/bottom docking.
    case end

    /// The fixed alignment used by shortcut/menu docking (the basic docked
    /// alignment): every direction uses the middle snap point.
    static func shortcutDefault(for state: MirrorDockingState) -> MirrorDockAlignment {
        switch state {
        case .top, .bottom, .left, .right, .undocked: .center
        }
    }
}

/// The along-edge position of a docked mirror. Alignment anchors preserve the
/// semantic start/center/end snap, while relative anchors preserve a freely
/// chosen position as a fraction of the selection's along-edge length.
enum MirrorDockingAnchor: Equatable {
    case alignment(MirrorDockAlignment)
    case relative(CGFloat)
}

/// Returns the mirror edge that participates in docking. For side docking,
/// the titlebar is excluded, while any bottom chrome remains part of the
/// docked edge as required by the product geometry.
func mirrorDockingMirrorEdgeRect(
    frame: CGRect, state: MirrorDockingState,
    chromeHeight: CGFloat, bottomChromeHeight: CGFloat = 0
) -> CGRect {
    guard state != .undocked, frame.width > 0, frame.height > 0 else { return .zero }
    switch state {
    case .top, .bottom:
        return frame
    case .left, .right:
        let dockedEdgeHeight = max(0, frame.height - chromeHeight)
        return CGRect(
            x: frame.minX, y: frame.minY,
            width: frame.width, height: dockedEdgeHeight
        )
    case .undocked:
        return .zero
    }
}

private func clampedHorizontalDockRatio(
    selectionLength: CGFloat, mirrorLength: CGFloat, ratio: CGFloat
) -> CGFloat {
    guard selectionLength > 0 else { return 0 }
    let bound = (selectionLength - mirrorLength) / selectionLength
    let lower = min(0, bound)
    let upper = max(0, bound)
    return min(max(ratio, lower), upper)
}

private func clampedVerticalDockRatio(
    selection: CGRect, contentHeight: CGFloat, ratio: CGFloat
) -> CGFloat {
    guard selection.height > 0 else { return 0 }
    let lowerTarget: CGFloat
    let upperTarget: CGFloat
    if contentHeight <= selection.height {
        lowerTarget = selection.minY + contentHeight
        upperTarget = selection.maxY
    } else {
        lowerTarget = selection.maxY
        upperTarget = selection.minY + contentHeight
    }
    let lower = (lowerTarget - selection.minY) / selection.height
    let upper = (upperTarget - selection.minY) / selection.height
    return min(max(ratio, min(lower, upper)), max(lower, upper))
}

/// Returns the anchor represented by a docked frame at the current selection.
/// For side docking the anchor tracks the content area's top edge; for
/// top/bottom docking it tracks the content area's left edge.
func mirrorDockingAnchor(
    frame: CGRect, selection: CGRect, state: MirrorDockingState,
    chromeHeight: CGFloat, bottomChromeHeight: CGFloat = 0
) -> MirrorDockingAnchor {
    switch state {
    case .top, .bottom:
        guard selection.width > 0 else { return .relative(0) }
        return .relative((frame.minX - selection.minX) / selection.width)
    case .left, .right:
        guard selection.height > 0 else { return .relative(0) }
        let mirrorEdge = mirrorDockingMirrorEdgeRect(
            frame: frame, state: state,
            chromeHeight: chromeHeight, bottomChromeHeight: bottomChromeHeight
        )
        let contentTop = mirrorEdge.maxY
        return .relative((contentTop - selection.minY) / selection.height)
    case .undocked:
        return .relative(0)
    }
}

func mirrorDockedFrame(
    selection: CGRect, windowSize: CGSize, state: MirrorDockingState,
    visibleFrames: [CGRect], chromeHeight: CGFloat,
    borderOutset: CGFloat, alignment: MirrorDockAlignment,
    anchor: MirrorDockingAnchor? = nil,
    bottomChromeHeight: CGFloat = 0,
    minimumScale: CGFloat = MirrorDockingState.minimumScale
) -> MirrorDockingPlacement? {
    guard state != .undocked, windowSize.width > 0, windowSize.height > 0 else { return nil }
    // The window meets the border line (selection edge + the border's
    // outset) with a small gap beyond it, so it never tucks under the
    // border ring; the docking seam bridges the gap.
    let offset = borderOutset + MirrorDockingState.dockedGap
    func alignedX(width: CGFloat) -> CGFloat {
        switch anchor ?? .alignment(alignment) {
        case .alignment(let alignment):
            switch alignment {
            case .start: return selection.minX
            case .center: return selection.midX - width / 2
            case .end: return selection.maxX - width
            }
        case .relative(let ratio):
            let clampedRatio = clampedHorizontalDockRatio(
                selectionLength: selection.width, mirrorLength: width, ratio: ratio
            )
            return selection.minX + selection.width * clampedRatio
        }
    }
    func alignedY(height: CGFloat) -> CGFloat {
        // Side docking excludes only the top titlebar. Any bottom chrome is
        // part of the mirror docking edge and therefore remains in the
        // along-edge alignment length.
        let contentHeight = max(0, height - chromeHeight)
        switch anchor ?? .alignment(alignment) {
        case .alignment(let alignment):
            switch alignment {
            case .start:
                return selection.maxY + chromeHeight - height
            case .center:
                return selection.midY - contentHeight / 2
            case .end:
                return selection.minY
            }
        case .relative(let ratio):
            let clampedRatio = clampedVerticalDockRatio(
                selection: selection, contentHeight: contentHeight, ratio: ratio
            )
            return selection.minY + selection.height * clampedRatio
                - contentHeight
        }
    }
    func centeredCandidate(scale: CGFloat) -> CGRect {
        let size = CGSize(width: windowSize.width * scale, height: windowSize.height * scale)
        switch state {
        case .top:
            return CGRect(x: alignedX(width: size.width),
                          y: selection.maxY + offset,
                          width: size.width, height: size.height)
        case .bottom:
            return CGRect(x: alignedX(width: size.width),
                          y: selection.minY - offset - size.height,
                          width: size.width, height: size.height)
        case .left:
            return CGRect(x: selection.minX - offset - size.width,
                          y: alignedY(height: size.height),
                          width: size.width, height: size.height)
        case .right:
            return CGRect(x: selection.maxX + offset,
                          y: alignedY(height: size.height),
                          width: size.width, height: size.height)
        case .undocked: return .zero
        }
    }

    let frames = visibleFrames.filter { !$0.isEmpty && !$0.isNull }
    guard !frames.isEmpty else { return nil }
    func coveredCandidate(scale: CGFloat) -> CGRect? {
        let centered = centeredCandidate(scale: scale)
        var candidates = [centered]
        for visible in frames {
            var adjusted = centered
            switch state {
            case .top, .bottom:
                guard adjusted.width <= visible.width else { continue }
                adjusted.origin.x = min(
                    max(adjusted.minX, visible.minX), visible.maxX - adjusted.width
                )
            case .left, .right:
                guard adjusted.height <= visible.height else { continue }
                adjusted.origin.y = min(
                    max(adjusted.minY, visible.minY), visible.maxY - adjusted.height
                )
            case .undocked: break
            }
            candidates.append(adjusted)
        }
        return candidates.filter {
            rectIsCovered($0, by: frames)
                && mirrorDockingAlongEdgeIsCovered(
                    selection: selection, frame: $0, state: state,
                    chromeHeight: chromeHeight, bottomChromeHeight: bottomChromeHeight
                )
        }.min {
            hypot($0.midX - centered.midX, $0.midY - centered.midY)
                < hypot($1.midX - centered.midX, $1.midY - centered.midY)
        }
    }
    if let frame = coveredCandidate(scale: 1) {
        return MirrorDockingPlacement(frame: frame, scale: 1)
    }
    var low = minimumScale
    var high: CGFloat = 1
    guard coveredCandidate(scale: low) != nil else { return nil }
    for _ in 0..<14 {
        let middle = (low + high) / 2
        if coveredCandidate(scale: middle) != nil { low = middle }
        else { high = middle }
    }
    guard let frame = coveredCandidate(scale: low) else { return nil }
    return MirrorDockingPlacement(frame: frame, scale: low)
}

/// Checks whether releasing at the current frame would dock the window
/// against a selection edge. Unlike shortcut docking, a drag-docked window
/// may attach at any position along the edge: it only requires the window's
/// edge to sit within `snapDistance` of the selection edge and the overlap
/// to cover the full length of the shorter of the two touching edges.
func mirrorFreeDockCandidate(
    windowFrame: CGRect, selection: CGRect,
    snapDistance: CGFloat = MirrorDockingState.snapDistance,
    tangentialTolerance: CGFloat = MirrorDockingState.tangentialDockingTolerance,
    chromeHeight: CGFloat = 0, bottomChromeHeight: CGFloat = 0
) -> MirrorDockingState? {
    struct Candidate {
        let state: MirrorDockingState
        let normal: CGFloat
        let contact: CGFloat
        let requiredContact: CGFloat
        let priority: Int
    }
    let mirrorEdge = mirrorDockingMirrorEdgeRect(
        frame: windowFrame, state: .right,
        chromeHeight: chromeHeight, bottomChromeHeight: bottomChromeHeight
    )
    let verticalOverlap = max(0, min(mirrorEdge.maxY, selection.maxY) - max(mirrorEdge.minY, selection.minY))
    let horizontalOverlap = max(0, min(windowFrame.maxX, selection.maxX) - max(windowFrame.minX, selection.minX))
    // The shorter of the touching edges must be fully covered by the overlap.
    let verticalFullCover = min(mirrorEdge.height, selection.height)
    let horizontalFullCover = min(windowFrame.width, selection.width)
    let candidates = [
        // The order is part of the product contract. Keep the explicit
        // priority as well as the array order so an equal-distance result
        // cannot depend on collection implementation details.
        Candidate(state: .top, normal: abs(windowFrame.minY - selection.maxY),
                  contact: horizontalOverlap, requiredContact: horizontalFullCover, priority: 0),
        Candidate(state: .bottom, normal: abs(windowFrame.maxY - selection.minY),
                  contact: horizontalOverlap, requiredContact: horizontalFullCover, priority: 1),
        Candidate(state: .left, normal: abs(windowFrame.maxX - selection.minX),
                  contact: verticalOverlap, requiredContact: verticalFullCover, priority: 2),
        Candidate(state: .right, normal: abs(windowFrame.minX - selection.maxX),
                  contact: verticalOverlap, requiredContact: verticalFullCover, priority: 3)
    ]
    return candidates
        .filter {
            $0.normal <= snapDistance
                && $0.contact + max(0, tangentialTolerance) >= $0.requiredContact
        }
        .min {
            if $0.normal != $1.normal { return $0.normal < $1.normal }
            return $0.priority < $1.priority
        }?.state
}

/// Returns whether a frame still satisfies the same geometric docking rule
/// used when an undocked window is attached by dragging. The direction must
/// also remain the same; a frame that satisfies another edge is a candidate
/// for that other direction instead.
func mirrorDockingCandidateMatches(
    windowFrame: CGRect, selection: CGRect, state: MirrorDockingState,
    snapDistance: CGFloat = MirrorDockingState.snapDistance,
    tangentialTolerance: CGFloat = MirrorDockingState.tangentialDockingTolerance,
    chromeHeight: CGFloat = 0, bottomChromeHeight: CGFloat = 0
) -> Bool {
    guard state != .undocked else { return false }
    return mirrorFreeDockCandidate(
        windowFrame: windowFrame, selection: selection, snapDistance: snapDistance,
        tangentialTolerance: tangentialTolerance,
        chromeHeight: chromeHeight, bottomChromeHeight: bottomChromeHeight
    ) == state
}

func mirrorDockingAlongEdgeIsCovered(
    selection: CGRect, frame: CGRect, state: MirrorDockingState,
    chromeHeight: CGFloat, bottomChromeHeight: CGFloat = 0
) -> Bool {
    let mirrorEdge = mirrorDockingMirrorEdgeRect(
        frame: frame, state: state,
        chromeHeight: chromeHeight, bottomChromeHeight: bottomChromeHeight
    )
    guard !mirrorEdge.isEmpty else { return false }
    let overlap: CGFloat
    let required: CGFloat
    switch state {
    case .top, .bottom:
        overlap = max(0, min(mirrorEdge.maxX, selection.maxX) - max(mirrorEdge.minX, selection.minX))
        required = min(mirrorEdge.width, selection.width)
    case .left, .right:
        overlap = max(0, min(mirrorEdge.maxY, selection.maxY) - max(mirrorEdge.minY, selection.minY))
        required = min(mirrorEdge.height, selection.height)
    case .undocked:
        return false
    }
    return overlap >= required
}

/// The glowing band bridging the selection border and a docked mirror
/// placement. Shared by the persistent docking seam and the drag-time dock
/// preview so both read as the same connection. The band's center sits at
/// `seamPosition` between the border's outer edge (border line +
/// `borderShadowReach`) and the window edge, and spans only a centered
/// fraction of the shared edge.
func mirrorDockingSeamRect(
    placement: CGRect, state: MirrorDockingState, selection: CGRect,
    borderOutset: CGFloat, borderShadowReach: CGFloat,
    chromeHeight: CGFloat = 0, bottomChromeHeight: CGFloat = 0
) -> CGRect? {
    guard state != .undocked, placement.width > 0, placement.height > 0 else { return nil }
    let thickness = MirrorDockingState.seamThickness
    let lengthFraction = MirrorDockingState.seamLengthFraction
    let position = MirrorDockingState.seamPosition
    switch state {
    case .top, .bottom:
        let minX = max(placement.minX, selection.minX)
        let maxX = min(placement.maxX, selection.maxX)
        guard maxX > minX else { return nil }
        let length = (maxX - minX) * lengthFraction
        let centerX = (minX + maxX) / 2
        let borderLine = state == .top
            ? selection.maxY + borderOutset
            : selection.minY - borderOutset
        let borderVisualOuter = state == .top
            ? borderLine + borderShadowReach
            : borderLine - borderShadowReach
        let windowEdge = state == .top ? placement.minY : placement.maxY
        let midY = borderVisualOuter + (windowEdge - borderVisualOuter) * position
        return CGRect(x: centerX - length / 2, y: midY - thickness / 2,
                      width: length, height: thickness)
    case .left, .right:
        let mirrorEdge = mirrorDockingMirrorEdgeRect(
            frame: placement, state: state,
            chromeHeight: chromeHeight, bottomChromeHeight: bottomChromeHeight
        )
        let minY = max(mirrorEdge.minY, selection.minY)
        let maxY = min(mirrorEdge.maxY, selection.maxY)
        guard maxY > minY else { return nil }
        let length = (maxY - minY) * lengthFraction
        let centerY = (minY + maxY) / 2
        let borderLine = state == .right
            ? selection.maxX + borderOutset
            : selection.minX - borderOutset
        let borderVisualOuter = state == .right
            ? borderLine + borderShadowReach
            : borderLine - borderShadowReach
        let windowEdge = state == .right ? placement.minX : placement.maxX
        let midX = borderVisualOuter + (windowEdge - borderVisualOuter) * position
        return CGRect(x: midX - thickness / 2, y: centerY - length / 2,
                      width: thickness, height: length)
    case .undocked: return nil
    }
}
