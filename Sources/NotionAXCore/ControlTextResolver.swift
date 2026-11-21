import AppKit
import ApplicationServices

// Resolve native text before line extraction. Each instance lives for one capture.
package final class ControlTextResolver: AXTextAccess {
    struct Text {
        let element: AXUIElement
        let parent: AXUIElement?
        let value: String
        let title: String
        let source: String
        let frame: CGRect
        let method: String
        let parentFrames: [Entry]
    }
    struct Result {
        var texts: [Text] = []
        var status = "text_unavailable"
        var emptyRange = false
        var internalTextAttempted = false
        var complete = true
    }

    private var verifyTextParents = false
    private var parentValidationCalls = 0
    private var parentValidationSeconds = 0.0
    private var groupChildren: [AXUIElement: [AXUIElement]] = [:]
    private var observations: [AXUIElement: Entry] = [:]

    private func observation(_ element: AXUIElement) -> Entry {
        if let cached = observations[element] { return cached }
        let data = many(element, ["AXRole", "AXValue", "AXTitle", "AXFrame", "AXParent"])
        observations[element] = data
        return data
    }

    private func text(_ anchor: AXUIElement, owner: AXUIElement,
                      method: String, internalOwnership: Bool = false) -> Text? {
        guard !CFEqual(anchor, owner) else { return nil }
        var element = anchor
        var data = observation(element)
        guard data["AXRole"] as? String == "AXStaticText" else { return nil }
        // Marker anchors can be inlineTextBox wrappers. Their StaticText parent
        // provides the full native string across its visual lines.
        if !internalOwnership, let parent = asElement(data["AXParent"] as CFTypeRef?) {
            let parentData = observation(parent)
            if parentData["AXRole"] as? String == "AXStaticText" {
                element = parent
                data = parentData
            }
        }
        let parent = asElement(data["AXParent"] as CFTypeRef?)
        var parentFrames: [Entry] = []
        if !internalOwnership {
            var ancestor = parent
            var belongsToOwner = false
            for _ in 0..<16 {
                guard let current = ancestor else { break }
                if CFEqual(current, owner) { belongsToOwner = true; break }
                let info = observation(current)
                // Retain frames already read for ownership and paragraph geometry.
                // Ignored AX parents may be absent from the exported child tree.
                if let role = info["AXRole"] as? String,
                   let f = asRect(info["AXFrame"] as CFTypeRef?) {
                    var saved: Entry = ["role":role,"frame":rect(f)]
                    if role == "AXGroup", verifyTextParents {
                        if groupChildren[current] == nil {
                            let started = Date()
                            groupChildren[current] = get(current,"AXChildren") as? [AXUIElement] ?? []
                            parentValidationCalls += 1
                            parentValidationSeconds += Date().timeIntervalSince(started)
                        }
                        let children = groupChildren[current] ?? []
                        groupChildren[current] = children
                        saved["singleTextOwnerVerified"] = children.count == 1 && CFEqual(children[0],element)
                    }
                    parentFrames.append(saved)
                }
                if ["AXButton", "AXPopUpButton", "AXRadioButton", "AXWebArea", "AXWindow"]
                    .contains(info["AXRole"] as? String ?? "") { break }
                ancestor = asElement(info["AXParent"] as CFTypeRef?)
            }
            guard belongsToOwner else { return nil }
        }
        let value = data["AXValue"] as? String ?? ""
        let title = data["AXTitle"] as? String ?? ""
        var source = value
        if source.isEmpty,
           let whole = param(element, "AXTextMarkerRangeForUIElement", element),
           let native = param(element, "AXStringForTextMarkerRange", whole) as? String {
            source = native
        }
        guard !source.isEmpty, let frame = asRect(data["AXFrame"] as CFTypeRef?),
              !rectArray(frame).isEmpty else { return nil }
        return Text(element: element, parent: parent, value: value, title: title,
                    source: source, frame: frame, method: method, parentFrames: parentFrames)
    }

    private func fromMarker(_ raw: CFTypeRef?, owner: AXUIElement, method: String) -> Text? {
        for (_, marker) in endpoints(raw) {
            if let anchor = asElement(param(owner, "AXUIElementForTextMarker", marker)),
               let found = text(anchor, owner: owner, method: method) { return found }
        }
        return nil
    }

    func resolve(_ element: AXUIElement, header: Bool, internalText: Bool,
                 neighbors: [AXUIElement], deadline: Date, documentTab: Bool = false) -> Result {
        guard Date() < deadline,
              let raw = param(element, "AXTextMarkerRangeForUIElement", element),
              CFGetTypeID(raw) == AXTextMarkerRangeGetTypeID() else { return Result() }
        let range = raw as! AXTextMarkerRange
        let start = AXTextMarkerRangeCopyStartMarker(range)
        let end = AXTextMarkerRangeCopyEndMarker(range)
        let empty = sameMarkerBytes(start, end)
        var result = Result(emptyRange: empty)

        // Document tabs can expose a title while their native range is empty.
        // Restrict this fallback to their observed semantic ancestry; other
        // empty controls retain the existing no-extra-query path.
        if internalText || (documentTab && empty) {
            result.internalTextAttempted = true
            // Sidebar/document tab text can be absent from text navigation.
            // SVG can contain multiple labels; enumerate real StaticText children.
            // Chromium 156's serialization is checked by internalTree before
            // constructing any child marker. Unsupported formats stay unresolved.
            guard let description = param(element, "AXTextMarkerNodeDebugDescription", start) as? String else {
                result.status = "internal_text_description_unavailable"
                return result
            }
            var texts: [Text] = []
            let tree = internalTree(element, start, description) { anchor in
                if Date() < deadline,
                   let found = self.text(anchor, owner: element,
                                         method: "internal_child_text", internalOwnership: true),
                   !texts.contains(where: { CFEqual($0.element, found.element) }) {
                    texts.append(found)
                }
                return [:]
            }
            result.complete = tree.complete && Date() < deadline
            result.texts = texts
            result.status = result.complete ? "internal_text_resolved" : "internal_text_incomplete"
            return result
        }

        if header, let found = fromMarker(
            param(element, "AXLineTextMarkerRangeForTextMarker", start),
            owner: element, method: "header_line_start") {
            result.texts = [found]
        }
        if result.texts.isEmpty && !empty {
            for (endpoint, outward, inward) in [
                (start, "AXPreviousTextMarkerForTextMarker", "AXNextTextMarkerForTextMarker"),
                (end, "AXNextTextMarkerForTextMarker", "AXPreviousTextMarkerForTextMarker")
            ] {
                guard Date() < deadline, var position = param(element, outward, endpoint) else { continue }
                for _ in 0..<2 {
                    guard let moved = param(element, inward, position) else { break }
                    position = moved
                    if let found = fromMarker(position, owner: element, method: "character_return") {
                        result.texts = [found]
                        break
                    }
                }
                if !result.texts.isEmpty { break }
            }
            if result.texts.isEmpty,
               let found = fromMarker(param(element, "AXLineTextMarkerRangeForTextMarker", start),
                                      owner: element, method: "native_line_start") {
                result.texts = [found]
            }
            if result.texts.isEmpty,
               let found = fromMarker(param(element, "AXNextLineEndTextMarkerForTextMarker", start),
                                      owner: element, method: "native_line_end") {
                result.texts = [found]
            }
        }
        if result.texts.isEmpty {
            for neighbor in neighbors.prefix(3) {
                guard Date() < deadline,
                      let range = param(neighbor, "AXTextMarkerRangeForUIElement", neighbor) else { continue }
                for (_, marker) in endpoints(range) {
                    for key in ["AXPreviousTextMarkerForTextMarker", "AXPreviousLineStartTextMarkerForTextMarker"] {
                        if let found = fromMarker(param(element, key, marker), owner: element,
                                                  method: "neighbor_control_marker") {
                            result.texts = [found]
                            break
                        }
                    }
                    if !result.texts.isEmpty { break }
                }
                if !result.texts.isEmpty { break }
            }
        }
        result.status = result.texts.isEmpty
            ? (empty ? "empty_native_text_range" : "text_unavailable")
            : "native_text_resolved"
        return result
    }
}

