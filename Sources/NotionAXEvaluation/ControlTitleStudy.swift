import AppKit
import ApplicationServices

// Opt-in stage-2 research for control-title text recovery and query costs.
// The internal-tree diagnostic below is specific to Chromium 156 marker
// serialization. It is kept separate from candidate recovery routes.
final class ControlTitleStudy: AXTextAccess {

    func prepare(activation: String) throws {
        guard AXIsProcessTrusted(),
              let process = NSRunningApplication.runningApplications(withBundleIdentifier: "notion.id").first else {
            throw NSError(domain: "Accessibility permission or Notion unavailable", code: 1)
        }
        let keys: [String]
        switch activation {
        case "none": keys = []
        case "manual": keys = ["AXManualAccessibility"]
        case "enhanced": keys = ["AXEnhancedUserInterface"]
        case "both": keys = ["AXManualAccessibility", "AXEnhancedUserInterface"]
        default: throw NSError(domain: "Invalid activation mode", code: 1)
        }
        let app = AXUIElementCreateApplication(process.processIdentifier)
        var errors: [String: Int32] = [:]
        for key in keys {
            errors[key] = AXUIElementSetAttributeValue(app, key as CFString, kCFBooleanTrue).rawValue
        }
        // Electron 45 debounces screen-reader mode activation for two seconds.
        // Prepare before replay so its document-URL lookup can see the WebArea.
        if !keys.isEmpty { Thread.sleep(forTimeInterval: 2.5) }
        print(String(decoding: try JSONSerialization.data(withJSONObject: errors), as: UTF8.self))
        if errors["AXManualAccessibility"].map({ $0 != 0 }) == true {
            throw NSError(domain: "AXManualAccessibility activation failed", code: 1)
        }
    }

    func inspect(_ element: AXUIElement, origin: AXUIElement, control: CGRect) -> Entry {
        let data = many(element, ["AXRole", "AXTitle", "AXValue", "AXFrame", "AXParent", "ChromeAXNodeId"])
        let frame = asRect(data["AXFrame"] as CFTypeRef?)
        let anchorTitle = data["AXTitle"] as? String ?? ""
        let anchorValue = data["AXValue"] as? String ?? ""
        let role = data["AXRole"] as? String ?? ""
        let directParent = asElement(data["AXParent"] as CFTypeRef?)
        let same = CFEqual(element, origin)
        var result: Entry = [
            "role": role, "title": anchorTitle, "value": anchorValue, "nativeID": data["ChromeAXNodeId"] as? String ?? "", "frame": rectArray(frame), "same": same,
            "parentIsControl": directParent.map { CFEqual($0, origin) } ?? false
        ]
        if role == "AXStaticText", let frame {
            result["centerInControl"] = control.insetBy(dx: -1, dy: -1).contains(CGPoint(x: frame.midX, y: frame.midY))
            result["intersectsControl"] = control.intersects(frame)
            if let range = param(element, "AXTextMarkerRangeForUIElement", element),
               let full = param(element, "AXStringForTextMarkerRange", range) as? String {
                result["fullText"] = full
                if !full.isEmpty {
                    var indexes = CFRange(location: 0, length: full.utf16.count)
                    let bounds = AXValueCreate(.cfRange, &indexes).flatMap { asRect(param(element,"AXBoundsForRange",$0)) }
                    result["bounds"] = rectArray(bounds)
                }
            }
        }
        return result
    }

