import Foundation

// The replay's viewport describes document content, not every visible Notion UI
// region. Sidebars and page previews are separate translation surfaces. Restrict each to
// its own observed AX frame/window rather than accidentally to the body or peek.
enum SelectionViewport {
    static func region(surface: CGRect?, content: CGRect, window: CGRect) -> CGRect {
        guard let surface else { return content }
        return surface.intersection(window)
    }
}
