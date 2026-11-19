import Foundation

package enum AXBranchPruning {
    enum Scope {
        case body
        case simpleTable(CGRect)
        case preserve

        func descending(into classes: [String], frame: CGRect?) -> Self {
            if case .preserve = self { return self }
            if classes.contains(where: protectedClasses.contains) { return .preserve }
            if classes.contains("notion-table-tbody-selectable"), let frame, frame.hasUsableArea {
                return .simpleTable(frame)
            }
            return self
        }
    }

    private static let protectedClasses: Set<String> = [
        "notion-overlay-container", "notion-default-overlay-container", "notion-text-action-menu",
        "notion-timeline-view", "sticky-portal-target", "notion-table-view-header-row",
    ]
    private static let blockClasses: Set<String> = [
        "notion-text-block", "notion-header-block", "notion-sub_header-block", "notion-sub_sub_header-block",
        "notion-bulleted_list-block", "notion-numbered_list-block", "notion-to_do-block", "notion-toggle-block",
        "notion-callout-block", "notion-code-block", "notion-tab-block",
        "notion-column_list-block", "notion-column-block", "notion-table-block", "notion-table-tbody-selectable",
        "notion-collection-item", "notion-table-view-cell",
    ]

    static func shouldSkipChildren(role: String, classes: [String], frame: CGRect?,
                                   captureViewport: CGRect, scope: Scope) -> Bool {
        guard let frame, frame.hasFiniteEdges, frame.width >= 0, frame.height >= 0,
              captureViewport.hasUsableArea else { return false }
        if case .preserve = scope { return false }

        let viewport: CGRect
        if classes.contains(where: blockClasses.contains) {
            viewport = captureViewport
        } else if case let .simpleTable(table) = scope, role == "AXRow" || role == "AXCell" {
            viewport = captureViewport.intersection(table)
        } else {
            return false
        }
        guard viewport.hasUsableArea else { return false }

        // Chromium can collapse a fully clipped block to a 1pt strip at the
        // clipping edge. Keep thin boxes elsewhere and any partial overlap >1pt.
        let verticallyClamped = frame.height <= 1 &&
            min(abs(frame.minY - viewport.minY), abs(frame.minY - viewport.maxY)) <= 1
        let horizontallyClamped = frame.width <= 1 &&
            min(abs(frame.minX - viewport.minX), abs(frame.minX - viewport.maxX)) <= 1
        return verticallyClamped || horizontallyClamped ||
            (frame.hasUsableArea && !frame.intersects(viewport))
    }
}

private extension CGRect {
    var hasFiniteEdges: Bool {
        [minX, minY, maxX, maxY].allSatisfy(\.isFinite)
    }

    var hasUsableArea: Bool {
        hasFiniteEdges && width > 0 && height > 0
    }
}