    func probe(_ element: AXUIElement, title: String, frame: CGRect, web: AXUIElement, neighbors: [AXUIElement]) -> Entry {
        var observations = [String: Any]()
        var checked: [(AXUIElement, Entry)] = []
        func lookup(_ anchor: AXUIElement) -> Entry {
            if let existing = checked.first(where: { CFEqual($0.0, anchor) }) { return existing.1 }
            let info = inspect(anchor, origin: element, control: frame)
            checked.append((anchor, info))
            return info
        }
        func observe(_ label: String, _ raw: CFTypeRef?, source: AXUIElement? = nil) {
            for (suffix, marker) in endpoints(raw) {
                if let anchor = asElement(param(source ?? element, "AXUIElementForTextMarker", marker)) {
                    let name = label + suffix
                observations[name] = lookup(anchor)
                if let parent = asElement(attr(anchor, "AXParent")),
                   attr(parent, "AXRole") as? String == "AXStaticText" {
                    observations[name + ".parent"] = lookup(parent)
                }
                }
            }
        }
        let relationshipNames = [
            "AXChildren", "AXChildrenInNavigationOrder", "AXVisibleChildren", "AXOwns", "AXLinkedUIElements",
            "AXTitleUIElement", "AXLabelUIElements", "AXLabelledBy", "AXServesAsTitleForUIElements", "AXContents"
        ]
        let relationshipValues = many(element, relationshipNames)
        for key in relationshipNames {
            guard let raw = relationshipValues[key] else { continue }
            if let elements = raw as? [AXUIElement], !elements.isEmpty {
                observations[key] = elements.prefix(24).map(lookup)
            } else if let linked = asElement(raw as CFTypeRef) {
                observations[key] = [lookup(linked)]
            }
        }
        for (index, neighbor) in neighbors.enumerated() {
            guard let raw = param(neighbor, "AXTextMarkerRangeForUIElement", neighbor) else { continue }
            for (suffix, marker) in endpoints(raw) {
                for key in ["AXPreviousTextMarkerForTextMarker", "AXPreviousLineStartTextMarkerForTextMarker"] {
                    observe("neighborControl.\(index)" + suffix + "." + key, param(element, key, marker))
                }
            }
        }
        let range = param(element, "AXTextMarkerRangeForUIElement", element)
        observe("elementRange", range)
        if let range, CFGetTypeID(range) == AXTextMarkerRangeGetTypeID() {
            let whole = range as! AXTextMarkerRange
            let start = AXTextMarkerRangeCopyStartMarker(whole)
            let end = AXTextMarkerRangeCopyEndMarker(whole)
            observations["markerEndpointsCFEqual"] = CFEqual(start, end)
            observations["markerEndpointBytesEqual"] = sameMarkerBytes(start, end)
        }
        if let marker = endpoints(range).first?.1 {
            for key in ["AXTextMarkerNodeDebugDescription", "AXTextMarkerDebugDescription", "AXTextMarkerRangeDebugDescription"] {
                if let description = param(element, key, key.contains("Range") ? range! : marker) as? String {
                    observations[key] = description
                }
            }
        }
        if let marker = endpoints(range).first?.1,
           let description = observations["AXTextMarkerNodeDebugDescription"] as? String {
            let tree = internalTree(element, marker, description, lookup: lookup)
            observations["internalTree"] = tree.nodes
            observations["internalTreeComplete"] = tree.complete
        }
        let attributes = [
            "AXNextLineEndTextMarkerForTextMarker", "AXPreviousLineStartTextMarkerForTextMarker",
            "AXLineTextMarkerRangeForTextMarker", "AXLeftLineTextMarkerRangeForTextMarker", "AXRightLineTextMarkerRangeForTextMarker",
            "AXNextTextMarkerForTextMarker", "AXPreviousTextMarkerForTextMarker",
            "AXNextWordEndTextMarkerForTextMarker", "AXPreviousWordStartTextMarkerForTextMarker",
            "AXLeftWordTextMarkerRangeForTextMarker", "AXRightWordTextMarkerRangeForTextMarker",
            "AXSentenceTextMarkerRangeForTextMarker", "AXParagraphTextMarkerRangeForTextMarker",
            "AXNextParagraphEndTextMarkerForTextMarker", "AXPreviousParagraphStartTextMarkerForTextMarker",
            "AXStyleTextMarkerRangeForTextMarker"
        ]
        for (suffix, marker) in endpoints(range) {
            for name in attributes {
                observe(name + suffix, param(element,name,marker))
            }
        }
        let movement: [(String, String, String, [String])] = [
            ("fromPreviousCharacter", ".start", "AXPreviousTextMarkerForTextMarker",
                ["AXNextTextMarkerForTextMarker", "AXNextLineEndTextMarkerForTextMarker", "AXNextWordEndTextMarkerForTextMarker", "AXLineTextMarkerRangeForTextMarker"]),
            ("fromNextCharacter", ".end", "AXNextTextMarkerForTextMarker",
                ["AXPreviousTextMarkerForTextMarker", "AXPreviousLineStartTextMarkerForTextMarker", "AXPreviousWordStartTextMarkerForTextMarker", "AXLineTextMarkerRangeForTextMarker"]),
            ("fromPreviousLine", ".start", "AXPreviousLineStartTextMarkerForTextMarker",
                ["AXNextTextMarkerForTextMarker", "AXNextLineEndTextMarkerForTextMarker", "AXNextParagraphEndTextMarkerForTextMarker", "AXRightLineTextMarkerRangeForTextMarker"]),
            ("fromNextLine", ".end", "AXNextLineEndTextMarkerForTextMarker",
                ["AXPreviousTextMarkerForTextMarker", "AXPreviousLineStartTextMarkerForTextMarker", "AXPreviousParagraphStartTextMarkerForTextMarker", "AXLeftLineTextMarkerRangeForTextMarker"])
        ]
        for (label, endpoint, outward, inward) in movement {
            guard let initial = endpoints(range).first(where: { $0.0 == endpoint })?.1,
                  let neighbour = param(element, outward, initial),
                  CFGetTypeID(neighbour) == AXTextMarkerGetTypeID() else { continue }
            for name in inward {
                let returned = param(element, name, neighbour)
                observe(label + "." + name, returned)
                if name == "AXNextTextMarkerForTextMarker" || name == "AXPreviousTextMarkerForTextMarker",
                   let returned, CFGetTypeID(returned) == AXTextMarkerGetTypeID() {
                    observe(label + "." + name + ".twice", param(element, name, returned))
                }
            }
        }
        for key in ["AXStartTextMarker", "AXEndTextMarker"] {
            observe(key, attr(element,key))
        }
        observe("webRangeForElement", param(web, "AXTextMarkerRangeForUIElement", element), source: web)
        observe("AXTextMarkerRangeForLine", param(element, "AXTextMarkerRangeForLine", 0 as NSNumber))
        var searchBounds = frame
        if let rect = AXValueCreate(.cgRect, &searchBounds) {
            for key in ["AXStartTextMarkerForBounds", "AXEndTextMarkerForBounds"] {
                observe(key, param(web,key,rect), source: web)
            }
        }
        let search: [String: Any] = [
            "AXSearchKey":"AXStaticTextSearchKey", "AXSearchText":title, "AXVisibleOnly":true,
            "AXDirection":"AXDirectionNext", "AXResultsLimit":48
        ]
        for (label, root) in [("controlSearch", element), ("webSearch", web)] {
            let results = param(root,"AXUIElementsForSearchPredicate",search as CFDictionary) as? [AXUIElement] ?? []
            let matches = results.map(lookup).filter { $0["centerInControl"] as? Bool == true }
            if !matches.isEmpty { observations[label] = matches }
        }
        return observations
    }
    func benchmark(_ element: AXUIElement, title: String, frame: CGRect, neighbors: [AXUIElement]) -> Entry {
        let routes = ["opaque-owned-node", "internal-owned-node", "opaque-owned", "owned-internal", "opaque-hybrid", "hybrid-internal", "line-range", "previous-line-start",
                      "next-line-end", "previous-char-next-char", "previous-char-return",
                      "next-char-previous-char", "neighbor-control", "internal-tree", "internal-owned"]
        func candidate(_ anchor: AXUIElement, requireTitleMatch: Bool = true, internallyOwned: Bool = false, includeRangeValidation: Bool = true) -> Entry {
            if CFEqual(anchor,element) { return ["status":"same_control"] }
            var textElement = anchor
            var observed = many(anchor, ["AXRole", "AXTitle", "AXValue", "AXFrame", "AXParent", "ChromeAXNodeId"])
            guard observed["AXRole"] as? String == "AXStaticText" else { return ["status":"not_static_text"] }
            if !internallyOwned, let parent = asElement(observed["AXParent"] as CFTypeRef?) {
                let parentData = many(parent, ["AXRole", "AXTitle", "AXValue", "AXFrame", "AXParent", "ChromeAXNodeId"])
                if parentData["AXRole"] as? String == "AXStaticText" {
                    observed = parentData
                    textElement = parent
                }
            }
            guard observed["AXRole"] as? String == "AXStaticText" else { return ["status":"not_static_text"] }
            let label = observed["AXValue"] as? String ?? ""
            let text = label.isEmpty ? observed["AXTitle"] as? String ?? "" : label
            var output: Entry = ["text":text, "nativeID":observed["ChromeAXNodeId"] as? String ?? "", "frame":rectArray(asRect(observed["AXFrame"] as CFTypeRef?)),
                                "status":"different_text"]
            guard !text.isEmpty else { return ["status":"empty_text"] }
            if requireTitleMatch {
                guard text == title else { return output }
            } else if internallyOwned {
                output["ownerVerified"] = true
                output["ownershipSource"] = "internal_child_or_label_relation"
            } else {
                var ancestor = asElement(observed["AXParent"] as CFTypeRef?)
                var owned = false
                for _ in 0..<16 {
                    guard let parent = ancestor else { break }
                    if CFEqual(parent, element) { owned = true; break }
                    let parentData = many(parent, ["AXRole", "AXParent"])
                    let role = parentData["AXRole"] as? String ?? ""
                    if ["AXButton", "AXPopUpButton", "AXRadioButton", "AXWebArea", "AXWindow"].contains(role) { break }
                    ancestor = asElement(parentData["AXParent"] as CFTypeRef?)
                }
                guard owned else { output["status"] = "different_owner"; return output }
                output["ownerVerified"] = true
            }
            guard let box = asRect(observed["AXFrame"] as CFTypeRef?), box.width > 1, box.height > 1,
                  box.intersects(frame) else { output["status"]="outside_control"; return output }
            if !includeRangeValidation {
                output["status"] = "matched"
                output["rangeValidation"] = "independent_probe_after_timing"
                return output
            }
            guard let range = param(textElement, "AXTextMarkerRangeForUIElement", textElement),
                  let fullText = param(textElement, "AXStringForTextMarkerRange", range) as? String,
                  fullText == text else {
                output["status"] = "full_text_mismatch"
                return output
            }
            var indexes = CFRange(location: 0, length: fullText.utf16.count)
            guard let argument = AXValueCreate(.cfRange, &indexes),
                  let bounds = asRect(param(textElement, "AXBoundsForRange", argument)),
                  bounds.width > 0, bounds.height > 0 else {
                output["status"] = "text_bounds_unavailable"
                return output
            }
            output["bounds"] = rectArray(bounds)
            output["status"] = "matched"
            return output
        }
        func execute(_ route: String) -> Entry {
            guard let range = param(element,"AXTextMarkerRangeForUIElement",element),
                  CFGetTypeID(range)==AXTextMarkerRangeGetTypeID() else { return ["status":"range_unavailable"] }
            let markers = range as! AXTextMarkerRange
            let start = AXTextMarkerRangeCopyStartMarker(markers)
            let end = AXTextMarkerRangeCopyEndMarker(markers)
            var target: CFTypeRef?
            func markerResult(_ marker: CFTypeRef?) -> Entry? {
                guard let marker,
                      let anchor = asElement(param(element, "AXUIElementForTextMarker", marker)) else { return nil }
                let result = candidate(anchor, requireTitleMatch: !["opaque-owned", "opaque-owned-node", "owned-internal"].contains(route),
                                       includeRangeValidation: !route.hasSuffix("-node"))
                return result["status"] as? String == "matched" ? result : nil
            }
            func neighborResult() -> Entry? {
                for neighbor in neighbors {
                    guard let otherRange = param(neighbor, "AXTextMarkerRangeForUIElement", neighbor) else { continue }
                    for (_, marker) in endpoints(otherRange) {
                        for key in ["AXPreviousTextMarkerForTextMarker", "AXPreviousLineStartTextMarkerForTextMarker"] {
                            if let result = markerResult(param(element, key, marker)) { return result }
                        }
                    }
                }
                return nil
            }
            func internalResult() -> Entry {
                guard let description = param(element, "AXTextMarkerNodeDebugDescription", start) as? String else {
                    return ["status":"debug_unavailable"]
                }
                var matches: [Entry] = []
                let tree = internalTree(element, start, description) { anchor in
                    let result = candidate(anchor, requireTitleMatch: !["owned-internal", "internal-owned", "internal-owned-node"].contains(route),
                                           internallyOwned: true, includeRangeValidation: !route.hasSuffix("-node"))
                    if result["status"] as? String == "matched" { matches.append(result) }
                    return result
                }
                if var result = matches.first {
                    result["textNodes"] = matches
                    result["internalTreeComplete"] = tree.complete
                    return result
                }
                return ["status":"no_match", "internalNodes":tree.nodes.count, "complete":tree.complete]
            }
            switch route {
            case "opaque-owned-node", "opaque-owned", "owned-internal", "opaque-hybrid", "hybrid-internal":
                if !sameMarkerBytes(start, end) {
                    for (endpoint, outward, inward) in [
                        (start, "AXPreviousTextMarkerForTextMarker", "AXNextTextMarkerForTextMarker"),
                        (end, "AXNextTextMarkerForTextMarker", "AXPreviousTextMarkerForTextMarker")
                    ] {
                        guard var position = param(element, outward, endpoint) else { continue }
                        for _ in 0..<2 {
                            guard let moved = param(element, inward, position) else { break }
                            position = moved
                            if let result = markerResult(position) { return result }
                        }
                    }
                    if let line = param(element, "AXLineTextMarkerRangeForTextMarker", start) {
                        for (_, marker) in endpoints(line) {
                            if let result = markerResult(marker) { return result }
                        }
                    }
                    if let result = markerResult(param(element, "AXNextLineEndTextMarkerForTextMarker", start)) {
                        return result
                    }
                }
                if let result = neighborResult() { return result }
                if route == "hybrid-internal" || route == "owned-internal" { return internalResult() }
                return ["status":sameMarkerBytes(start,end) ? "empty_marker_range" : "no_match"]
            case "line-range":
                target = param(element,"AXLineTextMarkerRangeForTextMarker",start)
            case "previous-line-start":
                target = param(element,"AXPreviousLineStartTextMarkerForTextMarker",end)
            case "next-line-end":
                target = param(element,"AXNextLineEndTextMarkerForTextMarker",start)
            case "previous-char-next-char":
                if let outside = param(element,"AXPreviousTextMarkerForTextMarker",start) {
                    target = param(element,"AXNextTextMarkerForTextMarker",outside)
                }
            case "previous-char-return":
                guard var position = param(element, "AXPreviousTextMarkerForTextMarker", start) else {
                    return ["status":"previous_character_unavailable"]
                }
                for _ in 0..<2 {
                    guard let next = param(element, "AXNextTextMarkerForTextMarker", position) else { break }
                    position = next
                    if let anchor = asElement(param(element, "AXUIElementForTextMarker", position)) {
                        let result = candidate(anchor)
                        if result["status"] as? String == "matched" { return result }
                    }
                }
                return ["status":"no_match"]
            case "neighbor-control":
                return neighborResult() ?? ["status":"no_match"]
            case "next-char-previous-char":
                if let outside = param(element,"AXNextTextMarkerForTextMarker",end) {
                    target = param(element,"AXPreviousTextMarkerForTextMarker",outside)
                }
            case "internal-tree", "internal-owned", "internal-owned-node":
                return internalResult()
            default:
                return ["status":"unknown_route"]
            }
            guard let marker = endpoints(target).first?.1,
                  let anchor = asElement(param(element,"AXUIElementForTextMarker",marker)) else { return ["status":"anchor_unavailable"] }
            return candidate(anchor)
        }

        var report: Entry = [:]
        var samples: [String: [[String: Any]]] = [:]
        for round in 0..<7 {
            let ordered = round % 2 == 0 ? routes : Array(routes.reversed())
            for route in ordered {
                let callsBefore = queryCount
                let started = DispatchTime.now().uptimeNanoseconds
                let result = execute(route)
                let elapsed = (DispatchTime.now().uptimeNanoseconds - started) / 1000
                samples[route,default:[]].append(["us":elapsed,"calls":queryCount-callsBefore])
                report[route] = result
            }
        }
        return ["results":report, "samples":samples]
    }

