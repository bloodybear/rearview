import Foundation

// Shared geometry for explicitly associated Notion table/timeline headers.
// Do not use arbitrary AXGroup frames as opaque headers. Nodes/paragraphs only;
// AX line boxes remain original even when extending behind a header.
package enum StickyHeaderClipping {
    static func belowHeader(_ box: CGRect, header: CGRect) -> CGRect {
        guard box.intersects(header) else { return box }
        if header.contains(box) { return .null }
        // A sticky top header may clip vertically only when it covers the whole
        // width. Do not invent one rectangle for a nonrectangular remainder.
        guard header.minX <= box.minX, header.maxX >= box.maxX,
              header.minY <= box.minY else { return box }
        return CGRect(x:box.minX, y:header.maxY, width:box.width,
                      height:max(0,box.maxY-header.maxY))
    }
}
