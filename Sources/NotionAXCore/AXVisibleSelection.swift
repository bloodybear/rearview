import ApplicationServices

// Search results are compared by AX object identity, never by text or traversal ID.
// Keep broad raw observations for research; this set filters selected inputs only.
package struct AXElementMembership {
    private var buckets: [CFHashCode: [AXUIElement]] = [:]
    init(_ elements: [AXUIElement]) {
        for element in elements { buckets[CFHash(element), default: []].append(element) }
    }
    func contains(_ element: AXUIElement) -> Bool {
        buckets[CFHash(element)]?.contains(where: { CFEqual($0, element) }) == true
    }
}

package enum AXVisibleSelection {
    // Absence from the visible search is meaningful only if the same search
    // without AXVisibleOnly can discover that exact element. Native chrome and
    // unsearchable elements are not silently classified as offscreen.
    static func excludes(discovered: Bool, visible: Bool) -> Bool {
        discovered && !visible
    }
}
