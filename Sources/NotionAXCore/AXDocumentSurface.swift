import Foundation

/// Snapshot-local identifiers must never be used to join different captures.
public struct AXDocumentSurface: Codable, Sendable {
    public let node: Int
    public let url: String?
    public let frame: AXBox?
    public let bodyNodes: [Int]
    public let dialogBoxes: [AXBox]
}

extension AXExtractionSnapshot {
    public var documentSurfaces: [AXDocumentSurface] {
        struct Metadata: Decodable { let documentSurfaces: [AXDocumentSurface]? }
        return (try? JSONDecoder().decode(Metadata.self, from: metadata).documentSurfaces) ?? []
    }
}

package enum AXDocumentSurfaceBuilder {
    static func build(rows: [[String: Any]]) -> [[String: Any]] {
        let byID = Dictionary(uniqueKeysWithValues: rows.compactMap { row in
            (row["id"] as? Int).map { ($0, row) }
        })
        func chain(_ id: Int) -> [Int] {
            var result: [Int] = [], seen = Set<Int>(), cursor: Int? = id
            while let id = cursor, seen.insert(id).inserted {
                result.append(id)
                cursor = (byID[id]?["parent"] as? Int) ?? (byID[id]?["controlTextOwner"] as? Int)
            }
            return result
        }
        func classes(_ id: Int) -> [String] { byID[id]?["domClasses"] as? [String] ?? [] }
        return rows.compactMap { root in
            guard root["role"] as? String == "AXWebArea", root["title"] as? String != "Tab Bar",
                  let id = root["id"] as? Int else { return nil }
            var body: [Int] = [], dialogs: [[String: Double]] = []
            for row in rows {
                guard let node = row["id"] as? Int else { continue }
                let ancestry = chain(node)
                guard ancestry.first(where: { byID[$0]?["role"] as? String == "AXWebArea" }) == id else { continue }
                let excluded = ancestry.contains { ancestor in
                    let c = classes(ancestor)
                    return c.contains("notion-peek-renderer") || c.contains("notion-sidebar") ||
                        c.contains("notion-topbar") || c.contains("notion-overlay-container") ||
                        byID[ancestor]?["subrole"] as? String == "AXApplicationDialog"
                }
                if !excluded && classes(node).contains("notion-selectable") { body.append(node) }
                guard row["subrole"] as? String == "AXApplicationDialog",
                      row["popupVisibleOnly"] as? Bool != false,
                      !ancestry.contains(where: { classes($0).contains("notion-peek-renderer") }),
                      let frame = row["frame"] as? [String: Double],
                      let x = frame["x"], let y = frame["y"], let w = frame["width"], let h = frame["height"],
                      [x,y,w,h].allSatisfy(\.isFinite), w > 1, h > 1 else { continue }
                let panel = CGRect(x:x,y:y,width:w,height:h)
                if let f = root["frame"] as? [String: Double],
                   let rx=f["x"], let ry=f["y"], let rw=f["width"], let rh=f["height"],
                   panel.contains(CGRect(x:rx,y:ry,width:rw,height:rh)) { continue }
                if !dialogs.contains(frame) { dialogs.append(frame) }
            }
            var surface: [String: Any] = ["node":id,"bodyNodes":body,"dialogBoxes":dialogs]
            if let url = root["documentURL"] as? String { surface["url"] = url }
            if let frame = root["frame"] { surface["frame"] = frame }
            return surface
        }
    }
}
