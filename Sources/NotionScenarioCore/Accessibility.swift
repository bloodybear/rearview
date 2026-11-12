import AppKit
import ApplicationServices

enum NotionPageURL {
    static func id(from raw: String) -> String? {
        guard let components = URLComponents(string: raw),
              ["app.notion.com", "www.notion.so", "notion.so", "www.notion.com"].contains(components.host ?? ""),
              let tail = components.path.split(separator: "/").last else { return nil }
        let compact = tail.filter { $0 != "-" }
        guard compact.count >= 32 else { return nil }
        let suffix = String(compact.suffix(32))
        guard suffix.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0) }) else { return nil }
        let formatted = "\(suffix.prefix(8))-\(suffix.dropFirst(8).prefix(4))-\(suffix.dropFirst(12).prefix(4))-\(suffix.dropFirst(16).prefix(4))-\(suffix.suffix(12))"
        return UUID(uuidString: formatted)?.uuidString.lowercased()
    }
}

// Public Accessibility API only. AXDOMIdentifier is intentionally never persisted.
@MainActor
final class Accessibility {
    let app: AXUIElement
    let process: NSRunningApplication
    private let inputSource = CGEventSource(stateID: .hidSystemState)
    init() throws {
        guard AXIsProcessTrusted() else { throw ScenarioFailure("accessibility_permission", "Enable Accessibility for Notion Scenarios in System Settings.") }
        guard let process = NSRunningApplication.runningApplications(withBundleIdentifier: "notion.id").first else {
            throw ScenarioFailure("notion_not_running", "Open the Notion desktop app first.")
        }
        self.process = process
        inputSource?.localEventsSuppressionInterval = 0
        app = AXUIElementCreateApplication(process.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.35)
    }
    func get(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
        var result: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, name as CFString, &result) == .success ? result : nil
    }
    func supports(_ e: AXUIElement, _ key: String) -> Bool {
        var names: CFArray?
        return AXUIElementCopyAttributeNames(e, &names) == .success && (names as? [String] ?? []).contains(key)
    }
    func text(_ e: AXUIElement, _ name: String) -> String { get(e, name) as? String ?? "" }
    func children(_ e: AXUIElement) -> [AXUIElement] { get(e, "AXChildren") as? [AXUIElement] ?? [] }
    func parent(_ e: AXUIElement) -> AXUIElement? {
        guard let p = get(e, "AXParent"), CFGetTypeID(p) == AXUIElementGetTypeID() else { return nil }
        return (p as! AXUIElement)
    }
    func classes(_ e: AXUIElement) -> [String] { get(e, "AXDOMClassList") as? [String] ?? [] }
    func frame(_ e: AXUIElement) -> CGRect? {
        guard let p = get(e, "AXPosition"), let s = get(e, "AXSize"),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }
    func nodes(_ root: AXUIElement) -> [AXUIElement] {
        var result: [AXUIElement] = [], stack: [(AXUIElement, Int)] = [(root, 0)]
        var visited: [CFHashCode: [AXUIElement]] = [:]
        let deadline = Date().addingTimeInterval(2)
        while let (e, depth) = stack.popLast(), result.count < 3500, Date() < deadline {
            let hash = CFHash(e)
            if visited[hash]?.contains(where: { CFEqual($0, e) }) == true { continue }
            visited[hash, default: []].append(e)
            result.append(e)
            if depth < 40 { stack.append(contentsOf: children(e).reversed().map { ($0, depth + 1) }) }
        }
        return result
    }
    func set(_ e: AXUIElement, _ key: String, _ value: CFTypeRef) throws {
        let result = AXUIElementSetAttributeValue(e, key as CFString, value)
        guard result == .success else { throw ScenarioFailure("unsupported", "Cannot set \(key): AX error \(result.rawValue)") }
    }
    func press(_ e: AXUIElement, action: String = "AXPress") throws {
        let result = AXUIElementPerformAction(e, action as CFString)
        guard result == .success else { throw ScenarioFailure("unsupported", "Cannot perform \(action): AX error \(result.rawValue)") }
    }
    func setFrame(_ window: AXUIElement, _ rect: CGRect) throws {
        var point = rect.origin, size = rect.size
        try set(window, "AXPosition", AXValueCreate(.cgPoint, &point)!)
        try set(window, "AXSize", AXValueCreate(.cgSize, &size)!)
    }
    func pageID(_ web: AXUIElement) -> String? {
        let raw = (get(web, "AXURL") as? URL)?.absoluteString ?? text(web, "AXURL")
        return NotionPageURL.id(from: raw)
    }
    func isPage(_ web: AXUIElement, pageId: String) -> Bool {
        guard let actual = pageID(web), let wanted = UUID(uuidString: pageId)?.uuidString.lowercased() else { return false }
        return actual == wanted
    }
    func targets(pageId: String) -> [(AXUIElement, AXUIElement)] {
        var result: [(AXUIElement, AXUIElement)] = []
        for window in get(app, "AXWindows") as? [AXUIElement] ?? [] {
            for web in nodes(window) where text(web, "AXRole") == "AXWebArea" && isPage(web, pageId: pageId) { result.append((window, web)) }
        }
        return result
    }
    func focusedTarget() throws -> (window: AXUIElement, web: AXUIElement, pageId: String) {
        guard let raw = get(app, "AXFocusedWindow"), CFGetTypeID(raw) == AXUIElementGetTypeID() else {
            throw ScenarioFailure("current_page_unavailable", "Notion has no focused page window")
        }
        let window = raw as! AXUIElement
        guard (get(app, "AXWindows") as? [AXUIElement] ?? []).contains(where: { CFEqual($0, window) }) else {
            throw ScenarioFailure("current_page_unavailable", "Notion's focused page window is unavailable")
        }
        let pages = nodes(window).compactMap { web -> (AXUIElement, String)? in
            guard text(web, "AXRole") == "AXWebArea", let pageId = pageID(web) else { return nil }
            return (web, pageId)
        }
        guard pages.count == 1, let page = pages.first else {
            let code = pages.isEmpty ? "current_page_unavailable" : "current_page_ambiguous"
            let detail = pages.isEmpty ? "Could not read a Notion page URL from the focused window" : "The focused window exposes multiple Notion pages"
            throw ScenarioFailure(code, detail)
        }
        return (window, page.0, page.1)
    }
    func editor(_ web: AXUIElement) -> AXUIElement? {
        nodes(web).first { classes($0).contains("whenContentEditable") }
    }
    func viewport(_ web: AXUIElement) -> AXUIElement? {
        guard var node = editor(web) else { return nil }
        for _ in 0..<20 {
            let c = classes(node)
            if c.contains("notion-scroller") && c.contains("vertical") { return node }
            guard let p = parent(node) else { break }; node = p
        }
        return nil
    }
    func leaves(_ root: AXUIElement) -> [AXUIElement] {
        nodes(root).filter { text($0, "AXRole") == "AXTextArea" && classes($0).contains("notranslate") }
    }
    func matching(_ anchor: Anchor, in root: AXUIElement) -> [AXUIElement] {
        let editable = leaves(root).filter { text($0, "AXValue") == anchor.text }
        let candidates = editable.isEmpty ? nodes(root).filter {
            // Observed Notion column headers expose AXPopUpButton, and view
            // tabs expose AXRadioButton. Their titles are replay anchors too.
            ["AXStaticText", "AXCell", "AXColumn", "AXButton", "AXPopUpButton", "AXRadioButton"].contains(text($0, "AXRole")) && label($0) == anchor.text
        } : editable
        return candidates.filter { e in
            var current: AXUIElement? = e
            var blockMatches = anchor.blockClass == nil, ancestorMatches = anchor.ancestorText == nil
            for _ in 0..<15 {
                guard let n = current else { break }
                if let c = anchor.blockClass, classes(n).contains(c) { blockMatches = true }
                if let t = anchor.ancestorText, n != e, leaves(n).contains(where: { text($0, "AXValue") == t }) { ancestorMatches = true }
                // Do not treat the entire document as an enclosing block.
                if classes(n).contains("whenContentEditable") { break }
                current = parent(n)
            }
            return blockMatches && ancestorMatches
        }
    }
    func unique(_ anchor: Anchor, in root: AXUIElement) throws -> AXUIElement? {
        let candidates = matching(anchor, in: root)
        let hits = candidates.filter { candidate in
            !candidates.contains { other in !CFEqual(candidate, other) && contains(candidate, other) }
        }
        // Sticky headers may retain an offscreen clone of one authored label.
        // A unique visible instance is a deterministic navigation target.
        let visible = hits.filter { frame($0).map { $0.width > 0 && $0.height > 0 } ?? false }
        if visible.count == 1 { return visible[0] }
        guard hits.count <= 1 else { throw ScenarioFailure("ambiguous_anchor", "More than one loaded element matches: \(anchor.text.prefix(60))") }
        return hits.first
    }
    func key(_ code: CGKeyCode, flags: CGEventFlags = []) {
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: inputSource, virtualKey: code, keyDown: down)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
    }
    func click(_ e: AXUIElement, flags: CGEventFlags = []) throws {
        guard let r = frame(e), r.width > 0, r.height > 0 else { throw ScenarioFailure("unsupported", "Control has no clickable frame") }
        let point = CGPoint(x: r.midX, y: r.midY)
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            let event = CGEvent(mouseEventSource: inputSource, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
    }
    func rightClick(_ element: AXUIElement) throws {
        guard let frame = frame(element), frame.width > 0, frame.height > 0 else { throw ScenarioFailure("unsupported", "Context menu target has no visible frame") }
        let point = CGPoint(x: frame.midX, y: frame.midY)
        for type in [CGEventType.rightMouseDown, .rightMouseUp] {
            CGEvent(mouseEventSource: inputSource, mouseType: type, mouseCursorPosition: point, mouseButton: .right)?.post(tap: .cghidEventTap)
        }
    }
    @discardableResult
    func wheel(_ delta: Int, viewport: AXUIElement, horizontal: Bool = false) throws -> CGPoint {
        guard let rect = frame(viewport), rect.width > 0, rect.height > 0 else {
            throw ScenarioFailure("unsupported", "Cannot read body viewport for scroll input")
        }
        let system = AXUIElementCreateSystemWide()
        // A database body's right side reaches the movable timeline canvas
        // beside its pinned list. Other panes keep their established input order.
        let preferRightSide = horizontal && classes(viewport).contains("notion-collection-view-body")
        let candidates: [(CGFloat, CGFloat)] = preferRightSide
            ? [(0.88,0.5),(0.12,0.5),(0.5,0.1),(0.5,0.5),(0.5,0.8),(0.25,0.25),(0.75,0.75)]
            : [(0.12,0.5),(0.88,0.5),(0.5,0.1),(0.5,0.5),(0.5,0.8),(0.25,0.25),(0.75,0.75)]
        var destination: CGPoint?
        for (x,y) in candidates {
            let point = CGPoint(x: rect.minX + rect.width*x, y: rect.minY + rect.height*y)
            var hit: AXUIElement?
            guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success, let hit else { continue }
            var pid: pid_t = 0
            AXUIElementGetPid(hit, &pid)
            guard pid == process.processIdentifier else { continue }
            // Same-app menus and floating sidebars must not receive body scrolls.
            var node: AXUIElement? = hit
            for _ in 0..<40 {
                guard let current = node else { break }
                if CFEqual(current, viewport) { destination = point; break }
                // Timeline canvases can consume a vertical wheel as a saved
                // date pan. Tables still need body scroll input when their
                // rows fill the viewport after a reverse boundary probe.
                if !horizontal, classes(viewport).contains("vertical"),
                   classes(current).contains(where: { $0.contains("timeline") }) { break }
                node = parent(current)
            }
            if destination != nil { break }
        }
        guard let point = destination else {
            throw ScenarioFailure("target_occluded", "No exposed Notion body point passed AX hit testing; no scroll input was sent")
        }
        CGWarpMouseCursorPosition(point)
        let move = CGEvent(mouseEventSource: inputSource, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)
        move?.flags = .maskNonCoalesced; move?.post(tap: .cghidEventTap)
        let event = CGEvent(scrollWheelEvent2Source: inputSource, units: .pixel, wheelCount: horizontal ? 2 : 1,
                            wheel1: horizontal ? 0 : Int32(delta), wheel2: horizontal ? Int32(delta) : 0, wheel3: 0)
        event?.flags = .maskNonCoalesced; event?.location = point
        event?.post(tap: .cghidEventTap)
        return point
    }
    func url(_ element: AXUIElement) -> String {
        (get(element, "AXURL") as? URL)?.absoluteString ?? text(element, "AXURL")
    }
    func label(_ element: AXUIElement) -> String {
        for name in ["AXTitle", "AXDescription", "AXValue"] {
            let value = text(element, name)
            if !value.isEmpty { return value }
        }
        return ""
    }
    func contains(_ ancestor: AXUIElement, _ element: AXUIElement) -> Bool {
        var node: AXUIElement? = element
        for _ in 0..<45 {
            guard let current = node else { return false }
            if CFEqual(current, ancestor) { return true }
            node = parent(current)
        }
        return false
    }
    func move(_ point: CGPoint) {
        CGWarpMouseCursorPosition(point)
        CGEvent(mouseEventSource: inputSource, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    }
    func drag(from: CGPoint, to: CGPoint) async throws {
        move(from)
        try await Task.sleep(for: .milliseconds(60))
        CGEvent(mouseEventSource: inputSource, mouseType: .leftMouseDown, mouseCursorPosition: from, mouseButton: .left)?.post(tap: .cghidEventTap)
        try await Task.sleep(for: .milliseconds(60))
        for index in 1...12 {
            let fraction = Double(index) / 12
            let point = CGPoint(x: from.x + (to.x - from.x) * fraction, y: from.y + (to.y - from.y) * fraction)
            CGEvent(mouseEventSource: inputSource, mouseType: .leftMouseDragged, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
            try await Task.sleep(for: .milliseconds(16))
        }
        CGEvent(mouseEventSource: inputSource, mouseType: .leftMouseUp, mouseCursorPosition: to, mouseButton: .left)?.post(tap: .cghidEventTap)
    }
    func menu(_ title: String) throws {
        guard let bar = get(app, "AXMenuBar"), CFGetTypeID(bar) == AXUIElementGetTypeID() else { throw ScenarioFailure("unsupported", "No application menu") }
        let root = bar as! AXUIElement
        guard let view = children(root).first(where: { text($0, "AXTitle") == "View" }) else { throw ScenarioFailure("unsupported", "View menu unavailable in this Notion locale") }
        try press(view)
        guard let item = nodes(view).first(where: { text($0, "AXTitle") == title }) else { key(53); throw ScenarioFailure("unsupported", "Menu item \(title) unavailable") }
        try press(item)
    }
}
