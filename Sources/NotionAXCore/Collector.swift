import AppKit
import ApplicationServices

package func recordAXQuery() {
    let key = "rearview.ax.queryCount"
    Thread.current.threadDictionary[key] = (Thread.current.threadDictionary[key] as? Int ?? 0) + 1
}
package func get(_ e: AXUIElement, _ key: String) -> CFTypeRef? {
    if (Thread.current.threadDictionary["rearview.ax.cancellation"] as? AXCancellation)?.isCancelled == true { return nil }
    recordAXQuery()
    var value: CFTypeRef?
    let result=AXUIElementCopyAttributeValue(e, key as CFString, &value)
    recordAXResult(key,result)
    return result == .success ? value : nil
}
package func frame(_ e: AXUIElement) -> CGRect? {
    guard let p = get(e, "AXPosition"), let s = get(e, "AXSize"), CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
    var point = CGPoint.zero, size = CGSize.zero
    guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
    return CGRect(origin: point, size: size)
}
package func position(_ e: AXUIElement) -> CGPoint? {
    guard let value = get(e, "AXPosition"), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    var point = CGPoint.zero
    return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
}
// Product policy, not proof of invisibility: Chromium can clamp fully clipped
// nodes to a 1-unit edge rectangle. Even a genuinely visible <=1pt text sliver
// is not useful translation input. Filter using the already-read frame to avoid
// additional cross-process AX range queries. Units are screen points (1pt = 2px
// on a 2x display), not pixels. Revisit this threshold if tiny fragments become
// useful; preserve the raw node and exclusion reason for that investigation.
// Rationale: https://github.com/chromium/chromium/blob/main/docs/accessibility/browser/offscreen.md
package let minimumUsefulTextExtent: CGFloat = 1
package func isTinyTextFrame(_ frame: CGRect) -> Bool {
    frame.width <= minimumUsefulTextExtent || frame.height <= minimumUsefulTextExtent
}

// Notion parks inactive tab WebAreas outside the tracked window. Their frames
// can overlap its edge by 1pt. Check the window, not the user's crop, so a
// narrow crop in the tab bar does not suppress the active document's metadata.
package func isParkedNotionDocument(_ frame: CGRect, window: CGRect) -> Bool {
    guard !frame.isEmpty, !window.isEmpty,
          [frame.minX, frame.minY, frame.width, frame.height,
           window.minX, window.minY, window.width, window.height].allSatisfy(\.isFinite) else { return false }
    let overlap = frame.intersection(window)
    return overlap.isNull || isTinyTextFrame(overlap)
}

package func rect(_ r: CGRect) -> [String: Double] { ["x":r.minX,"y":r.minY,"width":r.width,"height":r.height] }

