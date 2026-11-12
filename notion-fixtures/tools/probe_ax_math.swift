import AppKit
import ApplicationServices

// Opt-in research only. Match a saved paragraph to the unchanged live AX tree,
// inventory the advertised attributes, and compare text spans with the existing
// native line collector. No input events, DOM/CDP, rectangle unions or changes
// to the extractor's final selection. Paragraph IDs are experiment inputs.
func mathRect(_ b: CGRect) -> [String: Double] {
    ["x": b.minX, "y": b.minY, "width": b.width, "height": b.height]
}
func rect(_ b: CGRect) -> [String: Double] { mathRect(b) }
@main struct MathProbe {
    static func main() throws {
        let folder = URL(fileURLWithPath: CommandLine.arguments[1])
        let ids = CommandLine.arguments.dropFirst(2).compactMap(Int.init)
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("rawAx.json"))) as! [[String: Any]]
        guard !ids.isEmpty, AXIsProcessTrusted(),
              let process = NSRunningApplication.runningApplications(withBundleIdentifier: "notion.id").first
        else { throw NSError(domain: "math-probe: explicit paragraph IDs / Notion / AX trust required", code: 1) }
        let app = AXUIElementCreateApplication(process.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.35)
        let access = AXTextAccess()
        let previousManual = access.attr(app, "AXManualAccessibility")
        let activation = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        defer { AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, previousManual ?? kCFBooleanFalse) }
        guard activation == .success else { throw NSError(domain: "math-probe: manual activation", code: Int(activation.rawValue)) }
        Thread.sleep(forTimeInterval: 2.5)
        guard let root = access.asElement(access.attr(app, "AXFocusedWindow")) else {
            throw NSError(domain: "math-probe: no focused window", code: 2)
        }
        func frame(_ e: AXUIElement) -> CGRect? {
            guard let p = access.attr(e, "AXPosition"), let s = access.attr(e, "AXSize"),
                  CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
            var pt = CGPoint.zero, sz = CGSize.zero
            guard AXValueGetValue(p as! AXValue, .cgPoint, &pt), AXValueGetValue(s as! AXValue, .cgSize, &sz) else { return nil }
            return CGRect(origin: pt, size: sz)
        }
        let deadline = Date().addingTimeInterval(90)
        var stack = [root], seen = Set<AXUIElement>(), found: [Int: AXUIElement] = [:]
        while let e = stack.popLast(), seen.count < 5000, Date() < deadline {
            guard seen.insert(e).inserted else { continue }
            let children = access.attr(e, "AXChildren") as? [AXUIElement] ?? []
            stack.append(contentsOf: children.reversed())
            guard let role = access.attr(e, "AXRole") as? String else { continue }
            let possible = ids.filter { raw[$0]["role"] as? String == role }
            guard !possible.isEmpty, let text = access.attr(e, "AXValue") as? String, let b = frame(e) else { continue }
            for id in possible where raw[id]["value"] as? String == text {
                guard let f = raw[id]["frame"] as? [String: Double] else { continue }
                if abs(f["x"]! - b.minX) < 0.5 && abs(f["y"]! - b.minY) < 0.5 &&
                    abs(f["width"]! - b.width) < 0.5 && abs(f["height"]! - b.height) < 0.5 { found[id] = e }
            }
        }
        func value(_ v: CFTypeRef?) -> Any {
            guard let v else { return NSNull() }
            if CFGetTypeID(v) == AXUIElementGetTypeID() { return "AXUIElement" }
            if let s = v as? String { return s }
            if let a = v as? [String] { return a }
            if let a = v as? [AXUIElement] { return ["elementCount": a.count] }
            if let n = v as? NSNumber { return n }
            return String(describing: v)
        }
        func rangeProbe(_ receiver: AXUIElement, _ a: AXUIElement, _ b: AXUIElement) -> [String: Any] {
            let q = NativeParagraphLines.Queries(RangeInvestigator(deadline: deadline))
            guard let ar = q.whole(a), let br = q.whole(b) else { return ["status": "range_unavailable", "calls": q.investigator.calls] }
            let r = AXTextMarkerRangeCreate(nil, AXTextMarkerRangeCopyStartMarker(ar), AXTextMarkerRangeCopyEndMarker(br))
            let text = q.string(receiver, r), box = q.box(receiver, r)
            return ["status": box == nil ? "no_positive_bounds" : "bounds_returned", "text": text as Any? ?? NSNull(),
                    "box": box.map(mathRect) as Any? ?? NSNull(), "calls": q.investigator.calls]
        }
        var results: [[String: Any]] = []
        for id in ids {
            guard let owner = found[id] else { results.append(["node": id, "status": "unmatched_live_paragraph"]); continue }
            var elements: [AXUIElement] = [], parents: [Int?] = []
            func visit(_ e: AXUIElement, _ parent: Int?, _ depth: Int) {
                guard elements.count < 250, depth < 25 else { return }
                let index = elements.count; elements.append(e); parents.append(parent)
                for c in access.attr(e, "AXChildren") as? [AXUIElement] ?? [] { visit(c, index, depth + 1) }
            }
            visit(owner, nil, 0)
            var observations: [[String: Any]] = []
            for (i, e) in elements.enumerated() {
                var names: CFArray?, parameterNames: CFArray?
                let attrError = AXUIElementCopyAttributeNames(e, &names)
                let paramError = AXUIElementCopyParameterizedAttributeNames(e, &parameterNames)
                let listed = names as? [String] ?? []
                var attrs: [String: Any] = [:]
                for key in listed where !["AXChildren", "AXParent", "AXWindow", "AXTopLevelUIElement"].contains(key) {
                    attrs[key] = value(access.attr(e, key))
                }
                // These diagnostic names are not necessarily advertised. Record
                // failures rather than mistaking absence for a false property.
                var extra: [String: Any] = [:]
                for key in ["AXDOMClassList", "AXDOMIdentifier", "AXARIARole", "AXRoleDescription", "AXSubrole", "AXDescription", "AXHelp"] where !listed.contains(key) {
                    var v: CFTypeRef?; let err = AXUIElementCopyAttributeValue(e, key as CFString, &v)
                    extra[key] = ["error": err.rawValue, "value": value(v)]
                }
                var entry: [String: Any] = ["index": i, "parent": parents[i] as Any? ?? NSNull(), "attributes": attrs,
                    "attributeNamesError": attrError.rawValue, "parameterNamesError": paramError.rawValue,
                    "parameterNames": parameterNames as? [String] ?? [], "extra": extra,
                    "frame": frame(e).map(mathRect) as Any? ?? NSNull(), "wholeRange": rangeProbe(owner, e, e)]
                if let r = access.param(e, "AXTextMarkerRangeForUIElement", e), CFGetTypeID(r) == AXTextMarkerRangeGetTypeID() {
                    let marker = AXTextMarkerRangeCopyStartMarker(r as! AXTextMarkerRange)
                    entry["debugStart"] = value(access.param(owner, "AXTextMarkerNodeDebugDescription", marker))
                }
                observations.append(entry)
            }
            let leafIndices = elements.indices.filter { access.attr(elements[$0], "AXRole") as? String == "AXStaticText" }
            var experiments: [[String: Any]] = []
            func collect(_ label: String, _ indices: [Int]) {
                guard !indices.isEmpty else { return }
                var base = 0
                let leaves = indices.map { i -> NativeParagraphLines.Leaf in
                    let text = access.attr(elements[i], "AXValue") as? String ?? ""
                    defer { base += text.utf16.count }
                    return .init(id: i, node: elements[i], text: text, base: base)
                }
                let text = leaves.map(\.text).joined()
                // Both APIs used by current extraction, without geometry edits.
                let inv = RangeInvestigator(deadline: deadline)
                let start = Date()
                let output = inv.inspectParagraph(owner, role: "AXTextArea", leaves: leaves.map { ($0.id, $0.node, $0.text) }, viewport: CGRect(x: -10000, y: -10000, width: 20000, height: 20000))
                experiments.append(["label": label, "indices": indices, "text": text, "output": output,
                    "calls": inv.calls, "seconds": Date().timeIntervalSince(start),
                    "nativeSpan": rangeProbe(owner, elements[indices.first!], elements[indices.last!])])
            }
            collect("all-leaves-current", leafIndices)
            let geometricText = leafIndices.filter { i in frame(elements[i]).map { $0.width > 0 && $0.height > 1 } ?? false }
            collect("positive-frame-leaves-diagnostic-not-a-rule", geometricText)
            func insideMath(_ index: Int) -> Bool {
                var p: Int? = index
                while let i = p {
                    if access.attr(elements[i], "AXSubrole") as? String == "AXDocumentMath" { return true }
                    p = parents[i]
                }
                return false
            }
            let mathLeaves = Set(leafIndices.filter(insideMath))
            var span: [Int] = [], segment = 0
            func flush() {
                guard !span.isEmpty else { return }
                collect("outside-math-span-\(segment)", span)
                segment += 1; span = []
            }
            for i in leafIndices {
                if mathLeaves.contains(i) { flush() }
                else { span.append(i) }
            }
            flush()
            for i in leafIndices { collect("individual-leaf-\(i)", [i]) }
            let children = elements.indices.filter { parents[$0] == 0 }
            for i in children {
                let subset = leafIndices.filter { leaf in
                    var p: Int? = leaf
                    while let index = p { if index == i { return true }; p = parents[index] }
                    return false
                }
                collect("direct-child-\(i)", subset)
            }
            results.append(["node": id, "status": "measured", "source": raw[id]["value"] ?? "", "subtree": observations, "experiments": experiments])
        }
        let out: [String: Any] = ["paragraphs": results, "timedOut": Date() > deadline, "discoveryNodeCount": seen.count,
            "scope": "AX-only research; no selection, translation or geometry policy changes; diagnostic leaf exclusions are not production rules"]
        try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]).write(to: folder.appendingPathComponent("math-study.json"))
        print("Measured \(results.count) math paragraphs; matched=\(found.count); timeout=\(Date() > deadline)")
        guard found.count == ids.count, Date() < deadline else { throw NSError(domain: "math-probe: incomplete", code: 3) }
    }
}
