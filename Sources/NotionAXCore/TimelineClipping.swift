import Foundation

// Notion-specific pinned-list occlusion, NOT generic AX paint-order inference.
// AXVisibleOnly does not remove timeline labels behind the pinned list.
// Only node/paragraph presentation boxes may use this function. AX line boxes
// must remain the engine's original measurements, including covered portions.
package enum TimelineClipping {
    static func visibleBox(_ box: CGRect, behind panel: CGRect) -> CGRect {
        guard box.intersects(panel) else { return box }
        if panel.contains(box) { return .null }
        // A single rectangle can represent the remaining right-hand portion only
        // when the left panel spans the full text height. Leave other shapes
        // unchanged rather than inventing a bounding box across hidden content.
        guard panel.minX <= box.minX, panel.minY <= box.minY,
              panel.maxY >= box.maxY else { return box }
        return CGRect(x: panel.maxX, y: box.minY,
                      width: max(0, box.maxX - panel.maxX), height: box.height)
    }
}
