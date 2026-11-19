import NotionAXCore
import NotionAXReportSupport
import AppKit
import ApplicationServices
import NotionScenarioCore

func get(_ e: AXUIElement, _ key: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(e, key as CFString, &value) == .success ? value : nil
}
func frame(_ e: AXUIElement) -> CGRect? {
    guard let p = get(e, "AXPosition"), let s = get(e, "AXSize"), CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
    var point = CGPoint.zero, size = CGSize.zero
    guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
    return CGRect(origin: point, size: size)
}
// Product policy, not proof of invisibility: Chromium can clamp fully clipped
// nodes to a 1-unit edge rectangle. Even a genuinely visible <=1pt text sliver
// is not useful translation input. Filter using the already-read frame to avoid
// additional cross-process AX range queries. Units are screen points (1pt = 2px
// on a 2x display), not pixels. Revisit this threshold if tiny fragments become
// useful; preserve the raw node and exclusion reason for that investigation.
// Rationale: https://github.com/chromium/chromium/blob/main/docs/accessibility/browser/offscreen.md
let minimumUsefulTextExtent: CGFloat = 1
func isTinyTextFrame(_ frame: CGRect) -> Bool {
    // Research override only; default selection keeps the inexpensive 1pt guard.
    !CommandLine.arguments.contains("--disable-1pt-filter") &&
        (frame.width <= minimumUsefulTextExtent || frame.height <= minimumUsefulTextExtent)
}

