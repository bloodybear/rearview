import AppKit
import ApplicationServices

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
        let deadline = Date().addingTimeInterval(2)
        while let (e, depth) = stack.popLast(), result.count < 3500, Date() < deadline {
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
    func isPage(_ web: AXUIElement, pageId: String) -> Bool {
        let raw = (get(web, "AXURL") as? URL)?.absoluteString ?? text(web, "AXURL")
        guard let url = URL(string: raw), ["app.notion.com", "www.notion.so", "notion.so", "www.notion.com"].contains(url.host ?? "") else { return false }
        let tail = url.path.split(separator: "/").last.map(String.init) ?? ""
        let wanted = pageId.replacingOccurrences(of: "-", with: "").lowercased()
        return tail.replacingOccurrences(of: "-", with: "").lowercased().hasSuffix(wanted)
    }
    func targets(pageId: String) -> [(AXUIElement, AXUIElement)] {
        var result: [(AXUIElement, AXUIElement)] = []
        for window in get(app, "AXWindows") as? [AXUIElement] ?? [] {
            for web in nodes(window) where text(web, "AXRole") == "AXWebArea" && isPage(web, pageId: pageId) { result.append((window, web)) }
        }
        return result
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
        leaves(root).filter { e in
            guard text(e, "AXValue") == anchor.text else { return false }
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
        let hits = matching(anchor, in: root)
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
    func click(_ e: AXUIElement) throws {
        guard let r = frame(e), r.width > 0, r.height > 0 else { throw ScenarioFailure("unsupported", "Control has no clickable frame") }
        let point = CGPoint(x: r.midX, y: r.midY)
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            let event = CGEvent(mouseEventSource: inputSource, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
            event?.post(tap: .cghidEventTap)
        }
    }
    @discardableResult
    func wheel(_ delta: Int, viewport: AXUIElement) throws -> CGPoint {
        guard let rect = frame(viewport), rect.width > 0, rect.height > 0 else {
            throw ScenarioFailure("unsupported", "Cannot read body viewport for scroll input")
        }
        let system = AXUIElementCreateSystemWide()
        let candidates: [(CGFloat, CGFloat)] = [(0.5,0.5),(0.12,0.5),(0.88,0.5),(0.5,0.8),(0.25,0.25),(0.75,0.75)]
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
        let event = CGEvent(scrollWheelEvent2Source: inputSource, units: .pixel, wheelCount: 1, wheel1: Int32(delta), wheel2: 0, wheel3: 0)
        event?.flags = .maskNonCoalesced; event?.location = point
        event?.post(tap: .cghidEventTap)
        return point
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