    func collect(rows: [[String: Any]], elements: [AXUIElement],
                        candidates: [[String: Any]]) -> [String: Any] {
        let started = DispatchTime.now().uptimeNanoseconds
        var results: [[String: Any]] = []
        let requestedCount = candidates.filter { $0["textSource"] as? String == "AXTitle" }.count
        for candidate in candidates where candidate["textSource"] as? String == "AXTitle" {
            if DispatchTime.now().uptimeNanoseconds - started > 10_000_000_000 { break }
            guard let index = candidate["node"] as? Int,
                  let title = candidate["text"] as? String,
                  let raw = rows[index]["frame"] as? [String: Double],
                  let x = raw["x"], let y = raw["y"],
                  let width = raw["width"], let height = raw["height"] else { continue }
            let element = elements[index]
            var root = index
            while rows[root]["role"] as? String != "AXWebArea", let parent = rows[root]["parent"] as? Int {
                root = parent
            }
            let control = CGRect(x: x, y: y, width: width, height: height)
            let before = DispatchTime.now().uptimeNanoseconds
            let neighbors = rows.compactMap { row -> AXUIElement? in
                guard let other = row["id"] as? Int, other != index,
                      ["AXButton", "AXPopUpButton", "AXRadioButton"].contains(row["role"] as? String ?? ""),
                      row["surfaceKind"] as? String == rows[index]["surfaceKind"] as? String,
                      let box = row["frame"] as? [String: Double],
                      let x = box["x"], let y = box["y"],
                      let width = box["width"], let height = box["height"] else { return nil }
                let otherFrame = CGRect(x: x, y: y, width: width, height: height)
                return width > 1 && height > 1 && control.contains(otherFrame) ? elements[other] : nil
            }
            // Time the opaque-marker route before the exhaustive diagnostics.
            // Earlier control queries and the baseline tree may already be warm.
            let measurements = benchmark(element, title: title, frame: control, neighbors: Array(neighbors.prefix(3)))
            let observations = probe(element, title: title, frame: control, web: elements[root], neighbors: Array(neighbors.prefix(3)))
            results.append([
                "node": index, "role": rows[index]["role"] ?? "",
                "surface": rows[index]["surfaceKind"] ?? "content",
                "title": title, "frame": rectArray(control),
                "nativeID": attr(element, "ChromeAXNodeId") as? String ?? "",
                "elapsedUs": (DispatchTime.now().uptimeNanoseconds - before) / 1000,
                "observations": observations, "benchmark": measurements
            ])
        }
        return [
            "studyVersion": "control-text-v6", "scope": "final_selected_AXTitle",
            "elapsedUs": (DispatchTime.now().uptimeNanoseconds - started) / 1000,
            "requestedCount": requestedCount, "truncated": results.count != requestedCount, "rows": results
        ]
    }
}