func rect(_ r: CGRect) -> [String: Double] { ["x":r.minX,"y":r.minY,"width":r.width,"height":r.height] }
func escape(_ s: String) -> String { s.replacingOccurrences(of:"&",with:"&amp;").replacingOccurrences(of:"<",with:"&lt;").replacingOccurrences(of:"\"",with:"&quot;") }
func save(_ value: Any, _ url: URL) throws { try JSONSerialization.data(withJSONObject:value, options:[.prettyPrinted,.sortedKeys]).write(to:url) }
func run() throws {
    let args = Array(CommandLine.arguments.dropFirst())
    func option(_ name: String) throws -> String { guard let i = args.firstIndex(of:name), i+1 < args.count else { throw NSError(domain:"Missing \(name)",code:1) }; return args[i+1] }
    if args.first == "prepare-ax" {
        try ControlTitleStudy().prepare(activation: try option("--activation"))
        return
    }
    guard args.first == "collect" else { throw NSError(domain:"Usage: collect --root PATH --run-id ID",code:1) }
    let root = URL(fileURLWithPath:try option("--root")), id = try option("--run-id")
    guard !id.contains("/"), id != ".." else { throw NSError(domain:"Invalid run ID",code:1) }
    let source = root.appendingPathComponent("runs/\(id)")
    let decoder = JSONDecoder()
    let result = try decoder.decode(RunResult.self, from:Data(contentsOf:source.appendingPathComponent("result.json")))
    let request = try decoder.decode(RunRequest.self, from:Data(contentsOf:source.appendingPathComponent("request.json")))
    guard let capture = result.screenshot,
          result.status == "verified" || (result.status == "partial" && result.steps.filter({$0.status != "verified"}).allSatisfy({$0.item == "zoom" && $0.status == "unsupported"})) else { throw NSError(domain:"Ineligible replay",code:1) }
    guard AXIsProcessTrusted(), let process = NSRunningApplication.runningApplications(withBundleIdentifier:"notion.id").first else { throw NSError(domain:"Accessibility permission or Notion unavailable",code:1) }
    let app = AXUIElementCreateApplication(process.processIdentifier)
    AXUIElementSetMessagingTimeout(app,0.35)
    // Stage-2 research collector defaults to Manual for markers-local.
    // This does not change activation in the product extractor.
    let activation = args.firstIndex(of: "--activation").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? "manual"
    guard ["none", "manual", "enhanced", "both"].contains(activation) else { throw NSError(domain:"Invalid activation mode",code:1) }
    let activationKeys = activation == "none" ? [] : activation == "manual" ? ["AXManualAccessibility"] : activation == "both" ? ["AXManualAccessibility", "AXEnhancedUserInterface"] : ["AXEnhancedUserInterface"]
    // Leave target AX activation enabled after collection.
    var activationErrors: [String: Int32] = [:]
    for key in activationKeys { activationErrors[key] = AXUIElementSetAttributeValue(app,key as CFString,kCFBooleanTrue).rawValue }
    // Delay is an observation window, NOT a claim that every node is ready.
    if !activationKeys.isEmpty { Thread.sleep(forTimeInterval:2.5) }

    guard let focused = get(app,"AXFocusedWindow") else { throw NSError(domain:"No focused window",code:1) }
    let window = focused as! AXUIElement
    guard let before = frame(window), Rect(before).near(capture.frame) else { throw NSError(domain:"Window changed",code:1) }
    func selectionViewport(_ row: [String:Any]) -> CGRect {
        let surface = (row["surfaceViewport"] as? [String:Double]).map {
            CGRect(x:$0["x"]!,y:$0["y"]!,width:$0["width"]!,height:$0["height"]!)
        }
        return SelectionViewport.region(surface:surface,content:capture.viewport?.cgRect ?? before,window:before)
    }
    let started = Date(), deadline = started.addingTimeInterval(15)
    var elements: [AXUIElement] = []
    let investigator = RangeInvestigator(deadline: deadline)
    var stack: [(AXUIElement,Int,Int?)] = [(window,0,nil)], seen: [AXUIElement] = [], rows: [[String:Any]] = [], candidates: [[String:Any]] = [], pageFound = false
    while let (node,depth,parent) = stack.popLast() {
        if rows.count >= 3500 || Date() > deadline { stack.append((node,depth,parent)); break }
        if seen.contains(where:{CFEqual($0,node)}) { continue }; seen.append(node)
        let n = rows.count
        let role = get(node,"AXRole") as? String ?? ""
        let value = get(node,"AXValue") as? String ?? "", title = get(node,"AXTitle") as? String ?? ""
        let url = String(describing:get(node,"AXURL") ?? "" as CFString).replacingOccurrences(of:"-",with:"").lowercased()
        if url.contains(request.pageId.replacingOccurrences(of:"-",with:"").lowercased()) { pageFound = true }
        var names: CFArray?; AXUIElementCopyAttributeNames(node,&names)
        var parameters: CFArray?; AXUIElementCopyParameterizedAttributeNames(node,&parameters)
        var row: [String:Any] = ["id":n,"role":role,"value":value,"title":title,"attributes":names as? [String] ?? [],"parameterizedAttributes":parameters as? [String] ?? []]
        if let parent { row["parent"] = parent }
        // Semantic layout classes are needed only on container groups. Preserve
        // them for auditing the timeline-only rule; never infer z-order generally.
        if role == "AXGroup" {
            // One metadata request replaces the old class-only request. Cache
            // the real subrole; an advertised attribute name is not its value.
            var metadata: CFArray?
            if AXUIElementCopyMultipleAttributeValues(node, ["AXDOMClassList", "AXSubrole"] as CFArray, [], &metadata) == .success,
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
        let nodeFrame = excludedMath ? nil : frame(node)
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
        if !excludedMath && !value.isEmpty && !excludedTinyText {
            var range = CFRange(location:0,length:(value as NSString).length)
            var bounds: CFTypeRef?
            let error = AXUIElementCopyParameterizedAttributeValue(node,"AXBoundsForRange" as CFString,AXValueCreate(.cfRange,&range)!,&bounds)
            row["boundsForFullRangeError"] = error.rawValue
            if let bounds, CFGetTypeID(bounds) == AXValueGetTypeID() { var r = CGRect.zero; if AXValueGetValue(bounds as! AXValue,.cgRect,&r) { row["boundsForFullRange"] = rect(r) } }
        }
        elements.append(node)
        rows.append(row)
        let children = get(node,"AXChildren") as? [AXUIElement] ?? []
        if depth < 40 { stack.append(contentsOf:children.reversed().map{($0,depth+1,n)}) }
        else if !children.isEmpty { row["depthLimitReached"] = true; rows[n] = row }
    }
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
            let error = AXUIElementCopyParameterizedAttributeValue(elements[rootID],"AXUIElementsForSearchPredicate" as CFString,predicate as CFDictionary,&found)
            guard error == .success, let matches = found as? [AXUIElement], matches.count < 10000 else {
                // An incomplete search must not masquerade as successful filtering.
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
    let controlTextResolution = ControlTextResolver().apply(rows: &rows, elements: &elements, candidates: &candidates, deadline: deadline, filterTiny: !args.contains("--disable-1pt-filter"))
    let selectionRegion = result.observedGeometry["captureRegion"]?.cgRect
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
    var stickyHeaders: [Int:(header:Int, kind:String)] = [:]
    for (timeline, choices) in panels where choices.count == 1 {
        guard let panelID = choices.first, let panel = rowFrame(panelID), let scroller = verticalScroller(timeline) else { continue }
        let matches = headerPortals.filter { portalID in
            guard verticalScroller(portalID) == scroller, let header = rowFrame(portalID) else { return false }
            return header.height > 1 && header.minY <= panel.minY && header.maxY > panel.minY &&
                header.minX <= panel.minX && header.maxX >= panel.maxX
        }
        if matches.count == 1 { stickyHeaders[timeline] = (matches.first!, "timeline") }
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
        if matches.count == 1 { stickyHeaders[table] = (matches.first!, "table") }
    }
    for index in candidates.indices {
        guard candidates[index]["geometricVisibility"] as? String != "outside" else { continue }
        let id = candidates[index]["node"] as! Int
        let ancestors = [id] + ancestorIDs(id)
        guard let view = ancestors.first(where:{classes($0).contains("notion-timeline-view") || classes($0).contains("notion-table-view")}),
              ancestors.prefix(while:{$0 != view}).contains(where:{classes($0).contains("notion-collection-item")}),
              let association = stickyHeaders[view], let header = rowFrame(association.header) else { continue }
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
    candidates.sort { ($0["node"] as! Int) < ($1["node"] as! Int) }
    // Lines belong to native translation units, parallel to original AX nodes.
    // Match the same nearest native boundary as render_ax_report.build_paragraphs.
    // Reuse this traversal's handles; never reacquire IDs from a different tree.
    var nestedAreas:Set<Int>=[]
    for id in rows.indices where rows[id]["role"] as? String == "AXTextArea" {
        for parent in ancestorIDs(id) where rows[parent]["role"] as? String == "AXTextArea" {nestedAreas.insert(parent)}
    }
    var groups:[Int:[Int]]=[:]
    for candidate in candidates {
        let id=candidate["node"] as! Int
        var unit=id
        if candidate["textSource"] as? String == "AXValue" && candidate["controlTextOwner"] == nil {
            for parent in ancestorIDs(id) {
                let role=rows[parent]["role"] as? String ?? ""
                let usable=rowFrame(parent).map{$0.width>1 && $0.height>1} == true
                if role=="AXTextArea" {
                    if usable && !nestedAreas.contains(parent) && !(rows[parent]["value"] as? String ?? "").isEmpty {unit=parent}
                    break
                }
                if ["AXButton","AXPopUpButton","AXRadioButton"].contains(role) {
                    let title=rows[parent]["title"] as? String ?? ""
                    if usable && !title.isEmpty && title.contains(candidate["text"] as! String){unit=parent}
                    break
                }
            }
        }
        groups[unit,default:[]].append(id)
    }
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

    func sidebarPageTitleLine(_ node: Int) -> [String: Any]? {
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
              rows[node]["boundsForFullRangeError"] as? Int32 == 0,
              let box = rows[node]["boundsForFullRange"] as? [String: Double],
              box.values.allSatisfy(\.isFinite),
              let width = box["width"], width > 0,
              let height = box["height"], height > 0,
              let text = rows[node]["value"] as? String else { return nil }

        var rowLeaves: [Int] = []
        collectTextLeaves(row, into: &rowLeaves)
        guard rowLeaves.count == 1, rowLeaves.first == node else { return nil }

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
        } else if let titleLine = sidebarPageTitleLine(unit) {
            probe = titleLine
        } else if leafIDs.isEmpty {
            probe=["lineMethod":"unavailable","lineSourceText":rows[unit]["value"] as? String ?? "",
                   "lineRangeStatus":"no_static_text_descendants","lineRanges":[]]
        } else {
            probe=investigator.inspectParagraph(elements[unit],role:rows[unit]["role"] as? String ?? "",leaves:leafIDs.map{($0,elements[$0],(rows[$0]["recoveredText"] ?? rows[$0]["value"]) as! String)},viewport:viewport)
        }
        probe["sourceNodes"]=leafIDs
        let lines=probe["lineRanges"] as? [[String:Any]] ?? []
        // Keep raw AX coordinates even under header/preview clipping. Fully
        // outside lines can be omitted, but their rectangles are never cut.
        probe["lineRanges"]=lines.enumerated().compactMap{number,line -> [String:Any]? in
            var line=line;line["line"]=number
            guard let b=line["box"] as? [String:Double] else{return nil}
            let box=CGRect(x:b["x"]!,y:b["y"]!,width:b["width"]!,height:b["height"]!)
            guard TextRangeSafety.visibility(box,in:viewport) != "outside" else{return nil}
            return line
        }
        rows[unit]["paragraphLineInvestigation"]=probe
        // Preserve raw query output separately from visibility selection.
        var rawProbe=probe;rawProbe["lineRanges"]=lines
        rows[unit]["rangeInvestigations"]=[rawProbe]
    }
    let valid = pageFound && frame(window).map{Rect($0).near(Rect(before))} == true
    let collectionElapsed = Date().timeIntervalSince(started)
    // Report coverage separately from successful execution. Notion can remove
    // the background subtree entirely while an Actions menu is open. Do not
    // fabricate background text from previous captures or close menus to extract.
    let backgroundAXUnavailable = result.requested.overlay?.kind == "menu" &&
        !rows.contains { ($0["domClasses"] as? [String] ?? []).contains("notion-frame") } && stack.isEmpty
    let coverageLimitations = backgroundAXUnavailable ? ["menu_background_not_exposed_by_ax"] : []

    // Optional research sidecar, never a product selection rule. Keep the exact
    // AXUIElement handles used for rawAx.json: reactivation can add/remove wrapper
    // nodes, so IDs from a second traversal must not be assumed to identify them.
    var offscreenStudy: [String: Any]?
    if args.contains("--offscreen-study") {
        let studyStarted = Date()
        var lists: [Int: [Bool: [AXUIElement]]] = [:]
        var searches: [[String: Any]] = []
        for i in rows.indices where rows[i]["role"] as? String == "AXWebArea" {
            for visible in [false, true] {
                let predicate: [String: Any] = ["AXSearchKey":"AXAnyTypeSearchKey", "AXResultsLimit":10000,
                    "AXVisibleOnly":visible, "AXDirection":"AXDirectionNext", "AXImmediateDescendantsOnly":false]
                var value: CFTypeRef?
                let start = Date()
                let error = AXUIElementCopyParameterizedAttributeValue(elements[i], "AXUIElementsForSearchPredicate" as CFString, predicate as CFDictionary, &value)
                let found = value as? [AXUIElement] ?? []
                lists[i, default: [:]][visible] = found
                searches.append(["root":i, "visibleOnly":visible, "error":error.rawValue, "count":found.count,
                    "elapsedMs":Date().timeIntervalSince(start)*1000])
            }
        }
        var observations: [[String: Any]] = []
        for i in rows.indices {
            let memberships = lists.map { root, list -> [String: Any] in
                ["root":root, "all":list[false]?.contains(where:{CFEqual($0,elements[i])}) ?? false,
                    "visibleOnly":list[true]?.contains(where:{CFEqual($0,elements[i])}) ?? false]
            }
            var observation: [String: Any] = ["node":i, "searchMembership":memberships]
            let role = rows[i]["role"] as? String ?? ""
            if role == "AXStaticText" || ["AXButton","AXPopUpButton","AXRadioButton"].contains(role) {
                if let f = frame(elements[i]) { observation["frame"] = rect(f) }
                else { observation["frameUnavailable"] = true }
            }
            observations.append(observation)
        }
        offscreenStudy = ["method":"same AX handles as rawAx; no reactivation, hit-test or text-range query for visibility",
            "searches":searches, "nodes":observations, "elapsedMs":Date().timeIntervalSince(studyStarted)*1000]
    }
    let screenshotStarted = Date()
    let output = root.appendingPathComponent("evaluations/\(id)/\(UUID().uuidString)")
    try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
    try FileManager.default.copyItem(at:source.appendingPathComponent(capture.file),to:output.appendingPathComponent("screen.png"))
    if !activationKeys.isEmpty {
        // Capture while the research mode is still enabled. The replay image is
        // retained separately; never relabel a pre-activation image as "after".
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let matches = info.filter { row in
            guard row[kCGWindowOwnerPID as String] as? Int32 == process.processIdentifier,
                  let bounds = row[kCGWindowBounds as String] as? [String: Any],
                  let f = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return false }
            return Rect(f).near(Rect(before))
        }
        guard matches.count == 1, let number = matches.first?[kCGWindowNumber as String] as? Int else { throw NSError(domain:"Cannot map activated window screenshot",code:1) }
        try FileManager.default.moveItem(at:output.appendingPathComponent("screen.png"),to:output.appendingPathComponent("replay-screen.png"))
        let task = Process(); task.executableURL = URL(fileURLWithPath:"/usr/sbin/screencapture")
        task.arguments = ["-x", "-o", "-l", String(number), output.appendingPathComponent("screen.png").path]
        try task.run(); task.waitUntilExit()
        guard task.terminationStatus == 0, frame(window).map({Rect($0).near(Rect(before))}) == true else { throw NSError(domain:"Activated screenshot failed or frame changed",code:1) }
    }
    if let offscreenStudy { try save(offscreenStudy,output.appendingPathComponent("offscreen-membership.json")) }
    try save(rows,output.appendingPathComponent("rawAx.json")); try save(candidates,output.appendingPathComponent("candidate.json"))
    try save(["controlTextResolution":controlTextResolution,"activation":activation,"activationErrors":activationErrors,"screenshotSource":activationKeys.isEmpty ? "replay" : "activated_window_screencapture","activationObservationDelaySeconds":activationKeys.isEmpty ? 0 : 2.5,"status":"comparison_unverified","selectionPolicy":"ax-visible-only-plus-timeline-pinned-list-v1","tinyTextFilterEnabled":!args.contains("--disable-1pt-filter"),"coverageLimitations":coverageLimitations,"visibleSearches":visibleSearches,"visibleSearchElapsed":visibleSearchElapsed,"targetAndFrameMatch":valid,"screenIdentity":"Not established; manual comparison required","lineMethod":"native-paragraph-reverse-with-markers-local-reverse-single-node","rangeCalls":investigator.calls,"rangeElapsed":investigator.elapsed,"rangeLimitReached":investigator.limitReached,"coordinateSystem":"screen-top-left-points","pixelsPerPointX":capture.pixelsPerPointX,"pixelsPerPointY":capture.pixelsPerPointY,"truncated": Date() > deadline || investigator.limitReached || !stack.isEmpty || rows.contains{$0["depthLimitReached"] as? Bool == true},"elapsed":collectionElapsed,"screenshotElapsed":Date().timeIntervalSince(screenshotStarted),"limits":["nodes":3500,"depth":40,"seconds":15],"runId":id] as [String:Any],output.appendingPathComponent("metadata.json"))
    if args.contains("--control-title-study") {
        var study = ControlTitleStudy().collect(rows: rows, elements: elements, candidates: candidates)
        study["windowFrameUnchanged"] = frame(window).map { Rect($0).near(Rect(before)) } == true
        try save(study, output.appendingPathComponent("control-title-study.json"))
    }
    let list = candidates.map{"<li>\($0["node"]!): \(escape($0["text"] as! String)) — \($0["textSource"]!) / \(escape($0["uncertainty"] as! String)) / 라인: \(escape($0["lineRangeStatus"] as? String ?? "control_frame_only"))</li>"}.joined()
    let decisions = rows.filter { !($0["value"] as? String ?? "").isEmpty || !($0["title"] as? String ?? "").isEmpty }.map { row in
        "<tr><td>\(row["id"]!)</td><td>\(escape(row["role"] as! String))</td><td>\(escape((row["value"] as! String).isEmpty ? row["title"] as! String : row["value"] as! String))</td><td>\(row["decision"]!)</td><td>\(row["decisionReason"]!)</td></tr>"
    }.joined()
    let payload: [String: Any] = ["scenario": result.scenarioId, "fixture": result.fixtureId,
        "run": id, "evaluation": output.lastPathComponent, "nodes": rows, "selected": candidates, "selectionRegion": selectionRegion.map(rect) as Any? ?? NSNull()]
    let encoded = try JSONSerialization.data(withJSONObject: payload).base64EncodedString()
    // Separate sibling layers: every number is above every box, including boxes
    // emitted later. stopPropagation prevents number clicks opening the dialog.
    let report = """
    <meta charset="utf-8"><title>AX — \(escape(result.scenarioId))</title>
    <style>
    .screen{position:relative}.box{position:absolute;border:1px solid red;box-sizing:border-box;cursor:pointer;z-index:1;background:transparent}
    .box.title-source{border:2px dashed #d08000}.box:hover{background:#ff000018}.number{position:absolute;z-index:20;background:rgba(255,255,255,.45);color:#a00000;border:1px solid #a00000;border-radius:3px;padding:1px 2px;font:bold 12px/1.2 monospace;cursor:copy}
    dialog{max-width:760px;width:80vw;max-height:80vh;overflow:auto}dialog::backdrop{background:#0006}pre{white-space:pre-wrap;overflow-wrap:anywhere}#notice{position:fixed;bottom:20px;right:20px;z-index:100;background:#222;color:white;padding:12px;border-radius:6px}button{cursor:pointer}
    </style>
    <h1>\(escape(result.scenarioId))</h1><p>번호 클릭: 노드 참조 복사 / 박스 클릭: 상세 정보. 파란 박스: markers-local 라인(픽셀 가시성 미검증). 라인이 없으면 기존 박스를 유지합니다. 보라 점선: 선택 영역. 주황 점선: AXTitle 보완 수집(실제 표시 여부·글자 박스 미검증).</p>
    <p>추가 범위 API 호출: \(investigator.calls)회 / \(investigator.elapsed)s. 라인 API의 응답은 실제 픽셀 가시성의 정답이 아닙니다.</p>
    <p>Target/frame match: \(valid). Comparison unverified; full AX strings may include invisible characters.</p>
    <div class="screen" id="screen" style="width:\(before.width)px;height:\(before.height)px"><img src="screen.png" style="width:100%;height:100%"></div>
    <dialog id="detail"><button id="close">닫기</button> <button id="copyDetail">참조 복사</button><h2 id="heading"></h2><h3>원문</h3><pre id="text"></pre><h3>AX 정보·선택 근거</h3><pre id="info"></pre><textarea id="reference" readonly style="width:100%;height:90px" aria-label="노드 참조"></textarea></dialog>
    <div id="notice" role="status" hidden></div>
    <h2>현재 규칙의 선택 결과</h2><ol>\(list)</ol><details><summary>텍스트 값이 있는 전체 관측 노드: 선택·제외 이유</summary><table border="1"><tr><th>ID</th><th>Role</th><th>원문</th><th>결정</th><th>이유</th></tr>\(decisions)</table></details>
    <script>
    const data=JSON.parse(new TextDecoder().decode(Uint8Array.from(atob('\(encoded)'),c=>c.charCodeAt(0))));
    const screen=document.getElementById('screen'),dialog=document.getElementById('detail');
    let current;
    function reference(c){return 'notion-fixtures/evaluations/'+data.run+'/'+data.evaluation+'/index.html#node='+c.node+(c.line===undefined?'':'&line='+c.line);}
    function notify(message){const n=document.getElementById('notice');n.textContent=message;n.hidden=false;clearTimeout(window.noticeTimer);window.noticeTimer=setTimeout(()=>n.hidden=true,2500);}
    async function copy(c){
      const value=reference(c);
      try{if(!navigator.clipboard)throw Error('clipboard unavailable');await navigator.clipboard.writeText(value);notify('ノード参照をコピーしました');}
      catch(error){
        // file:// browsers may deny Clipboard API. Fall back to a selected field.
        const field=document.createElement('textarea');field.value=value;(dialog.open?dialog:document.body).append(field);field.select();
        const ok=document.execCommand('copy');field.remove();
        if(ok)notify('노드 참조를 복사했습니다');else{show(c);const ref=document.getElementById('reference');ref.focus();ref.select();notify('자동 복사 불가: 선택된 참조를 직접 복사하세요');}
      }
    }
    function show(c){current=c;const node=data.nodes.find(n=>n.id===c.node);
      document.getElementById('heading').textContent=data.scenario+' / node '+c.node;
      document.getElementById('text').textContent=c.text;
      document.getElementById('info').textContent=JSON.stringify({candidate:c,rawAx:node},null,2);
      document.getElementById('reference').value=reference(c);
      if(!dialog.open)dialog.showModal();
    }
    const toggle=document.createElement('button');toggle.textContent='노드 / 라인 박스 전환';screen.before(toggle);
    let lineMode=false;toggle.onclick=()=>{lineMode=!lineMode;document.querySelectorAll('.linebox').forEach(e=>e.hidden=!lineMode);document.querySelectorAll('.box:not(.linebox),.number:not(.linebox)').forEach(e=>e.hidden=lineMode && e.dataset.hasLines==='true');};
    if(data.selectionRegion){const r=data.selectionRegion,b=document.createElement('div');Object.assign(b.style,{position:'absolute',pointerEvents:'none',border:'2px dashed purple',left:(r.x-\(before.minX))+'px',top:(r.y-\(before.minY))+'px',width:r.width+'px',height:r.height+'px'});screen.append(b);}

    for(const c of data.selected){
      for(const line of c.lineRanges||[]){const b=document.createElement('button'),f=line.box;b.className='box linebox';b.hidden=true;b.style.borderColor='blue';Object.assign(b.style,{left:(f.x-\(before.minX))+'px',top:(f.y-\(before.minY))+'px',width:f.width+'px',height:f.height+'px'});b.onclick=()=>show({...c,...line});b.title='노드 '+c.node+' / 라인 '+line.line;screen.append(b);const label=document.createElement('button');label.className='number linebox';label.hidden=true;label.textContent=c.node+'.'+line.line;Object.assign(label.style,{left:b.style.left,top:b.style.top});label.onclick=e=>{e.stopPropagation();copy({...c,...line});};screen.append(label);}

      const f=c.box,box=document.createElement('button');box.type='button';box.className=c.textSource==='AXTitle'?'box title-source':'box';box.dataset.hasLines=String((c.lineRanges||[]).length>0);box.setAttribute('aria-label','노드 '+c.node+' 상세');
      Object.assign(box.style,{left:(f.x-\(before.minX))+'px',top:(f.y-\(before.minY))+'px',width:f.width+'px',height:f.height+'px'});box.onclick=()=>show(c);screen.append(box);
      const number=document.createElement('button');number.type='button';number.className='number';number.dataset.hasLines=box.dataset.hasLines;number.textContent=c.node;number.title='노드 참조 복사';
      Object.assign(number.style,{left:box.style.left,top:box.style.top});number.onclick=e=>{e.stopPropagation();copy(c);};screen.append(number);
    }
    document.getElementById('close').onclick=()=>dialog.close();
    document.getElementById('copyDetail').onclick=()=>copy(current);
    dialog.onclick=e=>{if(e.target===dialog){const r=dialog.getBoundingClientRect();if(e.clientX<r.left||e.clientX>r.right||e.clientY<r.top||e.clientY>r.bottom)dialog.close();}};
    </script>
    """
    try report.write(to:output.appendingPathComponent("index.html"),atomically:true,encoding:.utf8)
    print(output.path)
}
if CommandLine.arguments.contains("build-paragraphs") {
    do {
        let folder = URL(fileURLWithPath:CommandLine.arguments.last!)
        let nodes = try JSONSerialization.jsonObject(with:Data(contentsOf:folder.appendingPathComponent("rawAx.json"))) as! [[String:Any]]
        let selected = try JSONSerialization.jsonObject(with:Data(contentsOf:folder.appendingPathComponent("candidate.json"))) as! [[String:Any]]
        let data = try JSONSerialization.data(withJSONObject:AXParagraphBuilder.build(nodes:nodes,selected:selected),options:[.sortedKeys])
        print(String(decoding:data,as:UTF8.self))
        exit(0)
    } catch { fputs("\(error)\n",stderr); exit(1) }
}
let research = ["--offscreen-study", "--control-title-study", "--disable-1pt-filter"].contains(where:CommandLine.arguments.contains) || !CommandLine.arguments.contains("collect") || (CommandLine.arguments.contains("--activation") && !CommandLine.arguments.contains("manual"))
if research {
    do { try run() } catch { fputs("\(error)\n",stderr); exit(1) }
} else {
    let provider = NativeSessionAXProvider()
    do {
        let input = try AXReportInput(arguments:CommandLine.arguments)
        let snapshot = try await provider.collect(input.request)
        await provider.endSession()
        print(try input.write(snapshot,collector:"evaluation").path)
    } catch { await provider.endSession(); fputs("\(error)\n",stderr); exit(1) }
}
