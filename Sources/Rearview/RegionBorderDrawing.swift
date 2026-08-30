import AppKit

/// Shared visual constants for the region border effect stack. Both the
/// persistent region border and the selection-time border draw with the same
/// tuning so the two phases read as one design language. `effectInset` and
/// the hover values apply only to the persistent border panel; the selection
/// overlay lives on a full-screen panel with no clipping inset.
@MainActor
enum RegionBorderTuning {
    static let cornerRadius: CGFloat = 10
    static let borderLineWidth: CGFloat = 1
    static let borderShadowLayers: [(width: CGFloat, alpha: CGFloat)] = [
        (4.5, 0.08), (2.5, 0.22), (2.0, 0.78)
    ]
    static let innerGlowBlur: CGFloat = 14
    static let innerGlowAlpha: CGFloat = 0.8

    // Persistent border panel geometry.
    static let effectInset: CGFloat = 8
    static let borderOutset: CGFloat = 1.5
    static let joinedEdgeExtension: CGFloat = 0.5
    static let hoverHighlightEnabled = true
    static let hoverSegmentLength: CGFloat = 12
    static let hoverLineWidth: CGFloat = 2.0
    static let hoverWhiteBlend: CGFloat = 0.2
    static let hoverAlphaBoost: CGFloat = 0.3

    // Selection overlay.
    static let dimMaxAlpha: CGFloat = 0.30
    static let ghostShadowLayers: [(width: CGFloat, alpha: CGFloat)] = [
        (4.5, 0.04), (2.5, 0.10), (2.0, 0.28)
    ]
    /// How far the border's outer shadow extends beyond the border line; the
    /// docking seam uses it to center on the border's visual outer edge.
    static let borderShadowReach: CGFloat =
        (borderShadowLayers.map(\.width).max() ?? 0) / 2
    // The seam band geometry (thickness and length) lives in
    // MirrorDockingState so the pure geometry helper can use it.
    static let seamBandAlpha: CGFloat = 0.40
    static let seamLineAlpha: CGFloat = 1.0

    // Drag-time dock preview and selection-screen output preview: a solid
    // monochrome target in the region border color instead of a miniature
    // window copy, so it stays clearly distinguishable from the real mirror
    // window. The outline and the titlebar divider share the same line color
    // and alpha.
    static let dockPreviewBodyAlpha: CGFloat = 0.25
    static let dockPreviewLineAlpha: CGFloat = 0.75

    // Move handle (mirror mode): the outline uses the border's effect stack
    // and opacity so it reads as one body with the selection border. The
    // interior stays completely empty at idle — the inner glow keeps it from
    // looking dead — and gains a soft tint on hover/drag to signal the grab.
    // The grip dots stay visible at all times (idle in the border color,
    // brightened like the hover highlight while hovering or dragging).
    static let moveHandleIdleFillAlpha: CGFloat = 0
    // Soft interior tint on hover/drag, deliberately not a solid fill.
    static let moveHandleHoverFillAlpha: CGFloat = 0.35
    // Transparent window padding that carries the handle's outer shadow and
    // its inner-glow source band. Matches the border's glow source band
    // width (effectInset - borderOutset) so the right/bottom edges render
    // exactly like the selection border.
    static let moveHandleShadowPadding: CGFloat = effectInset - borderOutset

    // End-translation button (mirror mode): a shorter sibling of the move
    // handle, welded to the selection's top-right corner and drawn with the
    // same effect stack. 34pt keeps the bar reading (wider than the 26pt bar
    // height) while slimming it below the move handle's 80pt. The X mark is
    // always visible, in the border color at the border's opacity, and
    // brightens with the interior tint while hovering or pressing.
    static let endButtonWidth: CGFloat = 34
    // Half-length of each X stroke from the button's center.
    static let endButtonMarkArm: CGFloat = 4.5
    static let endButtonMarkLineWidth: CGFloat = 1.5

    // The border's hit band: `inwardHitWidth` inside and `outwardHitWidth`
    // outside the selection edge. The visible border line sits `borderOutset`
    // outside the edge, so the widths below are the line-relative values to
    // tune (2pt inside / 5pt outside the visible line by default), converted
    // to selection-edge offsets. The move handle's resize strips mirror this
    // band exactly, so the border attached to the handle stays resizable.
    static let inwardHitWidth: CGFloat = 2 - borderOutset    // 0.5
    static let outwardHitWidth: CGFloat = 5 + borderOutset   // 6.5
    // How far the handle's move grab recedes from its top/left edges so the
    // border's resize strip keeps priority where they overlap. The grab
    // starts exactly at the band's inner edge — no overlap, no dead strip on
    // the handle bar.
    static let moveHandleResizeClearance: CGFloat = borderOutset + inwardHitWidth
}