package enum AXCollector {
static func collect(_ request: AXExtractionRequest, window: AXUIElement, cancellation: AXCancellation, prefetch: (([AXUIElement]) -> Void)? = nil,
                    scrollAnchors: (([(AXUIElement, CGPoint)]) -> Void)? = nil) throws -> AXExtractionSnapshot {
 let before = request.windowFrame
    func selectionViewport(_ row: [String:Any]) -> CGRect {
        let surface = (row["surfaceViewport"] as? [String:Double]).map {
            CGRect(x:$0["x"]!,y:$0["y"]!,width:$0["width"]!,height:$0["height"]!)
        }
        return SelectionViewport.region(surface:surface,content:request.selectionRegion,window:before).intersection(request.selectionRegion)
    }
    let started = Date(), deadline = started.addingTimeInterval(15)
    Thread.current.threadDictionary["rearview.ax.queryCount"] = 0
    defer { Thread.current.threadDictionary.removeObject(forKey:"rearview.ax.queryCount") }
    Thread.current.threadDictionary["rearview.ax.cancellation"] = cancellation
    defer { Thread.current.threadDictionary.removeObject(forKey:"rearview.ax.cancellation") }
    var sidebarBoundsQueries = 0
    let pruningEnabled = request.pruneOffscreenBranches && !request.collectParentTextDiagnostics
    let captureViewport = before.intersection(request.selectionRegion)
    var prunedBranches = 0
    var outsideValueQueries = 0
    func readSidebarBounds(_ node: AXUIElement, value: String, row: inout [String: Any]) throws {
        sidebarBoundsQueries += 1
        var range = CFRange(location:0,length:(value as NSString).length)
        var bounds: CFTypeRef?
        try cancellation.check()
        recordAXQuery()
        let error = AXUIElementCopyParameterizedAttributeValue(node,"AXBoundsForRange" as CFString,AXValueCreate(.cfRange,&range)!,&bounds)
        recordAXResult("AXBoundsForRange",error)
        row["boundsForFullRangeError"] = error.rawValue
        if let bounds, CFGetTypeID(bounds) == AXValueGetTypeID() { var r = CGRect.zero; if AXValueGetValue(bounds as! AXValue,.cgRect,&r) { row["boundsForFullRange"] = rect(r) } }
    }
    let omitUnusedAttributes = !request.collectParentTextDiagnostics
    let traversalStarted = ContinuousClock.now
    let controlRoles = ["AXButton", "AXPopUpButton", "AXRadioButton"]
    var deferredValues: [Int] = []
    var requiredTextOwners = Set<Int>()
    var elements: [AXUIElement] = []
    var parkedDocumentCount = 0
    let investigator = RangeInvestigator(deadline: deadline, cancellation: cancellation)
    var stack: [(node: AXUIElement, depth: Int, parent: Int?, insideWebArea: Bool, pruningScope: AXBranchPruning.Scope)] = [(window,0,nil,false,.body)], seen: [AXUIElement] = [], rows: [[String:Any]] = [], candidates: [[String:Any]] = []
    while let (node,depth,parent,insideWebArea,inheritedScope) = stack.popLast() {
        try cancellation.check()
        if rows.count >= 3500 || Date() > deadline { stack.append((node,depth,parent,insideWebArea,inheritedScope)); break }
        if seen.contains(where:{CFEqual($0,node)}) { continue }; seen.append(node)
        let n = rows.count
        let role = get(node,"AXRole") as? String ?? ""
        let isWebArea = role == "AXWebArea"
        let needsTitle = !omitUnusedAttributes || isWebArea || controlRoles.contains(role)
        var title = needsTitle ? get(node,"AXTitle") as? String ?? "" : ""
        let isRootDocument = isWebArea && !insideWebArea && title != "Tab Bar"
        let rootDocumentFrame = isRootDocument ? frame(node) : nil
        if let rootDocumentFrame, isParkedNotionDocument(rootDocumentFrame, window: before) {
            parkedDocumentCount += 1
            continue
        }
        try cancellation.check()
        var row: [String:Any] = ["id":n,"role":role,"title":title,"attributes":[String](),"parameterizedAttributes":[String]()]
        if role == "AXTextArea" && !request.collectParentTextDiagnostics { row["valueCollection"] = "omitted_parent_value" }
        if let parent { row["parent"] = parent }
        if role == "AXWebArea", title != "Tab Bar", let url = get(node,"AXURL") as? URL {
            row["documentURL"] = url.absoluteString
        }
        // Semantic layout classes are needed only on container groups. Preserve
        // them for auditing the timeline-only rule; never infer z-order generally.
        if role == "AXGroup" {
            // One metadata request replaces the old class-only request. Cache
            // the real subrole; an advertised attribute name is not its value.
            var metadata: CFArray?
            try cancellation.check()
            recordAXQuery()
            let metadataResult=AXUIElementCopyMultipleAttributeValues(node, ["AXDOMClassList", "AXSubrole"] as CFArray, [], &metadata)
            recordAXResult("AXDOMClassList+AXSubrole",metadataResult)
            if metadataResult == .success,
               let values = metadata as? [Any], values.count == 2 {
                row["domClasses"] = values[0] as? [String] ?? []
                if let subrole = values[1] as? String { row["subrole"] = subrole }
            } else {
                row["domClasses"] = get(node,"AXDOMClassList") as? [String] ?? []
                row["subrole"] = get(node,"AXSubrole") as? String
            }
        }
        let inheritedMath = parent.flatMap { rows[$0]["mathOwner"] as? Int }
        if let inheritedMath { row["mathOwner"] = inheritedMath }
        else if row["subrole"] as? String == "AXDocumentMath" || (row["domClasses"] as? [String] ?? []).contains("notion-equation-block") {
            row["mathOwner"] = n
            row["mathKind"] = row["subrole"] as? String == "AXDocumentMath" ? "inline" : "block"
        }
        // Keep broad AX text/ownership observations for research, but formula
        // geometry is unused: no frame, full-range bounds or line API requests.
        // See AX_MATH_POLICY.md before changing this exclusion or migrating it.
        let excludedMath = row["mathOwner"] != nil
        let nodeFrame = excludedMath ? nil : (isRootDocument ? rootDocumentFrame : frame(node))
        let tinyFrame = nodeFrame.map(isTinyTextFrame) == true
        // Some control titles are used to group their visible text children.
        // Retain math observations and the original tiny-text classification.
        if !needsTitle {
            if excludedMath || tinyFrame {
                title = get(node,"AXTitle") as? String ?? ""
                row["title"] = title
            } else {
                row["titleCollection"] = "omitted_unused_attribute"
            }
        }
        // Visible UI surfaces have independent viewports. Reuse the observed
        // AX classes/frames: no new queries and no global window-wide selection.
        // In particular, a page preview is a sibling of the main document, not
        // a child whose bounds should be intersected with the main viewport.
        if let parent, let surface = rows[parent]["surfaceViewport"] {
            row["surfaceViewport"] = surface
            row["surfaceKind"] = rows[parent]["surfaceKind"]
        }
        let nodeClasses = row["domClasses"] as? [String] ?? []
        // Observed Notion UI roots: tab titles live in a separate WebArea;
        // breadcrumbs live in notion-topbar. Their own frames define selection,
        // so enabling them does not widen the document content viewport.
        let surfaceKind: String? = role == "AXWebArea" && title == "Tab Bar" ? "tabbar" :
            nodeClasses.contains("notion-topbar") ? "topbar" :
            nodeClasses.contains("notion-peek-renderer") ? "preview" :
            nodeClasses.contains(where:{["notion-sidebar","notion-sidebar-container"].contains($0)}) ? "sidebar" : nil
        if let surfaceKind, let nodeFrame {
            let surface = nodeFrame.intersection(before)
            row["surfaceViewport"] = rect(surface.isNull ? .zero : surface)
            row["surfaceKind"] = surfaceKind
        }
        let nodeViewport = selectionViewport(row)
        let outsideStaticText = role == "AXStaticText" &&
            !excludedMath && !nodeViewport.isNull && nodeFrame.map {
                !$0.isEmpty && [$0.minX, $0.minY, $0.width, $0.height].allSatisfy(\.isFinite) && !$0.intersects(nodeViewport)
            } == true
        let deferValue = request.visibleFirst && !request.collectParentTextDiagnostics && outsideStaticText
        if outsideStaticText && !deferValue { outsideValueQueries += 1 }
        let omitValue = omitUnusedAttributes && !excludedMath && !tinyFrame &&
            row["surfaceKind"] as? String != "sidebar" &&
            (role == "AXGroup" || role == "AXWindow" || role == "AXWebArea")
        if omitValue { row["valueCollection"] = "omitted_unused_attribute" }
        let value = omitValue || deferValue || (role == "AXTextArea" && !request.collectParentTextDiagnostics)
            ? "" : get(node, "AXValue") as? String ?? ""
        row["value"] = value
        if deferValue {
            deferredValues.append(n)
            row["valueCollection"] = "omitted_outside_viewport"
        }
        let excludedTinyText = (!value.isEmpty || !title.isEmpty) && nodeFrame.map(isTinyTextFrame) == true
        let reason: String
        if excludedMath { reason = "math_translation_excluded" }
        else if value.isEmpty { reason = "no_text_value" }
        else if excludedTinyText { reason = "text_extent_at_most_1pt" }
        else if role != "AXStaticText" { reason = "role_not_static_text" }
        else if nodeFrame == nil { reason = "frame_unavailable" }
        else if !nodeFrame!.intersects(nodeViewport) { reason = "outside_viewport" }
        else { reason = "selected_static_text_intersects_viewport" }
        row["decision"] = reason.hasPrefix("selected_") ? "selected" : "excluded"
        row["decisionReason"] = reason
        if excludedTinyText { row["exclusionReason"] = "text_extent_at_most_1pt" }
        if let f = nodeFrame {
            row["frame"] = rect(f)
            if role == "AXStaticText", !value.isEmpty, !excludedTinyText, f.intersects(nodeViewport) {
                candidates.append(["node":n,"text":value,"box":rect(f),"textSource":"AXValue","boxKind":"node_frame","selectionReason":reason,"uncertainty":"Full AX value; glyph visibility unverified"])
            }
        }
        if !request.visibleFirst, !excludedMath, !value.isEmpty, !excludedTinyText, row["surfaceKind"] as? String == "sidebar" {
            try readSidebarBounds(node, value: value, row: &row)
        }
        elements.append(node)
        rows.append(row)
        var pruningScope = inheritedScope
        if pruningEnabled {
            if surfaceKind != nil || excludedMath || row["subrole"] as? String == "AXApplicationDialog" {
                pruningScope = .preserve
            } else {
                pruningScope = inheritedScope.descending(into: nodeClasses, frame: nodeFrame)
            }
            if (insideWebArea || isWebArea),
               AXBranchPruning.shouldSkipChildren(role: role, classes: nodeClasses, frame: nodeFrame,
                                                 captureViewport: captureViewport, scope: pruningScope) {
                rows[n]["childrenPruned"] = true
                prunedBranches += 1
                continue
            }
        }
        let children = get(node,"AXChildren") as? [AXUIElement] ?? []
        if depth < 40 { stack.append(contentsOf:children.reversed().map{($0,depth+1,n,insideWebArea || isWebArea,pruningScope)}) }
        else if !children.isEmpty { row["depthLimitReached"] = true; rows[n] = row }
    }
    for candidate in candidates where !deferredValues.isEmpty {
        var ancestor = rows[candidate["node"] as! Int]["parent"] as? Int
        while let id = ancestor {
            if rows[id]["role"] as? String == "AXTextArea" { requiredTextOwners.insert(id) }
            ancestor = rows[id]["parent"] as? Int
        }
    }
    var restoredValues = 0
    for id in deferredValues {
        var ancestor = rows[id]["parent"] as? Int
        while let owner = ancestor {
            if requiredTextOwners.contains(owner) || controlRoles.contains(rows[owner]["role"] as? String ?? "") {
                try cancellation.check()
                rows[id]["value"] = get(elements[id], "AXValue") as? String ?? ""
                rows[id].removeValue(forKey: "valueCollection")
                restoredValues += 1
                break
            }
            ancestor = rows[owner]["parent"] as? Int
        }
    }
    let traversalDuration = traversalStarted.duration(to: .now).components
    let treeVisitedNodes = rows.count
    let traversalSeconds = Double(traversalDuration.seconds) + Double(traversalDuration.attoseconds) / 1e18
    // Second pass uses the observed tree only: no additional AX calls. Prefer
    // existing static text descendants even when fragmented by style or emoji.
    // Never deduplicate globally by string: identical labels in other rows matter.
    var hasTextDescendant = Set<Int>()
    for row in rows where row["role"] as? String == "AXStaticText" && !(row["value"] as? String ?? "").isEmpty {
        var parent = row["parent"] as? Int
        while let id = parent { hasTextDescendant.insert(id); parent = rows[id]["parent"] as? Int }
    }
    for i in rows.indices {
        if rows[i]["mathOwner"] != nil { continue }
        let role = rows[i]["role"] as? String ?? ""
        let title = rows[i]["title"] as? String ?? ""
        // Only roles observed in Notion fixtures: view tabs use AXRadioButton
        // (database-wrap-left, nodes 61/62 in the 20261108T121553Z run).
        // Do not broaden this list to unobserved control roles speculatively.
        guard ["AXButton", "AXPopUpButton", "AXRadioButton"].contains(role), !title.isEmpty else { continue }
        let reason: String
        if let f = rows[i]["frame"] as? [String: Double] {
            let box = CGRect(x:f["x"]!, y:f["y"]!, width:f["width"]!, height:f["height"]!)
            if isTinyTextFrame(box) { reason = "text_extent_at_most_1pt" }
            else if !box.intersects(selectionViewport(rows[i])) { reason = "outside_viewport" }
            else if hasTextDescendant.contains(i) { reason = "title_represented_by_static_text_descendant" }
            else {
                reason = "selected_control_title_without_static_text_descendant"
                // Experimental: a control title can exist even when its glyphs
                // are hidden (e.g. hover-only Add icon). Its frame is a control
                // area, not a measured text box. Expose both limitations, rather
                // than presenting this fallback as verified visible text.
                candidates.append(["node":i,"text":title,"box":f,"textSource":"AXTitle",
                    "boxKind":"control_frame","selectionReason":reason,
                    "uncertainty":"제목의 실제 표시 여부 미검증; 글자 박스가 아닌 컨트롤 영역"])
            }
        } else { reason = "frame_unavailable" }
        rows[i]["decision"] = reason.hasPrefix("selected_") ? "selected" : "excluded"
        rows[i]["decisionReason"] = reason
    }
    // Apply Chromium's onscreen search to actual selection, not only the study
    // sidecar. It handles ancestor clipping (gallery previews, menus), but not
    // sibling occlusion; the timeline-specific rule below remains necessary.
    // Retain the existing 1pt guard: onscreen control slivers still exist.
    let visibleSearchStarted = Date()
    var visibleSearches: [[String:Any]] = []
    var visibleRoots: [Int:(all:AXElementMembership, visible:AXElementMembership)] = [:]
    for rootID in rows.indices where rows[rootID]["role"] as? String == "AXWebArea" {
        var lists: [Bool:[AXUIElement]] = [:]
        for visibleOnly in [false,true] {
            let predicate: [String:Any] = ["AXSearchKey":"AXAnyTypeSearchKey","AXResultsLimit":10000,
                "AXVisibleOnly":visibleOnly,"AXDirection":"AXDirectionNext","AXImmediateDescendantsOnly":false]
            var found: CFTypeRef?
            let start = Date()
            try cancellation.check()
            recordAXQuery()
            let error = AXUIElementCopyParameterizedAttributeValue(elements[rootID],"AXUIElementsForSearchPredicate" as CFString,predicate as CFDictionary,&found)
            recordAXResult("AXUIElementsForSearchPredicate",error)
            guard error == .success, let matches = found as? [AXUIElement], matches.count < 10000 else {
                // An incomplete search must not masquerade as successful filtering.
                if error == .cannotComplete || error == .noValue || (error == .success && found == nil) {
                    throw AXReadinessError.visibilitySearchUnavailable(error.rawValue)
                }
                throw NSError(domain:"AX visibility search unavailable or truncated at WebArea \(rootID), visibleOnly=\(visibleOnly), error=\(error.rawValue)",code:1)
            }
            lists[visibleOnly] = matches
            visibleSearches.append(["root":rootID,"visibleOnly":visibleOnly,"count":matches.count,
                "error":error.rawValue,"elapsedMs":Date().timeIntervalSince(start)*1000])
        }
        visibleRoots[rootID] = (AXElementMembership(lists[false]!), AXElementMembership(lists[true]!))
    }
    candidates.removeAll { candidate in
        let id = candidate["node"] as! Int
        var rootID: Int? = id
        while let current = rootID, rows[current]["role"] as? String != "AXWebArea" { rootID = rows[current]["parent"] as? Int }
        guard let rootID, let membership = visibleRoots[rootID] else {
            rows[id]["onscreenSelection"] = "not_in_webarea"
            return false
        }
        let all = membership.all.contains(elements[id]), visible = membership.visible.contains(elements[id])
        rows[id]["onscreenSelection"] = ["root":rootID,"all":all,"visibleOnly":visible]
        if AXVisibleSelection.excludes(discovered:all,visible:visible) {
            rows[id]["decision"] = "excluded"
            rows[id]["decisionReason"] = "excluded_by_ax_visible_only"
            rows[id]["exclusionReason"] = "excluded_by_ax_visible_only"
            return true
        }
        return false
    }
    let visibleSearchElapsed = Date().timeIntervalSince(visibleSearchStarted)
    let controlTextResolution = ControlTextResolver().apply(rows: &rows, elements: &elements, candidates: &candidates, deadline: deadline, filterTiny: true)
    let selectionRegion = Optional(request.selectionRegion)
    for index in candidates.indices {
        let id = candidates[index]["node"] as! Int
        let isAuxiliary = rows[id]["surfaceViewport"] != nil
        let nodeViewport = selectionViewport(rows[id])
        candidates[index]["regionKind"] = rows[id]["surfaceKind"] as? String ?? "content"
        if isAuxiliary { candidates[index]["regionViewport"] = rows[id]["surfaceViewport"] }
        var effectiveViewport = nodeViewport
        var clippingAncestors: [Int] = []
        var ancestor = (rows[id]["controlTextOwner"] ?? rows[id]["parent"]) as? Int
        while let parent = ancestor {
            if rows[parent]["role"] as? String == "AXScrollArea", let f = rows[parent]["frame"] as? [String: Double] {
                effectiveViewport = effectiveViewport.intersection(CGRect(x:f["x"]!,y:f["y"]!,width:f["width"]!,height:f["height"]!))
                clippingAncestors.append(parent)
            }
            ancestor = rows[parent]["parent"] as? Int
        }
        if !isAuxiliary, let region = selectionRegion { effectiveViewport = effectiveViewport.intersection(region) }
        candidates[index]["clipAncestors"] = clippingAncestors
        candidates[index]["effectiveClipRegion"] = effectiveViewport.isNull ? NSNull() : rect(effectiveViewport) as Any
        let candidateBox = candidates[index]["box"] as! [String: Double]
        let nodeRect = CGRect(x:candidateBox["x"]!,y:candidateBox["y"]!,width:candidateBox["width"]!,height:candidateBox["height"]!)
        candidates[index]["geometricVisibility"] = TextRangeSafety.visibility(nodeRect, in: effectiveViewport)
        if !isAuxiliary, let region = selectionRegion { candidates[index]["selectionRegion"] = rect(region) }
        guard candidates[index]["geometricVisibility"] as? String != "outside",
              candidates[index]["textSource"] as? String == "AXValue" else { continue }
        if !isAuxiliary, let region = selectionRegion { candidates[index]["selectionRegion"] = rect(region) }
        candidates[index]["visibility"] = "unknown_glyph_visibility"
        candidates[index]["uncertainty"] = "전체 AX 문자열; 말줄임·부분 잘림·hover 표시 여부 미확정. 라인 박스가 없으면 노드 박스를 유지함."
    }
    // Identify a pinned list only inside an explicitly observed Notion timeline.
    // The nearest collection block wrapping list rows distinguishes the overlay
    // from the collection block wrapping the entire timeline. Ambiguity keeps data.
    func ancestorIDs(_ id: Int) -> [Int] {
        var result: [Int] = [], parent = (rows[id]["controlTextOwner"] ?? rows[id]["parent"]) as? Int
        while let current = parent { result.append(current); parent = rows[current]["parent"] as? Int }
        return result
    }
    func classes(_ id: Int) -> [String] { rows[id]["domClasses"] as? [String] ?? [] }
    func rowFrame(_ id: Int) -> CGRect? {
        guard let f = rows[id]["frame"] as? [String:Double] else { return nil }
        return CGRect(x:f["x"]!, y:f["y"]!, width:f["width"]!, height:f["height"]!)
    }
    var panels: [Int:Set<Int>] = [:]
    for id in rows.indices where classes(id).contains("notion-collection-item") {
        let ancestors = ancestorIDs(id)
        guard let timeline = ancestors.first(where:{ classes($0).contains("notion-timeline-view") }),
              let panel = ancestors.prefix(while:{$0 != timeline}).first(where:{classes($0).contains("notion-collection_view-block")}) else { continue }
        panels[timeline, default:[]].insert(panel)
    }
    for index in candidates.indices {
        let id = candidates[index]["node"] as! Int
        let ancestors = ancestorIDs(id)
        guard let timeline = ancestors.first(where:{classes($0).contains("notion-timeline-view")}),
              let choices = panels[timeline], choices.count == 1, let panelID = choices.first,
              let panel = rowFrame(panelID), let timelineFrame = rowFrame(timeline),
              panel.width > 1, panel.height > 1, panel.minX <= timelineFrame.minX,
              panel.maxX < timelineFrame.maxX,
              // Cover the timeline canvas AND date/month headers. Header groups
              // need not carry timeline-item classes. The pinned list's own
              // labels are above this surface and must never be clipped by it.
              !([id] + ancestors).contains(panelID) else { continue }
        let f = candidates[index]["box"] as! [String:Double]
        let original = CGRect(x:f["x"]!,y:f["y"]!,width:f["width"]!,height:f["height"]!)
        let visible = TimelineClipping.visibleBox(original, behind:panel)
        candidates[index]["timelineOcclusion"] = ["timeline":timeline,"panel":panelID,"panelFrame":rect(panel)]
        if visible.isNull || visible.isEmpty {
            candidates[index]["geometricVisibility"] = "outside"
            rows[id]["timelineOcclusion"] = candidates[index]["timelineOcclusion"]
            rows[id]["exclusionReason"] = "covered_by_timeline_pinned_list"
        } else if visible != original {
            candidates[index]["originalBox"] = rect(original)
            candidates[index]["box"] = rect(visible)
            candidates[index]["boxKind"] = "timeline_visible_node_frame"
        }
        // Deliberately do NOT touch lineRanges or rangeInvestigations here.
    }
    // The list's sticky column header lives in a portal OUTSIDE the timeline
    // subtree. Associate only a real table-header portal in the same vertical
    // scroller, crossing the timeline panel's top edge. Never use arbitrary AX
    // groups or infer generic paint order. Ambiguous portals leave input intact.
    func verticalScroller(_ id: Int) -> Int? {
        ([id] + ancestorIDs(id)).first { classes($0).contains("notion-scroller") && classes($0).contains("vertical") }
    }
    let headerPortals = Set(rows.indices.filter { classes($0).contains("notion-table-view-header-row") }.compactMap { id in
        ancestorIDs(id).first { classes($0).contains("sticky-portal-target") }
    })
    let calendarPortals = Set(rows.indices.filter { classes($0).contains("notion-shimmer-timeline-transition") }.compactMap { id in
        ancestorIDs(id).first { classes($0).contains("sticky-portal-target") }
    })
    var stickyHeaders: [Int:(header:Int, kind:String, frame:CGRect)] = [:]
    for (timeline, choices) in panels where choices.count == 1 {
        guard let panelID = choices.first, let panel = rowFrame(panelID), let scroller = verticalScroller(timeline) else { continue }
        let matches = headerPortals.filter { portalID in
            guard verticalScroller(portalID) == scroller, let header = rowFrame(portalID) else { return false }
            return header.height > 1 && header.minY <= panel.minY && header.maxY > panel.minY &&
                header.minX <= panel.minX && header.maxX >= panel.maxX
        }
        guard matches.count == 1, let headerID = matches.first, let listHeader = rowFrame(headerID),
              let timelineFrame = rowFrame(timeline) else { continue }
        // Keep the existing list-only clipping if the calendar cannot be
        // associated; an uncertain extension must not disable proven clipping.
        stickyHeaders[timeline] = (headerID, "timeline", listHeader)
        rows[timeline]["timelineHeaderStatus"] = "list_header_only_calendar_association_ambiguous"
        // Both halves share one opaque header band. Chromium collapses the
        // calendar portal to 1pt when sticky; the list header retains its height.
        // Require an explicit, uniquely associated calendar portal and timeline.
        let calendarMatches = calendarPortals.filter { id in
            guard verticalScroller(id) == scroller, let calendar = rowFrame(id) else { return false }
            return StickyHeaderClipping.timelineHeader(listHeader:listHeader, timeline:timelineFrame, calendarPortal:calendar) != nil
        }
        let timelineMatches = panels.keys.filter { id in
            guard verticalScroller(id) == scroller, let frame = rowFrame(id) else { return false }
            return abs(frame.minY - listHeader.minY) <= 1
        }
        guard calendarMatches.count == 1, timelineMatches.count == 1,
              let calendarID = calendarMatches.first, let calendar = rowFrame(calendarID),
              let header = StickyHeaderClipping.timelineHeader(listHeader:listHeader, timeline:timelineFrame, calendarPortal:calendar) else { continue }
        stickyHeaders[timeline] = (headerID, "timeline", header)
        rows[timeline]["timelineHeaderStatus"] = "full_header_band_from_list_header"
    }
    // Ordinary database tables have the same portal-based sticky header. Its
    // full width must span the table and its top must cover the table viewport.
    // Shared scroller + geometry + uniqueness avoid using another view's header.
    for table in rows.indices where classes(table).contains("notion-table-view") {
        guard let tableFrame = rowFrame(table), let scroller = verticalScroller(table) else { continue }
        let matches = headerPortals.filter { portalID in
            guard verticalScroller(portalID) == scroller, let header = rowFrame(portalID) else { return false }
            return header.height > 1 && header.minY <= tableFrame.minY && header.maxY > tableFrame.minY &&
                header.minX <= tableFrame.minX && header.maxX >= tableFrame.maxX
        }
        if matches.count == 1 { stickyHeaders[table] = (matches.first!, "table", rowFrame(matches.first!)!) }
    }
    for index in candidates.indices {
        guard candidates[index]["geometricVisibility"] as? String != "outside" else { continue }
        let id = candidates[index]["node"] as! Int
        let ancestors = [id] + ancestorIDs(id)
        guard let view = ancestors.first(where:{classes($0).contains("notion-timeline-view") || classes($0).contains("notion-table-view")}),
              let association = stickyHeaders[view] else { continue }
        let isBody = ancestors.prefix(while:{$0 != view}).contains { id in
            classes(id).contains("notion-collection-item") ||
                (association.kind == "timeline" && classes(id).contains("notion-timeline-item-row"))
        }
        guard isBody else { continue }
        let header = association.frame
        let metadataKey = association.kind == "timeline" ? "timelineHeaderOcclusion" : "tableHeaderOcclusion"
        let f = candidates[index]["box"] as! [String:Double]
        let original = CGRect(x:f["x"]!,y:f["y"]!,width:f["width"]!,height:f["height"]!)
        let visible = StickyHeaderClipping.belowHeader(original, header:header)
        candidates[index][metadataKey] = ["view":view,"header":association.header,"headerFrame":rect(header)]
        if visible.isNull || visible.isEmpty {
            candidates[index]["geometricVisibility"] = "outside"
            rows[id][metadataKey] = candidates[index][metadataKey]
            rows[id]["exclusionReason"] = association.kind == "timeline" ? "covered_by_timeline_sticky_header" : "covered_by_table_sticky_header"
        } else if visible != original {
            if candidates[index]["originalBox"] == nil { candidates[index]["originalBox"] = rect(original) }
            candidates[index]["box"] = rect(visible)
            candidates[index]["boxKind"] = "sticky_header_visible_node_frame"
        }
        // No range API calls and no changes to lineRanges/rangeInvestigations.
    }
    // A center peek's renderer includes the full-screen translucent backdrop.
    // Its actual opaque page panel is the parent of peek-top-hover-area. Scope
    // this rule to an unambiguous observed preview; never hide that preview's
    // own descendants or infer arbitrary AX sibling paint order.
    var previewPanels: [Int:Set<Int>] = [:]
    for id in rows.indices where classes(id).contains("peek-top-hover-area") {
        guard let rootID = ancestorIDs(id).first(where:{classes($0).contains("notion-peek-renderer")}),
              let panelID = rows[id]["parent"] as? Int, panelID != rootID else { continue }
        previewPanels[rootID,default:[]].insert(panelID)
    }
    if previewPanels.count == 1, let (rootID,panelIDs) = previewPanels.first,
       panelIDs.count == 1, let panelID = panelIDs.first, let panel = rowFrame(panelID),
       panel.width > 1, panel.height > 1 {
        for index in candidates.indices {
            guard candidates[index]["geometricVisibility"] as? String != "outside" else { continue }
            let id = candidates[index]["node"] as! Int
            guard !([id] + ancestorIDs(id)).contains(rootID) else { continue }
            let f = candidates[index]["box"] as! [String:Double]
            let original = CGRect(x:f["x"]!,y:f["y"]!,width:f["width"]!,height:f["height"]!)
            let visible = PreviewOcclusion.visibleBoxes(original,behind:panel)
            // Keep panel metadata even for non-overlapping node fragments: a
            // larger native paragraph frame may still intersect the preview.
            let observation: [String:Any] = ["root":rootID,"panel":panelID,"panelFrame":rect(panel)]
            candidates[index]["previewOcclusions"] = [observation]
            if visible.isEmpty {
                candidates[index]["geometricVisibility"] = "outside"
                rows[id]["previewOcclusions"] = [observation]
                rows[id]["exclusionReason"] = "covered_by_page_preview"
            } else if visible != [original] {
                if candidates[index]["originalBox"] == nil { candidates[index]["originalBox"] = rect(original) }
                candidates[index]["box"] = rect(visible[0])
                candidates[index]["visibleBoxes"] = visible.map(rect)
                candidates[index]["boxKind"] = "preview_visible_node_fragments"
            }
            // Preserve lineRanges and rangeInvestigations verbatim.
        }
    }
    candidates.removeAll { candidate in
        if candidate["geometricVisibility"] as? String == "outside" {
            let id = candidate["node"] as! Int
            rows[id]["decision"] = "excluded"
            rows[id]["decisionReason"] = rows[id]["exclusionReason"] as? String ?? "outside_effective_clip_region"
            return true
        }
        return false
    }
    let imageViewer = ImageViewerGeometry.detect(in: rows)
    if let imageViewer {
        candidates.removeAll { candidate in
            let id = candidate["node"] as! Int
            guard let frame = rowFrame(id), imageViewer.panel.intersects(frame) else { return false }
            rows[id]["decision"] = "excluded"
            rows[id]["decisionReason"] = "occluded_by_image_viewer"
            return true
        }
    }
    candidates.sort { ($0["node"] as! Int) < ($1["node"] as! Int) }
    // Lines belong to native translation units, parallel to original AX nodes.
    // Match the same nearest native boundary as render_ax_report.build_paragraphs.
    // Reuse this traversal's handles; never reacquire IDs from a different tree.
    let units = AXParagraphBuilder.build(nodes: rows, selected: candidates, popupOcclusion:nil)
    let groups = Dictionary(uniqueKeysWithValues: units.map { ($0["node"] as! Int, $0["members"] as! [Int]) })
    var childrenByParent:[Int:[Int]]=[:]
    for id in rows.indices {if let parent=rows[id]["parent"] as? Int{childrenByParent[parent,default:[]].append(id)}}
    func collectTextLeaves(_ id: Int, into leaves: inout [Int]) {
        if rows[id]["role"] as? String == "AXStaticText" {
            if !(rows[id]["recoveredText"] as? String ?? rows[id]["value"] as? String ?? "").isEmpty { leaves.append(id) }
            return
        }
        for child in childrenByParent[id] ?? [] {
            collectTextLeaves(child, into: &leaves)
        }
    }

    func sidebarPageTitleLine(_ node: Int) throws -> [String: Any]? {
        guard rows[node]["surfaceKind"] as? String == "sidebar",
              rows[node]["role"] as? String == "AXStaticText",
              let wrapper = rows[node]["parent"] as? Int,
              rows[wrapper]["role"] as? String == "AXGroup",
              classes(wrapper).contains("notranslate"),
              let row = rows[wrapper]["parent"] as? Int,
              rows[row]["role"] as? String == "AXRow",
              let page = rows[row]["parent"] as? Int,
              classes(page).contains("notion-page-block"),
              ancestorIDs(page).contains(where: { rows[$0]["role"] as? String == "AXOutline" }),
              let text = rows[node]["value"] as? String, !text.isEmpty else { return nil }

        var rowLeaves: [Int] = []
        collectTextLeaves(row, into: &rowLeaves)
        guard rowLeaves.count == 1, rowLeaves.first == node else { return nil }

        if request.visibleFirst {
            try readSidebarBounds(elements[node], value: text, row: &rows[node])
        }
        guard rows[node]["boundsForFullRangeError"] as? Int32 == 0,
              let box = rows[node]["boundsForFullRange"] as? [String: Double],
              box.values.allSatisfy(\.isFinite),
              let width = box["width"], width > 0,
              let height = box["height"], height > 0 else { return nil }

        // Page rows have a single displayed title. Reuse the full source
        // bounds, including portions hidden by ellipsis or scroll clipping.
        let length = text.utf16.count
        return [
            "lineMethod": "sidebar-title-full-range",
            "lineSourceText": text,
            "lineRangeStatus": "complete_unverified",
            "coveredUTF16Length": length,
            "totalUTF16Length": length,
            "lineRanges": [[
                "rangeStart": 0, "rangeLength": length, "text": text,
                "box": box, "boxKind": "full_range", "sourceNode": node
            ]]
        ]
    }

    for unit in groups.keys.sorted() {
        try cancellation.check()
        var leafIDs: [Int] = []
        collectTextLeaves(unit, into: &leafIDs)
        let viewport=selectionViewport(rows[unit])
        var probe:[String:Any]
        if let parts = MathSegments.parts(root: unit, rows: rows, children: childrenByParent) {
            var content: [[String: Any]] = [], combinedLines: [[String: Any]] = [], source = "", sourceIDs: [Int] = []
            var failures: [String] = []
            for (partID, part) in parts.enumerated() {
                if let math = part.math {
                    content.append(["kind": "math", "id": partID, "node": math, "translationExcluded": true])
                    continue
                }
                let text = part.leaves.map { (rows[$0]["recoveredText"] ?? rows[$0]["value"]) as! String }.joined()
                var segment: [String: Any] = ["kind": "text", "id": partID, "text": text, "sourceNodes": part.leaves]
                if MathTranslationPolicy.nonrendering(text) {
                    segment["lineRangeStatus"] = "nonrendering_text"; segment["lineRanges"] = []
                } else {
                    let result = investigator.inspectParagraph(elements[unit], role: rows[unit]["role"] as? String ?? "",
                        leaves: part.leaves.map { ($0, elements[$0], (rows[$0]["recoveredText"] ?? rows[$0]["value"]) as! String) }, viewport: viewport)
                    segment["lineRangeStatus"] = result["lineRangeStatus"]
                    segment["lineMethod"] = result["lineMethod"]
                    let nativeLines = result["lineRanges"] as? [[String: Any]] ?? []
                    segment["lineRanges"] = nativeLines
                    if result["lineRangeStatus"] as? String != "complete_unverified" { failures.append(result["lineRangeStatus"] as? String ?? "unknown") }
                    for var line in nativeLines {
                        line["segment"] = partID
                        line["segmentRangeStart"] = line["rangeStart"]
                        line["rangeStart"] = (line["rangeStart"] as! Int) + source.utf16.count
                        combinedLines.append(line)
                    }
                    source += text; sourceIDs += part.leaves
                }
                content.append(segment)
            }
            leafIDs = sourceIDs
            probe = ["lineMethod": "math-segmented-native", "lineSourceText": source,
                "lineRangeStatus": failures.isEmpty ? "complete_unverified" : "partial_math_text_segments",
                "coveredUTF16Length": combinedLines.reduce(0) { $0 + ($1["rangeLength"] as! Int) },
                "totalUTF16Length": source.utf16.count, "lineRanges": combinedLines,
                "inlineContent": content, "mathPolicy": MathTranslationPolicy.version, "segmentFailures": failures]
        } else if let titleLine = try sidebarPageTitleLine(unit) {
            probe = titleLine
        } else if leafIDs.isEmpty {
            probe=["lineMethod":"unavailable","lineSourceText":rows[unit]["value"] as? String ?? "",
                   "lineRangeStatus":"no_static_text_descendants","lineRanges":[]]
        } else {
            probe=investigator.inspectParagraph(elements[unit],role:rows[unit]["role"] as? String ?? "",leaves:leafIDs.map{($0,elements[$0],(rows[$0]["recoveredText"] ?? rows[$0]["value"]) as! String)},viewport:viewport)
        }
        probe["sourceNodes"]=leafIDs
        let lines=probe["lineRanges"] as? [[String:Any]] ?? []
        // A selected paragraph needs its entire native line capacity, including
        // lines outside the viewport. Visibility only controls rendering clips;
        // dropping lines here compresses the full translation into a partial span.
        probe["lineRanges"]=lines.enumerated().map{number,line -> [String:Any] in
            var line=line;line["line"]=number
            return line
        }
        rows[unit]["paragraphLineInvestigation"]=probe
        // Preserve the original query output without report line numbering.
        var rawProbe=probe;rawProbe["lineRanges"]=lines
        rows[unit]["rangeInvestigations"]=[rawProbe]
    }
    let valid = frame(window).map{AXWindowMatch.near($0, before)} == true
    // Report coverage separately from successful execution. Notion can remove
    // the background subtree entirely while an Actions menu is open. Do not
    // fabricate background text from previous captures or close menus to extract.
    let backgroundAXUnavailable = rows.contains { $0["role"] as? String == "AXMenu" } &&
        !rows.contains { ($0["domClasses"] as? [String] ?? []).contains("notion-frame") } && stack.isEmpty
    let coverageLimitations = backgroundAXUnavailable ? ["menu_background_not_exposed_by_ax"] : []


    try cancellation.check()
    // Reuse the visibility searches already performed for this exact tree.
    // Cached/hidden dialogs must not punch holes in an unrelated later frame.
    for id in rows.indices where rows[id]["subrole"] as? String == "AXApplicationDialog" || classes(id).contains("notion-sidebar") {
        if let root=([id]+ancestorIDs(id)).first(where:{ rows[$0]["role"] as? String == "AXWebArea" }),let membership=visibleRoots[root] {
            rows[id]["popupVisibleOnly"] = !AXVisibleSelection.excludes(discovered:membership.all.contains(elements[id]),visible:membership.visible.contains(elements[id]))
        }
    }
    let popupStarted=Date()
    let popupOcclusion = PopupOcclusion(rows:rows)
    let popupDetectionSeconds=Date().timeIntervalSince(popupStarted)
    var paragraphs = AXParagraphBuilder.build(nodes: rows, selected: candidates, popupOcclusion:popupOcclusion)
    let colorStarted = Date()
    var colorCalls = 0
    var attributedCache: [Int:NSAttributedString] = [:]
    let colorNodes = Set(paragraphs.flatMap { ($0["lineSourceNodes"] as? [Int]) ?? ($0["members"] as? [Int] ?? []) })
    for n in colorNodes.sorted() {
        if Date() > deadline { break }
        try cancellation.check()
        guard rows[n]["mathOwner"] == nil, let value = rows[n]["value"] as? String, !value.isEmpty else { continue }
        func colorQuery(_ key: String, _ argument: CFTypeRef) -> CFTypeRef? {
            if cancellation.isCancelled || Date() > deadline { return nil }
            var result: CFTypeRef?
            colorCalls += 1; recordAXQuery()
            let error=AXUIElementCopyParameterizedAttributeValue(elements[n],key as CFString,argument,&result)
            recordAXResult(key,error)
            return error == .success ? result : nil
        }
        // Chromium's integer-range string can have no style attributes. Its
        // original element marker range carries style; validate native text
        // before consuming it. No marker bytes or formula geometry are queried.
        var attributed: NSAttributedString?
        if let marker = colorQuery("AXTextMarkerRangeForUIElement",elements[n]),
           CFGetTypeID(marker) == AXTextMarkerRangeGetTypeID(),
           let native = colorQuery("AXAttributedStringForTextMarkerRange",marker) as? NSAttributedString,
           native.string.utf16.elementsEqual(value.utf16) {
            attributed = native
            rows[n]["colorSource"] = "native_text_marker_range"
        } else {
            var range = CFRange(location:0,length:value.utf16.count)
            if let argument = AXValueCreate(.cfRange,&range),
               let native = colorQuery("AXAttributedStringForRange",argument) as? NSAttributedString,
               native.string.utf16.elementsEqual(value.utf16) {
                attributed = native
                rows[n]["colorSource"] = "native_integer_range"
            }
        }
        attributedCache[n] = attributed
        rows[n]["foregroundColorStatus"] = "mixed_or_unavailable"
        if let attributed, let color = AXForegroundStyle.uniformColor(in:attributed,matching:value) {
            rows[n]["foregroundColor"] = ["red":color.red,"green":color.green,"blue":color.blue,"alpha":color.alpha]
            rows[n]["foregroundColorStatus"] = "uniform"
        }
    }
    let codeStarted = Date(), codeCallsBefore = investigator.calls
    for i in paragraphs.indices where paragraphs[i]["isCodeBlock"] as? Bool == true {
        try cancellation.check()
        let segments = AXCodeRangeCollection.collect(paragraph:paragraphs[i],rows:rows,elements:elements,
            attributed:attributedCache,investigator:investigator)
        paragraphs[i]["codeSegments"] = segments
        rows[paragraphs[i]["node"] as! Int]["codeSegments"] = segments
    }
    let codeSeconds = Date().timeIntervalSince(codeStarted)
    let truncated = Date() > deadline || investigator.limitReached || !stack.isEmpty || rows.contains{$0["depthLimitReached"] as? Bool == true}
    let codePartial = paragraphs.contains { ($0["codeSegments"] as? [[String:Any]])?.contains(where: { $0["status"] as? String == "partial" }) == true }
    let missingDocumentTree = !truncated && AXActivationReadiness.documentTreeMissing(rows:rows)
    let readinessReasons = AXActivationReadiness.reasons(paragraphs:paragraphs,truncated:truncated) + (missingDocumentTree ? ["document_webarea_unavailable"] : [])
    let partial = missingDocumentTree || codePartial || truncated || paragraphs.contains { ($0["lineRangeStatus"] as? String ?? "unavailable") != "complete_unverified" }
    let imageRegions = imageViewer.map { [$0.region(in: captureViewport)] } ?? ImageRegionBuilder.build(rows:rows,selection:request.selectionRegion,
        viewport:{ id in
            var viewport = selectionViewport(rows[id])
            let ancestors = [id]+ancestorIDs(id)
            if let view = ancestors.first(where:{ classes($0).contains("notion-timeline-view") || classes($0).contains("notion-table-view") }),
               let header = stickyHeaders[view],
               ancestors.prefix(while:{$0 != view}).contains(where:{ classes($0).contains("notion-collection-item") || (header.kind == "timeline" && classes($0).contains("notion-timeline-item-row")) }) {
                viewport = StickyHeaderClipping.belowHeader(viewport,header:header.frame)
            }
            if let timeline = ancestors.first(where:{ classes($0).contains("notion-timeline-view") }),
               let choices=panels[timeline],choices.count == 1,let panelID=choices.first,
               let panel=rowFrame(panelID),let timelineFrame=rowFrame(timeline),
               panel.width>1,panel.height>1,panel.minX<=timelineFrame.minX,panel.maxX<timelineFrame.maxX,
               !ancestors.contains(panelID) {
                viewport = TimelineClipping.visibleBox(viewport,behind:panel)
            }
            return viewport
        }, visible:{ id in
            guard let root = ([id]+ancestorIDs(id)).first(where:{ rows[$0]["role"] as? String == "AXWebArea" }),
                  let membership = visibleRoots[root] else { return false }
            return !AXVisibleSelection.excludes(discovered:membership.all.contains(elements[id]),visible:membership.visible.contains(elements[id]))
        }, occlusions:{ id in
            let chain = [id]+ancestorIDs(id)
            let sidebarMasks = popupOcclusion.masks(for:id)
            let menuMasks = rows.indices.filter { classes($0).contains("notion-text-action-menu") && !chain.contains($0) &&
                ancestorIDs($0).contains(where: { rows[$0]["role"] as? String == "AXWebArea" && chain.contains($0) }) }.compactMap(rowFrame).map(PreviewOcclusion.textEditingMenuPanel)
            guard previewPanels.count == 1, let (root,ids) = previewPanels.first,
                  ids.count == 1, let panelID=ids.first, let panel=rowFrame(panelID),
                  !([id]+ancestorIDs(id)).contains(root) else { return menuMasks + sidebarMasks }
            return menuMasks + sidebarMasks + [panel]
        })
    let surfaceStarted=Date()
    let documentSurfaces=AXDocumentSurfaceBuilder.build(rows:rows)
    let surfaceSeconds=Date().timeIntervalSince(surfaceStarted)
    let metadata: [String: Any] = ["imageViewerActive":imageViewer != nil,"documentSurfaces":documentSurfaces,"documentSurfaceSeconds":surfaceSeconds, "popupOcclusionSeconds":popupDetectionSeconds, "popupOcclusionPanels":popupOcclusion.diagnostics, "popupOcclusionPolicy":"semantic-dialog-and-floating-sidebar-v2; anonymous-popups-unsupported", "imageRegions":imageRegions,"status": valid ? (partial ? "partial" : "complete") : "failed",
        "targetAndFrameMatch":valid,"coordinateSystem":"screen-top-left-points", "elapsed":Date().timeIntervalSince(started), "colorQueries":colorCalls, "colorQuerySeconds":Date().timeIntervalSince(colorStarted),
        "codeRangeQueries":investigator.calls-codeCallsBefore,"codeRangeSeconds":codeSeconds,
        "parentValueQueries":request.collectParentTextDiagnostics ? rows.filter { $0["role"] as? String == "AXTextArea" }.count : 0,
        "totalAXCalls":Thread.current.threadDictionary["rearview.ax.queryCount"] as? Int ?? 0,"rangeCalls":investigator.calls,"rangeElapsed":investigator.elapsed,"rangeLimitReached":investigator.limitReached,
        "activationReadinessReasons":readinessReasons,
        "truncated":truncated,"parkedDocumentCount":parkedDocumentCount,"coverageLimitations":coverageLimitations,"visibleSearches":visibleSearches,
        "visibleSearchElapsed":visibleSearchElapsed,"traversalSeconds":traversalSeconds,
        "visibleFirst":request.visibleFirst,"pruneOffscreenBranches":pruningEnabled,
        "treeVisitedNodes":treeVisitedNodes,"treePrunedBranches":prunedBranches,"sidebarBoundsQueries":sidebarBoundsQueries,
        "outsideStaticTextValueQueries":outsideValueQueries+restoredValues,"omittedOutsideValues":deferredValues.count-restoredValues,"controlTextResolution":controlTextResolution,
        "selectionPolicy":"ax-visible-only-plus-timeline-pinned-list-v1", "limits":["nodes":3500,"depth":40,"seconds":15],
        "collectedAt":ISO8601DateFormatter().string(from:started), "windowFrame":rect(before), "selectionRegion":rect(request.selectionRegion)]
    guard valid else { throw AXExtractionError.windowChanged }
    if let scrollAnchors, imageViewer == nil, metadata["status"] as? String == "complete",
       documentSurfaces.count == 1, let document = documentSurfaces.first,
       (document["dialogBoxes"] as? [[String: Double]])?.isEmpty == true,
       let bodyNodes = document["bodyNodes"] as? [Int] {
        let body = Set(bodyNodes)
        let interior = captureViewport.insetBy(dx: min(55, captureViewport.width / 8),
                                                dy: min(90, captureViewport.height / 6))
        let choices: [(Int, CGPoint)] = candidates.compactMap { candidate in
            guard let id = candidate["node"] as? Int, rows[id]["role"] as? String == "AXStaticText",
                  rows[id]["surfaceKind"] == nil, rows[id]["mathOwner"] == nil,
                  let box = rows[id]["frame"] as? [String: Double], let x = box["x"], let y = box["y"],
                  interior.contains(CGPoint(x: x, y: y)) else { return nil }
            var ancestor: Int? = id
            var belongsToBody = false
            while let node = ancestor {
                let classes = rows[node]["domClasses"] as? [String] ?? []
                let role = rows[node]["role"] as? String
                if role == "AXCell" || role == "AXTable" || classes.contains(where: {
                    $0.hasPrefix("notion-collection") || $0.hasPrefix("notion-table") ||
                        $0.hasPrefix("notion-simple-table") || $0 == "notion-code-block"
                }) { return nil }
                belongsToBody = belongsToBody || body.contains(node)
                ancestor = rows[node]["parent"] as? Int
            }
            return belongsToBody ? (id, CGPoint(x: x, y: y)) : nil
        }
        var selected: [(AXUIElement, CGPoint)] = []
        for fraction in [0.3, 0.5, 0.7] {
            let y = captureViewport.minY + fraction * captureViewport.height
            if let choice = choices.filter({ candidate in
                selected.allSatisfy { abs($0.1.y - candidate.1.y) >= 35 }
            }).min(by: { abs($0.1.y - y) < abs($1.1.y - y) }) {
                selected.append((elements[choice.0], choice.1))
            }
        }
        scrollAnchors(selected)
    }
    if let prefetch, imageViewer == nil, metadata["status"] as? String == "complete" {
        let roots = rows.filter { $0["documentURL"] != nil && $0["surfaceKind"] == nil }
        if roots.count == 1, let root = roots.first?["id"] as? Int {
            var above: [AXUIElement] = [], below: [AXUIElement] = []
            for (id, row) in rows.enumerated() {
                guard row["surfaceKind"] == nil, row["mathOwner"] == nil,
                      let box = row["frame"] as? [String: Double], let y = box["y"], let height = box["height"],
                      let classes = row["domClasses"] as? [String], !AXPrefetch.classes.isDisjoint(with: classes),
                      row["childrenPruned"] as? Bool == true else { continue }
                var ancestor = row["parent"] as? Int
                while let index = ancestor, index != root {
                    let classes = rows[index]["domClasses"] as? [String] ?? []
                    if classes.contains(where: { $0.contains("table") || $0.contains("collection") || $0 == "notion-code-block" }) { break }
                    ancestor = rows[index]["parent"] as? Int
                }
                guard ancestor == root else { continue }
                if y + height <= captureViewport.minY + 1 { above.append(elements[id]) }
                else if y >= captureViewport.maxY - 1 { below.append(elements[id]) }
            }
            above.reverse()
            prefetch((0..<max(above.count, below.count)).flatMap { index in
                [index < above.count ? above[index] : nil, index < below.count ? below[index] : nil].compactMap { $0 }
            })
        }
    }
    return try AXExtractionSnapshot(nodes: rows, selected: candidates, paragraphs: paragraphs, metadata: metadata)
}
}