extension ControlTextResolver {
    func apply(rows: inout [Entry], elements: inout [AXUIElement], candidates: inout [Entry],
               deadline: Date, filterTiny: Bool) -> Entry {
        let started = Date()
        var ids = Dictionary(elements.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        let controls = rows.indices.filter { ["AXButton", "AXPopUpButton", "AXRadioButton"].contains(rows[$0]["role"] as? String ?? "") }
        func frame(_ entry: Entry) -> CGRect? {
            guard let f = entry["frame"] as? [String: Double], let x=f["x"], let y=f["y"], let w=f["width"], let h=f["height"] else { return nil }
            return CGRect(x:x,y:y,width:w,height:h)
        }
        func box(_ f: CGRect) -> [String:Double] { ["x":f.minX,"y":f.minY,"width":f.width,"height":f.height] }
        var output: [Entry] = []
        var resolved = 0
        for candidate in candidates {
            guard candidate["textSource"] as? String == "AXTitle" else { output.append(candidate); continue }
            let owner = candidate["node"] as! Int
            var ancestors: [Int] = [], p: Int? = owner
            while let id = p { ancestors.append(id); p = rows[id]["parent"] as? Int }
            let classes = ancestors.flatMap { rows[$0]["domClasses"] as? [String] ?? [] }
            let internalText = (rows[owner]["surfaceKind"] as? String == "sidebar" && rows[owner]["role"] as? String == "AXRadioButton") || (rows[owner]["role"] as? String == "AXButton" && classes.contains("notion-code-block"))
            verifyTextParents = classes.contains("notion-table-view-cell")
            // These roles/classes are already collected. Do not query classes
            // on every control or infer document tabs from screen coordinates.
            let documentTab = rows[owner]["role"] as? String == "AXRadioButton"
                && ancestors.dropFirst().contains { rows[$0]["role"] as? String == "AXTabGroup" }
                && classes.contains("notion-desktop-drag-area")
            let ownerFrame = frame(rows[owner])!
            let neighbors = rows[owner]["surfaceKind"] as? String == "tabbar" ? controls.filter { $0 != owner && frame(rows[$0]).map { ownerFrame.contains($0) } == true }.map { elements[$0] } : []
            let before = queryCount
            let found = resolve(elements[owner], header: classes.contains("notion-table-view-header-row"), internalText: internalText, neighbors: neighbors, deadline: deadline, documentTab: documentTab)
            rows[owner]["controlTextResolution"] = ["status":found.status,"complete":found.complete,"calls":queryCount-before,"textCount":found.texts.count,"chromiumInternalPath":found.internalTextAttempted]
            // Never replace a whole control with a partial private-tree walk.
            guard found.complete, !found.texts.isEmpty else {
                if found.status == "empty_native_text_range" {
                    rows[owner]["decision"] = "excluded"
                    rows[owner]["decisionReason"] = "empty_native_text_range"
                } else { output.append(candidate) }
                continue
            }
            resolved += 1
            rows[owner]["decision"] = "excluded"
            rows[owner]["decisionReason"] = "represented_by_recovered_static_text"
            for text in found.texts {
                if let existing = ids[text.element], output.contains(where: { $0["node"] as? Int == existing }) || candidates.contains(where: { $0["node"] as? Int == existing && $0["textSource"] as? String != "AXTitle" }) { continue }
                let id = ids[text.element] ?? rows.count
                var row: Entry = ["id":id,"role":"AXStaticText","value":text.value,"title":text.title,"frame":box(text.frame),"controlTextOwner":owner,"textDiscovery":text.method,"recoveredText":text.source]
                row["ownershipParentFrames"] = text.parentFrames
                if let parent=text.parent, let parentID=ids[parent] { row["parent"] = parentID }
                for key in ["surfaceKind","surfaceViewport","onscreenSelection"] { row[key] = rows[owner][key] }
                let reason = filterTiny && (text.frame.width <= 1 || text.frame.height <= 1) ? "text_extent_at_most_1pt" : (!text.frame.intersects(ownerFrame) ? "text_outside_owning_control" : "selected_recovered_static_text")
                row["decision"] = reason.hasPrefix("selected_") ? "selected" : "excluded"
                row["decisionReason"] = reason
                if id == rows.count { rows.append(row); elements.append(text.element); ids[text.element] = id } else { rows[id].merge(row, uniquingKeysWith: { _, new in new }) }
                guard reason.hasPrefix("selected_") else { continue }
                output.append(["node":id,"text":text.source,"box":box(text.frame),"textSource":text.value.isEmpty ? "AXStringForTextMarkerRange" : "AXValue","controlTextOwner":owner,"boxKind":"node_frame","selectionReason":reason,"uncertainty":"Native StaticText frame; glyph visibility unverified"])
            }
        }
        candidates = output
        return ["resolvedControls":resolved,"calls":queryCount,"elapsed":Date().timeIntervalSince(started),"parentValidationCalls":parentValidationCalls,"parentValidationSeconds":parentValidationSeconds]
    }
}
