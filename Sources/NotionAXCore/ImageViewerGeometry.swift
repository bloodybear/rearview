import Foundation

struct ImageViewerGeometry {
    let panel: CGRect
    let image: CGRect
    let node: Int
    let imageNode: Int
    let toolbar: CGRect?

    static func detect(in rows: [[String: Any]]) -> Self? {
        func role(_ id: Int) -> String? { rows[id]["role"] as? String }
        func frame(_ id: Int) -> CGRect? {
            guard let box = rows[id]["frame"] as? [String: Double],
                  let x = box["x"], let y = box["y"], let w = box["width"], let h = box["height"],
                  [x, y, w, h].allSatisfy(\.isFinite), w > 1, h > 1 else { return nil }
            return CGRect(x: x, y: y, width: w, height: h)
        }
        let portals = rows.indices.filter {
            role($0) == "AXGroup" &&
                (rows[$0]["domClasses"] as? [String])?.contains("notion-default-overlay-container") == true
        }
        guard !portals.isEmpty else { return nil }
        var children: [Int: [Int]] = [:]
        for id in rows.indices {
            if let parent = rows[id]["parent"] as? Int { children[parent, default: []].append(id) }
        }
        var matches: [Self] = []
        for portal in portals {
            guard let panel = frame(portal) else { continue }
            for node in children[portal, default: []] where role(node) == "AXGroup" {
                let branches = children[node, default: []]
                guard (1...2).contains(branches.count), let root = branches.first,
                      let image = frame(root), panel.contains(image) else { continue }
                // Chromium exposes the viewer image as four nested empty groups
                // with the same visible frame. The toolbar disappears when idle.
                var chain: [Int] = []
                var cursor: Int? = root
                while let id = cursor, chain.count < 4, role(id) == "AXGroup",
                      rows[id]["subrole"] as? String == "AXEmptyGroup", frame(id) == image {
                    chain.append(id)
                    let nested = children[id, default: []]
                    cursor = nested.count == 1 ? nested.first : nil
                }
                guard chain.count == 4, let imageNode = chain.last,
                      children[imageNode, default: []].isEmpty else { continue }
                var toolbar: CGRect?
                if branches.count == 2 {
                    let bar = branches[1]
                    let buttons = children[bar, default: []]
                    guard role(bar) == "AXGroup", let box = frame(bar), panel.contains(box),
                          buttons.count > 1, buttons.allSatisfy({ role($0) == "AXButton" }),
                          buttons.contains(where: { id in
                              guard let title = rows[id]["title"] as? String, title.hasSuffix("%") else { return false }
                              return Int(title.dropLast()) != nil
                          }) else { continue }
                    toolbar = box
                }
                matches.append(Self(panel: panel, image: image, node: node, imageNode: imageNode, toolbar: toolbar))
            }
        }
        return matches.count == 1 ? matches.first : nil
    }

    func region(in selection: CGRect) -> [String: Any] {
        func encode(_ rect: CGRect) -> [String: Double] {
            ["x": rect.minX, "y": rect.minY, "width": rect.width, "height": rect.height]
        }
        let crop = image.intersection(selection)
        let pieces = toolbar.map { PreviewOcclusion.visibleBoxes(crop, behind: $0) } ?? [crop]
        let display = pieces.filter { !$0.isNull && $0.width > 1 && $0.height > 1 }
        return ["node": node, "imageNode": imageNode, "box": encode(image),
                "displayBoxes": display.map(encode), "status": display.isEmpty ? "outside_viewport" : "selected"]
    }
}
