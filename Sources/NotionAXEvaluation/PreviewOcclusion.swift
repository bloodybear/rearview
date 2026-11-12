import Foundation

// Notion page previews are opaque panels over the background document. Their
// renderer also contains a translucent backdrop: use the panel wrapping the
// peek-top-hover-area, never the full renderer frame. No hit-test/range calls.
// For nodes/paragraphs only. AX line rectangles must not be processed here.
enum PreviewOcclusion {
    static func visibleBoxes(_ box: CGRect, behind panel: CGRect) -> [CGRect] {
        let covered = box.intersection(panel)
        guard !covered.isNull, !covered.isEmpty else { return [box] }
        return [
            CGRect(x:box.minX,y:box.minY,width:box.width,height:covered.minY-box.minY),
            CGRect(x:box.minX,y:covered.maxY,width:box.width,height:box.maxY-covered.maxY),
            CGRect(x:box.minX,y:covered.minY,width:covered.minX-box.minX,height:covered.height),
            CGRect(x:covered.maxX,y:covered.minY,width:box.maxX-covered.maxX,height:covered.height)
        ].filter { !$0.isEmpty && !$0.isNull }
    }
}
