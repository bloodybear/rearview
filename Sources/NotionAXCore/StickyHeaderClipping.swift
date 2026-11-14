import Foundation

// Shared geometry for explicitly associated Notion table/timeline headers.
// Do not use arbitrary AXGroup frames as opaque headers. Nodes/paragraphs only;
// AX line boxes remain original even when extending behind a header.
package enum StickyHeaderClipping {
    // Only call after associating the explicit calendar/list header structures
    // in the same scroller. The portal's collapsed height is not its paint area.
    static func timelineHeader(listHeader: CGRect, timeline: CGRect, calendarPortal: CGRect) -> CGRect? {
        guard [listHeader, timeline, calendarPortal].allSatisfy({
            !$0.isNull && !$0.isInfinite && $0.width > 1 && $0.height > 0
        }), listHeader.height > 1, timeline.height > 1,
              abs(listHeader.minY - timeline.minY) <= 1,
              abs(calendarPortal.minY - listHeader.minY) <= 1,
              listHeader.minX <= timeline.minX + 1,
              listHeader.maxX < timeline.maxX,
              calendarPortal.minX <= timeline.minX,
              calendarPortal.maxX >= timeline.maxX else { return nil }
        return CGRect(x:timeline.minX, y:listHeader.minY, width:timeline.width, height:listHeader.height)
    }

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
