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
            if units[owner] == nil {
                order.append(owner)
                units[owner] = ["node":owner,"kind":"paragraph","text":text,"box":rect(frame),"members":[Int](),"unitType":type,
                    "status":"translation_unit_candidate_unverified","source":source+" / native frame","semanticParagraphConfirmed":false]
            }
            var unit = units[owner]!
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
                    if unit["originalBox"] == nil { unit["originalBox"] = type == "selected_text" ? candidate["originalBox"] ?? rect(frame) : rect(frame) }
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
            var fragments = [box(unit["box"])]
            if let occlusions = unit["previewOcclusions"] as? [[String:Any]], !occlusions.isEmpty {
                for occlusion in occlusions { fragments = fragments.flatMap { PreviewOcclusion.visibleBoxes($0, behind:box(occlusion["panelFrame"])) } }
                if unit["originalBox"] == nil { unit["originalBox"] = unit["box"] }
                unit["visibleBoxes"] = fragments.map(rect); unit["box"] = rect(fragments.first ?? .zero)
            }
            let f = box(unit["box"])
            return f.width > 0 && f.height > 0 ? unit : nil
        }
    }
}
