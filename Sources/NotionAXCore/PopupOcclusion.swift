import Foundation

/// Only semantic AX dialogs and floating sidebar panels define occluders.
/// Never infer other popup boundaries from anonymous groups or CSS hashes.
package struct PopupOcclusion {
    private let parents: [Int:Int]
    private let panels: [(id:Int, root:Int, box:CGRect)]
    private let overlayIDs: Set<Int>
    private let sidebarIDs: Set<Int>
    private let unresolved: [[String:Any]]
    init(rows:[[String:Any]]) {
        let parentIndex: [Int:Int] = Dictionary(uniqueKeysWithValues: rows.compactMap { row in
            guard let id=row["id"] as? Int, let parent=(row["parent"] as? Int) ?? (row["controlTextOwner"] as? Int) else { return nil }
            return (id,parent)
        })
        parents = parentIndex
        let byID=Dictionary(uniqueKeysWithValues:rows.compactMap { row -> (Int,[String:Any])? in
            guard let id=row["id"] as? Int else { return nil }; return (id,row)
        })
        func chain(_ id:Int)->[Int] {
            var result:[Int]=[], cursor:Int?=id
            while let id=cursor, !result.contains(id) { result.append(id);cursor=parentIndex[id] }
            return result
        }
        func frame(_ row:[String:Any])->CGRect? {
            guard let f=row["frame"] as? [String:Double],let x=f["x"],let y=f["y"],let w=f["width"],let h=f["height"],
                  [x,y,w,h].allSatisfy(\.isFinite),w>=0,h>1 else { return nil }
            return CGRect(x:x,y:y,width:w,height:h)
        }
        let overlays = Set(rows.compactMap { row -> Int? in
            (row["domClasses"] as? [String] ?? []).contains("notion-overlay-container") ? row["id"] as? Int : nil
        })
        overlayIDs = overlays
        var found:[(id:Int,root:Int,box:CGRect)]=[]
        for row in rows {
            guard row["popupVisibleOnly"] as? Bool != false, (row["domClasses"] as? [String] ?? []).contains("notion-sidebar"),
                  let id=row["id"] as? Int,let panel=frame(row),panel.width>1 else { continue }
            let ancestors=chain(id)
            guard let host=ancestors.dropFirst().compactMap({byID[$0]}).first(where:{($0["domClasses"] as? [String] ?? []).contains("notion-sidebar-container")}),
                  let hostFrame=frame(host),hostFrame.width<=1,
                  abs(panel.minX-hostFrame.minX)<=1,
                  let root=ancestors.first(where:{byID[$0]?["role"] as? String == "AXWebArea"}) else { continue }
            found.append((id,root,panel))
        }
        // Ambiguous multiple panels are deliberately unsupported.
        sidebarIDs = Set(found.map(\.id))
        var accepted = found.count == 1 ? found : []
        for row in rows {
            guard row["popupVisibleOnly"] as? Bool != false, row["subrole"] as? String == "AXApplicationDialog",
                  let id=row["id"] as? Int,let panel=frame(row),panel.width>1 else { continue }
            let ancestors=chain(id)
            guard ancestors.contains(where:{overlays.contains($0)}),
                  // A full-overlay dialog can describe a translucent backdrop,
                  // not a verified opaque panel. Leave it unsupported.
                  !ancestors.contains(where:{ ancestor in
                      guard overlays.contains(ancestor),let row=byID[ancestor],let overlay=frame(row) else { return false }
                      return panel.contains(overlay)
                  }),
                  !ancestors.contains(where:{(byID[$0]?["domClasses"] as? [String] ?? []).contains("notion-peek-renderer")}),
                  !ancestors.contains(where:{(byID[$0]?["domClasses"] as? [String] ?? []).contains("notion-text-action-menu")}),
                  let root=ancestors.first(where:{byID[$0]?["role"] as? String == "AXWebArea"}) else { continue }
            if !accepted.contains(where:{$0.root == root && $0.box == panel}) { accepted.append((id,root,panel)) }
        }
        panels = accepted
        // Report nonempty overlay branches with no semantic boundary. Do not
        // publish a guessed rectangle for these candidates.
        var contentBranches=Set<Int>(), knownBranches=Set<Int>()
        let acceptedIDs=Set(accepted.map(\.id))
        for row in rows {
            guard let id=row["id"] as? Int else { continue }
            let ancestors=chain(id)
            guard let branch=ancestors.first(where:{ parentIndex[$0].map { overlays.contains($0) } ?? false }) else { continue }
            if let f=frame(row),f.width>1 { contentBranches.insert(branch) }
            let classes=row["domClasses"] as? [String] ?? []
            if acceptedIDs.contains(id) || classes.contains("notion-text-action-menu") || classes.contains("notion-peek-renderer") { knownBranches.insert(branch) }
        }
        unresolved=contentBranches.subtracting(knownBranches).sorted().map {
            ["kind":"unsupported_overlay", "node":$0,"reason":"no_verified_semantic_panel_boundary"]
        }
    }
    var diagnostics: [[String:Any]] {
        panels.map { ["kind":sidebarIDs.contains($0.id) ? "floating_sidebar" : "ax_application_dialog", "node":$0.id, "webArea":$0.root,
                      "panelFrame":rect($0.box), "rule":sidebarIDs.contains($0.id) ? "collapsed-semantic-host-v1" : "semantic-dialog-in-overlay-v1"] } + unresolved
    }
    func masks(for node:Int)->[CGRect] {
        var chain=Set<Int>(),cursor:Int?=node
        while let id=cursor,chain.insert(id).inserted { cursor=parents[id] }
        guard chain.isDisjoint(with:overlayIDs) else { return [] }
        return panels.filter { chain.contains($0.root) && !chain.contains($0.id) }.map(\.box)
    }
}