/// Shared drawing primitives used by both the persistent region border and
/// the selection-time overlay, so the effect stack (layered exterior shadow,
/// inverse-fill inner glow, docking seam) exists in exactly one place.
@MainActor
enum RegionBorderDrawing {
    /// Layered exterior strokes clipped to the outside of `shape`. The
    /// layered strokes produce a deterministic continuation of the control
    /// bar's dark shadow — NSShadow on an open path is mostly lost when
    /// clipped and composited in a transparent child panel.
    static func drawOuterShadow(
        path: NSBezierPath, shape: NSBezierPath, in bounds: CGRect,
        layers: [(width: CGFloat, alpha: CGFloat)], opacity: CGFloat
    ) {
        guard opacity > 0 else { return }
        NSGraphicsContext.saveGraphicsState()
        let outsideClip = NSBezierPath()
        outsideClip.appendRect(bounds)
        outsideClip.append(shape)
        outsideClip.windingRule = .evenOdd
        outsideClip.addClip()
        let shadowPath = path.copy() as! NSBezierPath
        for (width, alpha) in layers {
            shadowPath.lineWidth = width
            NSColor.black.withAlphaComponent(opacity * alpha).setStroke()
            shadowPath.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Fill the inverse of `shape` and let that opaque source cast one
    /// shadow into its transparent hole. Clipping the result to the shape
    /// keeps every glow pixel on the inside while avoiding the energy loss
    /// of blurring a 1pt stroke in both directions.
    static func drawInnerGlow(
        shape: NSBezierPath, in bounds: CGRect,
        color: NSColor, blur: CGFloat, alpha: CGFloat
    ) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        shape.addClip()
        let context = NSGraphicsContext.current!.cgContext
        context.setShadow(
            offset: .zero, blur: blur, color: color.withAlphaComponent(alpha).cgColor
        )
        let inverseShape = NSBezierPath(rect: bounds)
        inverseShape.append(shape)
        inverseShape.windingRule = .evenOdd
        NSColor.black.setFill()
        inverseShape.fill()
    }

    /// Glowing seam band between the selection and a docked mirror: a soft
    /// gradient band plus a crisp 1pt center line.
    static func drawSeam(
        band: CGRect, direction: MirrorDockingState,
        color: NSColor, bandAlpha: CGFloat, lineAlpha: CGFloat
    ) {
        let gradient = NSGradient(colors: [
            color.withAlphaComponent(0),
            color.withAlphaComponent(bandAlpha),
            color.withAlphaComponent(0)
        ])
        if direction == .left || direction == .right {
            gradient?.draw(in: band, angle: 0)
            color.withAlphaComponent(lineAlpha).setFill()
            CGRect(x: band.midX - 0.5, y: band.minY, width: 1, height: band.height).fill()
        } else {
            gradient?.draw(in: band, angle: 90)
            color.withAlphaComponent(lineAlpha).setFill()
            CGRect(x: band.minX, y: band.midY - 0.5, width: band.width, height: 1).fill()
        }
    }

    /// Solid monochrome ghost shared by the selection-screen output preview
    /// and the mirror window's drag-time dock preview: a rounded body filled
    /// and stroked with the region border color, with the titlebar hinted by
    /// a single divider line (no chrome buttons, no content lines), so it
    /// reads as a colored landing target rather than a copy of the window.
    static func drawSolidGhost(frame: CGRect, color: NSColor, in bounds: CGRect) {
        guard frame.width > 0, frame.height > 0 else { return }
        let path = NSBezierPath(
            roundedRect: frame,
            xRadius: RegionBorderTuning.cornerRadius,
            yRadius: RegionBorderTuning.cornerRadius
        )
        RegionBorderDrawing.drawOuterShadow(
            path: path, shape: path, in: bounds,
            layers: RegionBorderTuning.ghostShadowLayers, opacity: 1
        )
        color.withAlphaComponent(RegionBorderTuning.dockPreviewBodyAlpha).setFill()
        path.fill()
        color.withAlphaComponent(RegionBorderTuning.dockPreviewLineAlpha).setStroke()
        path.lineWidth = 1.5
        path.stroke()

        // Titlebar hint: one divider line at the real mirror window's chrome
        // height (the unified toolbar), so the ghost reads like the actual
        // window that will appear. It uses the same color and alpha as the
        // outline. Skipped on tiny frames where the titlebar would overflow.
        let chromeHeight = OverlayControlBarMetrics.height
        guard chromeHeight < frame.height else { return }
        color.withAlphaComponent(RegionBorderTuning.dockPreviewLineAlpha).setStroke()
        let separator = NSBezierPath()
        separator.move(to: CGPoint(x: frame.minX, y: frame.maxY - chromeHeight))
        separator.line(to: CGPoint(x: frame.maxX, y: frame.maxY - chromeHeight))
        separator.lineWidth = 1
        separator.stroke()
    }
}
