import ApplicationServices
import Foundation

package enum AXPrefetch {
    static let classes: Set<String> = ["notion-text-block", "notion-header-block",
        "notion-sub_header-block", "notion-sub_sub_header-block"]

    static func source(_ block: AXUIElement, cancellation: AXCancellation) throws -> String? {
        var calls = 0
        func read(_ node: AXUIElement, _ name: String, _ argument: CFTypeRef? = nil) throws -> CFTypeRef? {
            try cancellation.check()
            guard calls < 32 else { return nil }
            calls += 1
            var value: CFTypeRef?
            let status = argument.map { AXUIElementCopyParameterizedAttributeValue(node, name as CFString, $0, &value) }
                ?? AXUIElementCopyAttributeValue(node, name as CFString, &value)
            try cancellation.check()
            return status == .success ? value : nil
        }
        var stack = [block]
        var owner: AXUIElement?
        var leaves: [(AXUIElement, String)] = []
        while let node = stack.popLast() {
            switch try read(node, "AXRole") as? String {
            case "AXGroup":
                guard try read(node, "AXSubrole") as? String != "AXDocumentMath",
                      let children = try read(node, "AXChildren") as? [AXUIElement] else { return nil }
                stack.append(contentsOf: children.reversed())
            case "AXTextArea":
                guard owner == nil, let children = try read(node, "AXChildren") as? [AXUIElement] else { return nil }
                owner = node
                stack.append(contentsOf: children.reversed())
            case "AXStaticText":
                guard owner != nil, let value = try read(node, "AXValue") as? String, !value.isEmpty else { return nil }
                leaves.append((node, value))
            default: return nil
            }
        }
        func range(_ node: AXUIElement) throws -> AXTextMarkerRange? {
            guard let value = try read(node, "AXTextMarkerRangeForUIElement", node),
                  CFGetTypeID(value) == AXTextMarkerRangeGetTypeID() else { return nil }
            return (value as! AXTextMarkerRange)
        }
        guard let owner, let first = leaves.first?.0, let last = leaves.last?.0,
              let a = try range(first), let b = try first == last ? a : range(last) else { return nil }
        let span = AXTextMarkerRangeCreate(nil, AXTextMarkerRangeCopyStartMarker(a), AXTextMarkerRangeCopyEndMarker(b))
        let source = leaves.map { $0.1 }.joined()
        guard source.rangeOfCharacter(from: .newlines) == nil,
              let native = try read(owner, "AXStringForTextMarkerRange", span) as? String,
              native.utf16.elementsEqual(source.utf16) else { return nil }
        return source
    }
}
