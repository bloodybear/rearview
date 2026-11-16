import Foundation

public enum AXParagraphBuilder {
    // Also used for saved-input parity checks, without an AX process or markers.
    public static func build(nodes: [[String: Any]], selected: [[String: Any]]) -> [[String: Any]] {
        let byID = Dictionary(uniqueKeysWithValues: nodes.map { ($0["id"] as! Int, $0) })
        func ancestors(_ id: Int) -> [Int] {
            var result: [Int] = [], current = byID[id]?["parent"] as? Int
            while let id = current, !result.contains(id) { result.append(id); current = byID[id]?["parent"] as? Int }
            return result
        }
        func box(_ value: Any?) -> CGRect {
            guard let r = value as? [String: Double] else { return .zero }
            return CGRect(x:r["x"] ?? 0,y:r["y"] ?? 0,width:r["width"] ?? 0,height:r["height"] ?? 0)
        }
        var children: [Int:[Int]] = [:]
        for n in nodes { if let parent = n["parent"] as? Int { children[parent,default:[]].append(n["id"] as! Int) } }
        let selectedIDs = Set(selected.compactMap { $0["node"] as? Int })
        var groupOwners: [Int:(group:Int,control:Int,text:String)] = [:]
        func leaves(_ id:Int) -> [Int]? {
            guard let n=byID[id], n["mathOwner"] == nil else { return nil }
            if n["role"] as? String == "AXStaticText" {
                return (n["recoveredText"] as? String ?? n["value"] as? String ?? "").isEmpty ? [] : [id]
            }
            guard n["role"] as? String == "AXGroup" else { return nil }
            var result:[Int]=[]
            for child in children[id] ?? [] { guard let found=leaves(child) else{return nil};result += found }
            return result
        }
        for n in nodes where ["AXButton","AXPopUpButton","AXRadioButton"].contains(n["role"] as? String ?? "") {
            let control=n["id"] as! Int
            var branches:[(Int,[Int])]=[], valid=true
            for child in children[control] ?? [] {
                guard let found=leaves(child) else{valid=false;break}
                if !found.isEmpty { branches.append((child,found)) }
            }
            guard valid, branches.count == 2 else{continue}
            let texts=branches.map { $0.1.map { byID[$0]?["recoveredText"] as? String ?? byID[$0]?["value"] as? String ?? "" } }
            let icons=texts.map { $0.allSatisfy(AXEmojiClassification.isSingleEmoji) }
            guard icons.filter({$0}).count == 1,
                  branches.allSatisfy({ byID[$0.0]?["role"] as? String == "AXGroup" && $0.1.allSatisfy { selectedIDs.contains($0) } && box(byID[$0.0]?["frame"]).width > 1 && box(byID[$0.0]?["frame"]).height > 1 && [box(byID[$0.0]?["frame"]).minX,box(byID[$0.0]?["frame"]).minY,box(byID[$0.0]?["frame"]).width,box(byID[$0.0]?["frame"]).height].allSatisfy(\.isFinite) }) else{continue}
            for (i,branch) in branches.enumerated() {
                for leaf in branch.1 { groupOwners[leaf]=(branch.0,control,texts[i].joined()) }
            }
        }
        var containers = Set<Int>()
        for n in nodes where n["role"] as? String == "AXTextArea" {
            for id in ancestors(n["id"] as! Int) where byID[id]?["role"] as? String == "AXTextArea" { containers.insert(id) }
        }
        var units: [Int: [String: Any]] = [:], order: [Int] = []
        for candidate in selected {
            let id = candidate["node"] as! Int
            var owner = id, text = candidate["text"] as! String
            var frame = box(candidate["originalBox"] ?? candidate["box"])
            var type = "selected_text", source = (byID[id]?["role"] as? String ?? "") + "." + (candidate["textSource"] as? String ?? "")
            if candidate["textSource"] as? String == "AXValue", candidate["controlTextOwner"] == nil {
                for parent in ancestors(id) {
                    let area = byID[parent]!, role = area["role"] as? String ?? "", f = box(area["frame"])
                    let usable = f.width > 1 && f.height > 1
                    if role == "AXTextArea" {
                        let omitted = area["valueCollection"] as? String == "omitted_parent_value"
                        let value = area["value"] as? String ?? ""
                        if !containers.contains(parent), (omitted || !value.isEmpty), usable {
                            owner=parent; text=omitted ? "" : value; frame=f; type="native_textarea"; source="AXTextArea.AXValue"
                        }
                        break
                    }
                    if ["AXButton","AXPopUpButton","AXRadioButton"].contains(role) {
                        if let title = area["title"] as? String, !title.isEmpty, title.contains(text), usable {
                            owner=parent; text=title; frame=f; type="native_control"; source=role+".AXTitle"
                        }
                        break
                    }
                }
            }
            if let split=groupOwners[id] {
                owner=split.group; text=split.text; frame=box(byID[owner]?["frame"])
                type="native_control_group"; source="AXGroup text leaves"
            }
            // A verified text parent changes geometry only, never paragraph identity.
            var resolved = type == "native_textarea"
            if type == "selected_text",
               let parents = byID[id]?["ownershipParentFrames"] as? [[String:Any]],
               let group = parents.first(where:{ $0["role"] as? String == "AXGroup" }),
               group["singleTextOwnerVerified"] as? Bool == true {
                let proposed = box(group["frame"])
                if proposed.width > 1, proposed.height > 1,
                   let control = byID[id]?["controlTextOwner"] as? Int,
                   box(byID[control]?["frame"]).contains(proposed) {
                    frame = proposed; resolved = true
                }
            }
            if type == "native_control",
               ancestors(id).contains(where: { (byID[$0]?["domClasses"] as? [String] ?? []).contains("notion-table-view-cell") }),
               let groupID = ancestors(id).prefix(while: { $0 != owner }).first(where: { byID[$0]?["role"] as? String == "AXGroup" }) {
                let children = nodes.filter { $0["parent"] as? Int == groupID }
                let selectedIDs = Set(selected.compactMap { $0["node"] as? Int })
                let proposed = box(byID[groupID]?["frame"])
                if !children.isEmpty, children.allSatisfy({ $0["role"] as? String == "AXStaticText" && selectedIDs.contains($0["id"] as! Int) }),
                   proposed.width > 1, proposed.height > 1, box(byID[owner]?["frame"]).contains(proposed) {
                    frame = proposed; resolved = true
                }
            }
            if units[owner] == nil {
                order.append(owner)
                units[owner] = ["node":owner,"kind":"paragraph","text":text,"box":rect(frame),"members":[Int](),"unitType":type,
                    "status":"translation_unit_candidate_unverified","source":source+" / native frame","semanticParagraphConfirmed":false]
            }
            var unit = units[owner]!
            if let split=groupOwners[id] {
                unit["controlGroupOwner"]=split.control
                unit["paragraphGrouping"]="control_icon_label_subgroups"
            }
            if resolved { unit["resolvedTextArea"] = true; unit["layoutExpansionRight"] = Double(frame.maxX) }
            // The node frame (not the unbounded line range) proves that text
            // paints past this group. Its end is evidence, not the capacity limit.
            if resolved, type != "native_textarea",
               let cellID = ancestors(id).first(where: { (byID[$0]?["domClasses"] as? [String] ?? []).contains("notion-table-view-cell") }) ??
                    (byID[id]?["controlTextOwner"] as? Int).flatMap({ control in
                        ancestors(control).first(where: { (byID[$0]?["domClasses"] as? [String] ?? []).contains("notion-table-view-cell") })
                    }) {
                let nodeFrame = box(byID[id]?["frame"]), cellFrame = box(byID[cellID]?["frame"])
                if byID[id]?["role"] as? String == "AXStaticText",
                   nodeFrame.maxX > frame.maxX + 0.5, cellFrame.maxX > frame.maxX,
                   nodeFrame.minX >= cellFrame.minX - 0.5, nodeFrame.maxX <= cellFrame.maxX + 0.5 {
                    unit["cellExpansionRight"] = Double(cellFrame.maxX)
                }
            }
            unit["members"] = (unit["members"] as! [Int]) + [id]
            var current: Int? = id, code = false, visited = Set<Int>()
            while let n = current, let row = byID[n], visited.insert(n).inserted {
                if (row["domClasses"] as? [String] ?? []).contains("notion-code-block") { code=true; break }
                current = (row["controlTextOwner"] ?? row["parent"]) as? Int
            }
            unit["isCodeBlock"] = (unit["isCodeBlock"] as? Bool ?? false) || code
            unit["protectNonSourceText"] = unit["isCodeBlock"]
            for (key, panelKey) in [("timelineOcclusion","panelFrame"),("timelineHeaderOcclusion","headerFrame"),("tableHeaderOcclusion","headerFrame")] {
                if let occlusion = candidate[key] as? [String: Any] {
                    if unit["originalBox"] == nil { unit["originalBox"] = rect(frame) }
                    unit[key] = occlusion
                    let original = box(unit["originalBox"]), panel = box(occlusion[panelKey])
                    let clipped = key == "timelineOcclusion" ? TimelineClipping.visibleBox(original, behind:panel) : StickyHeaderClipping.belowHeader(box(unit["box"]), header:panel)
                    unit["box"] = rect(clipped.isNull ? .zero : clipped)
                }
            }
            if let occlusions = candidate["previewOcclusions"] { unit["previewOcclusions"] = occlusions }
            units[owner] = unit
        }
        return order.compactMap { id in
            var unit = units[id]!
            if let probe = byID[id]?["paragraphLineInvestigation"] as? [String: Any] {
                unit["lineRanges"] = probe["lineRanges"] ?? []
                for key in ["lineRangeStatus","lineMethod"] { unit[key] = probe[key] }
                unit["lineSourceText"] = probe["lineSourceText"] ?? unit["text"]
                unit["lineSourceNodes"] = probe["sourceNodes"] ?? []
                if byID[id]?["valueCollection"] as? String == "omitted_parent_value" {
                    unit["text"] = probe["lineSourceText"] ?? ""
                    unit["textOrigin"] = "text_leaves_parent_value_omitted"
                }
                if let content = probe["inlineContent"] as? [[String:Any]], !content.isEmpty {
                    unit["inlineContent"] = content; unit["mathPolicy"] = probe["mathPolicy"]
                }
            } else { unit["lineRanges"] = [] }
            if unit["lineRangeStatus"] as? String == "complete_unverified" {
                unit["translationSourceText"] = (unit["inlineContent"] as? [[String:Any]]).map { $0.filter { $0["kind"] as? String == "text" }.map { $0["text"] as? String ?? "" }.joined() } ?? unit["lineSourceText"]
            }
            if unit["isCodeBlock"] as? Bool == true || unit["inlineContent"] != nil {
                unit.removeValue(forKey:"layoutExpansionRight")
            }
            unit["codeSegments"] = byID[id]?["codeSegments"]
            // Infer symmetric inset only for existing expansion targets.
            if unit["layoutExpansionRight"] != nil, unit["cellExpansionRight"] == nil {
                let area = box(unit["originalBox"] ?? unit["box"])
                let ids = unit["members"] as? [Int] ?? []
                let frames = ids.compactMap { id -> CGRect? in
                    guard byID[id]?["role"] as? String == "AXStaticText" else { return nil }
                    let f = box(byID[id]?["frame"])
                    return f.width > 0 && f.height > 0 && !f.isInfinite && !f.isNull ? f : nil
                }
                var reason = "missing_node_geometry"
                if !frames.isEmpty, frames.count == ids.count {
                    let inset = frames.map(\.minX).min()! - area.minX
                    let right = area.maxX - inset
                    unit["inferredHorizontalInset"] = Double(inset)
                    unit["paddingCandidateRight"] = Double(right)
                    let clips = selected.filter { ids.contains($0["node"] as? Int ?? -1) }.compactMap { $0["effectiveClipRegion"] }.map(box)
                    let horizontalClip = clips.contains { area.minX <= $0.minX + 0.5 || area.maxX >= $0.maxX - 0.5 }
                        || abs(box(unit["box"]).minX-area.minX) > 0.5 || abs(box(unit["box"]).maxX-area.maxX) > 0.5
                        || unit["previewOcclusions"] != nil
                    if horizontalClip { reason = "horizontal_clipping_uncertain" }
                    else if inset <= 0.5 || right <= frames.map(\.minX).min()! { reason = "no_valid_inset" }
                    else if frames.contains(where: { $0.maxX > right + 0.5 }) { reason = "node_exceeds_candidate" }
                    else { unit["layoutExpansionRight"] = Double(right); reason = "applied" }
                }
                unit["symmetricPaddingStatus"] = reason
            }
            var fragments = [box(unit["box"])]
            if let occlusions = unit["previewOcclusions"] as? [[String:Any]], !occlusions.isEmpty {
                for occlusion in occlusions { fragments = fragments.flatMap { PreviewOcclusion.visibleBoxes($0, behind:box(occlusion["panelFrame"])) } }
                if unit["originalBox"] == nil { unit["originalBox"] = unit["box"] }
                unit["visibleBoxes"] = fragments.map(rect); unit["box"] = rect(fragments.first ?? .zero)
            }
            if let right = unit.removeValue(forKey:"cellExpansionRight") as? Double,
               unit["isCodeBlock"] as? Bool != true, unit["inlineContent"] == nil {
                unit["layoutExpansionRight"] = right
                unit["layoutExpansionReason"] = "text_node_overflows_paragraph_to_cell"
                var display = box(unit["originalBox"] ?? unit["box"])
                display.size.width = max(display.width, right-display.minX)
                for (key, panelKey) in [("timelineOcclusion","panelFrame"),("timelineHeaderOcclusion","headerFrame"),("tableHeaderOcclusion","headerFrame")] {
                    if let occlusion = unit[key] as? [String:Any] {
                        let panel = box(occlusion[panelKey])
                        display = key == "timelineOcclusion" ? TimelineClipping.visibleBox(display, behind:panel) : StickyHeaderClipping.belowHeader(display, header:panel)
                        if display.isNull { display = .zero }
                    }
                }
                var displayFragments = display.isEmpty ? [] : [display]
                for occlusion in unit["previewOcclusions"] as? [[String:Any]] ?? [] {
                    displayFragments = displayFragments.flatMap { PreviewOcclusion.visibleBoxes($0, behind:box(occlusion["panelFrame"])) }
                }
                unit["displayBoxes"] = displayFragments.map(rect)
            }
            let f = box(unit["box"])
            return f.width > 0 && f.height > 0 ? unit : nil
        }
    }
}
