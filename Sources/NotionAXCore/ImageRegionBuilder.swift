import Foundation

package enum ImageRegionBuilder {
    static func build(rows: [[String:Any]], selection: CGRect,
                      viewport: (Int) -> CGRect, visible: (Int) -> Bool,
                      occlusions: (Int) -> [CGRect]) -> [[String:Any]] {
        func classes(_ id:Int) -> [String] { rows[id]["domClasses"] as? [String] ?? [] }
        func box(_ id:Int) -> CGRect? {
            guard let b = rows[id]["frame"] as? [String:Double],
                  let x=b["x"],let y=b["y"],let w=b["width"],let h=b["height"],
                  [x,y,w,h].allSatisfy(\.isFinite),w>1,h>1 else { return nil }
            return CGRect(x:x,y:y,width:w,height:h)
        }
        func encoded(_ r:CGRect) -> [String:Double] { ["x":r.minX,"y":r.minY,"width":r.width,"height":r.height] }
        var pictures: [Int:[Int]] = [:]
        for id in rows.indices where classes(id).contains("notion-cursor-default") {
            var cursor = rows[id]["parent"] as? Int
            while let parent = cursor {
                if classes(parent).contains("notion-image-block") { pictures[parent,default:[]].append(id); break }
                cursor = rows[parent]["parent"] as? Int
            }
        }
        return rows.indices.filter { classes($0).contains("notion-image-block") }.map { block in
            var item: [String:Any] = ["node":block,"status":"image_geometry_ambiguous"]
            guard let choices = pictures[block], choices.count == 1, let picture=choices.first else { return item }
            item["imageNode"] = picture
            guard let original = box(picture) else { item["status"]="image_geometry_unavailable"; return item }
            item["box"] = encoded(original)
            guard visible(picture) else { item["status"]="excluded_by_ax_visible_only"; return item }
            var effective = viewport(picture).intersection(selection)
            var parent = rows[picture]["parent"] as? Int
            while let id = parent {
                if rows[id]["role"] as? String == "AXScrollArea", let frame=box(id) { effective=effective.intersection(frame) }
                parent = rows[id]["parent"] as? Int
            }
            var regions = [original.intersection(effective)].filter { !$0.isNull && $0.width>1 && $0.height>1 }
            for panel in occlusions(picture) { regions = regions.flatMap { PreviewOcclusion.visibleBoxes($0,behind:panel) }.filter { $0.width>1 && $0.height>1 } }
            item["displayBoxes"] = regions.map(encoded)
            item["status"] = regions.isEmpty ? "outside_viewport" : "selected"
            return item
        }
    }
}
