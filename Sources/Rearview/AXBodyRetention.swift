import AppKit
import NotionAXCore

/// Value data only. The epoch changes on explicit session/target/settings resets,
/// not on the ordinary visual revisions which opening a popup itself produces.
struct AXBodyScope: Equatable, Sendable {
    let generation: Int
    let processID: pid_t
    let windowID: CGWindowID
    let window: CGRect
    let selection: CGRect
    let pixels: CGSize
    let direction: String
    let protection: Bool
}

struct AXBodyReuseDiagnostic: Codable, Sendable {
    var status: String
    var sourceFrameID: UInt64?
    var sourceCollectedAt: String?
    var documentURL: String?
    var panels: [CGRect] = []
    var inheritedPanels: [CGRect]? = nil
}

final class AXRetainedBody: @unchecked Sendable {
    let scope: AXBodyScope
    let surface: AXDocumentSurface
    let frame: SessionCoordinator.AXFrameSnapshot
    let entries: [AXParagraphTranslation]
    let artwork: AXRenderArtwork
    let imageOCR: AXImageOCRResult
    let paragraphNodes: Set<Int>
    let regions: [CGRect] // bottom-left full-frame pixels
    init(scope: AXBodyScope, surface: AXDocumentSurface, value: SessionCoordinator.AXTranslatedFrame,
         artwork: AXRenderArtwork, paragraphNodes: Set<Int>, regions: [CGRect], imageOCR: AXImageOCRResult) {
        self.scope=scope; self.surface=surface; frame=value.frame; entries=value.entries
        self.artwork=artwork; self.paragraphNodes=paragraphNodes; self.regions=regions; self.imageOCR=imageOCR
    }
}
struct AXBodyReuse: Sendable {
    let body: AXRetainedBody
    let regions: [CGRect]
    let panels: [CGRect]
    var imageLayers: [AXImageOCRLayer] {
        body.imageOCR.layers.map { layer in
            var copy=layer
            copy.displayPixelBoxes = (layer.displayPixelBoxes ?? [layer.pixelBox]).flatMap { box in
                regions.map { $0.intersection(box) }.filter { !$0.isNull && !$0.isEmpty }
            }
            return copy
        }.filter { !($0.displayPixelBoxes ?? []).isEmpty }
    }
}

@MainActor final class AXBodyRetention {
    private(set) var body: AXRetainedBody?
    private var previousPanels: [CGRect] = []
    func reset() { body=nil;previousPanels=[] }
    static func pixel(_ r: CGRect, scope: AXBodyScope) -> CGRect {
        let sx=scope.pixels.width/scope.selection.width, sy=scope.pixels.height/scope.selection.height
        return CGRect(x:(r.minX-scope.selection.minX)*sx,y:(scope.selection.maxY-r.maxY)*sy,width:r.width*sx,height:r.height*sy)
    }
    private static func limited(_ snapshot: AXExtractionSnapshot) -> Bool {
        let m=(try? JSONSerialization.jsonObject(with:snapshot.metadata)) as? [String:Any] ?? [:]
        return snapshot.status == .failed || m["truncated"] as? Bool == true || m["rangeLimitReached"] as? Bool == true
    }
    func resolve(snapshot: AXExtractionSnapshot, scope: AXBodyScope) -> (AXBodyReuse?, AXBodyReuseDiagnostic) {
        func no(_ reason:String) -> (AXBodyReuse?,AXBodyReuseDiagnostic) { (nil,.init(status:reason)) }
        guard !snapshot.imageViewerActive else { previousPanels=[];return no("image_viewer_active") }
        guard !Self.limited(snapshot) else { previousPanels=[];return no("collection_unavailable_or_limited") }
        guard let body else { return no("no_previous_body") }
        guard body.scope == scope else { reset(); return no("scope_changed") }
        guard let current=snapshot.documentSurfaces.first(where: { $0.url == body.surface.url && $0.frame == body.surface.frame }),
              let url=current.url, !url.isEmpty else { reset(); return no("document_changed_or_unavailable") }
        guard current.bodyNodes.isEmpty else { previousPanels=[];return no("fresh_body_available") }
        guard !current.dialogBoxes.isEmpty else { previousPanels=[];return no("no_verified_dialog") }
        let currentPanels=current.dialogBoxes.map { Self.pixel($0.cgRect,scope:scope) }
        // A nested modal can prune its still-painted parent from AX too. Retain
        // that previously verified frame only for strict four-edge containment.
        // Shared-edge resize/replacement and moves outside it do not accumulate
        // old holes. This is an explicit geometry policy, not proven DOM ancestry:
        // an inward move to a smaller popup can conservatively over-clip text.
        let inherited=previousPanels.filter { parent in currentPanels.contains { child in
            child.minX>parent.minX && child.minY>parent.minY && child.maxX<parent.maxX && child.maxY<parent.maxY
        } }
        let panels=currentPanels+inherited.filter { !currentPanels.contains($0) }
        // Keep only maximal masks in the transition state: a retained outer
        // panel already covers nested descendants, so deep nesting stays bounded.
        previousPanels=panels.filter { panel in !panels.contains { other in other != panel && other.contains(panel) } }
        var regions=body.regions
        for panel in panels { regions=regions.flatMap { Self.subtract($0,panel) } }
        let m=(try? JSONSerialization.jsonObject(with:body.frame.snapshot.metadata)) as? [String:Any]
        return (.init(body:body,regions:regions,panels:panels),.init(status:"reused",sourceFrameID:body.frame.frameID,
            sourceCollectedAt:m?["collectedAt"] as? String,documentURL:url,panels:panels,inheritedPanels:inherited))
    }
    func store(value: SessionCoordinator.AXTranslatedFrame, artwork: AXRenderArtwork, scope: AXBodyScope) {
        let snapshot=value.frame.snapshot
        guard value.retainedBody == nil, !snapshot.imageViewerActive, !Self.limited(snapshot),
              snapshot.documentSurfaces.allSatisfy({ $0.dialogBoxes.isEmpty }),
              let surface=snapshot.documentSurfaces.first(where: { !$0.bodyNodes.isEmpty && !($0.url ?? "").isEmpty }) else { return }
        let roots=Set(surface.bodyNodes), nodes=Dictionary(uniqueKeysWithValues:snapshot.observations.map { ($0.id,$0) })
        func belongs(_ id:Int)->Bool {
            var cursor:Int?=id,seen=Set<Int>()
            while let id=cursor, seen.insert(id).inserted {
                if roots.contains(id) { return true }
                cursor=nodes[id]?.parent ?? nodes[id]?.controlTextOwner
            }
            return false
        }
        let paragraphs=snapshot.paragraphUnits.filter { belongs($0.node) }
        // Do not seed holes from a preview, floating sidebar or legacy menu.
        // Native fixed-header clipping remains part of the original display boxes.
        guard paragraphs.allSatisfy({ ($0.occlusionBoxes ?? []).isEmpty }) else { return }
        let regions=paragraphs.flatMap { $0.displayRegions }.map { Self.pixel($0.cgRect,scope:scope) }
        let imageBoxes=snapshot.imageRegions.filter { belongs($0.node) }.flatMap { $0.displayBoxes ?? [] }.map { Self.pixel($0.cgRect,scope:scope) }
        let images=AXImageOCRResult(layers:value.imageOCR.layers.filter { l in imageBoxes.contains { $0.intersects(l.pixelBox) } },
            diagnostics:value.imageOCR.diagnostics.filter { belongs($0.node) },maxConcurrentOCR:value.imageOCR.maxConcurrentOCR)
        guard !regions.isEmpty || !images.layers.isEmpty else { return }
        previousPanels=[]
        body=AXRetainedBody(scope:scope,surface:surface,value:value,artwork:artwork,paragraphNodes:Set(paragraphs.map(\.node)),
            regions:regions+imageBoxes,imageOCR:images)
    }
    nonisolated static func subtract(_ box:CGRect,_ panel:CGRect)->[CGRect] {
        let c=box.intersection(panel)
        guard !c.isNull,!c.isEmpty else{return[box]}
        return [CGRect(x:box.minX,y:box.minY,width:box.width,height:c.minY-box.minY),
            CGRect(x:box.minX,y:c.maxY,width:box.width,height:box.maxY-c.maxY),
            CGRect(x:box.minX,y:c.minY,width:c.minX-box.minX,height:c.height),
            CGRect(x:c.maxX,y:c.minY,width:box.maxX-c.maxX,height:c.height)].filter { !$0.isEmpty }
    }
}

extension AXRenderArtwork {
    /// Runs on the existing layout queue. No CoreText or source-color sampling
    /// is repeated for the retained body, and the current capture stays the base.
    func adding(_ reuse: AXBodyReuse?, size: CGSize) -> AXRenderArtwork {
        guard let reuse else { return self }
        let started=CFAbsoluteTimeGetCurrent()
        let old=reuse.body.artwork, allowed=reuse.regions
        let retainedIDs=Set(old.items.filter { old.itemNodes[$0.id].map { reuse.body.paragraphNodes.contains($0) } == true }.map(\.id))
        let fragments=old.fragments.filter { retainedIDs.contains($0.itemID) }.compactMap { f -> NativeMirrorRenderedFragment? in
            let pieces=allowed.map { $0.intersection(f.rect) }.filter { !$0.isNull && !$0.isEmpty }
            guard let box=pieces.max(by:{$0.width*$0.height < $1.width*$1.height}) else{return nil}
            return .init(itemID:f.itemID,text:f.text,rect:box,characterOffset:f.characterOffset)
        }
        let visible=Set(fragments.map(\.itemID))
        func composite(_ a:CGImage?,_ b:CGImage?)->CGImage? {
            guard let ctx=CGContext(data:nil,width:Int(size.width),height:Int(size.height),bitsPerComponent:8,bytesPerRow:0,
                space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else{return b}
            let full=CGRect(origin:.zero,size:size)
            if !allowed.isEmpty {
                ctx.saveGState();ctx.addRects(allowed);ctx.clip()
                if let a {ctx.draw(a,in:full)}
                ctx.restoreGState()
            }
            if let b {ctx.draw(b,in:full)}
            return ctx.makeImage()
        }
        func clipped(_ rects:[CGRect])->[CGRect] { rects.flatMap { r in allowed.map { $0.intersection(r) }.filter { !$0.isNull && !$0.isEmpty } } }
        let bg=composite(old.background,background),fg=composite(old.text,text),dbg=composite(old.debug,debug)
        var hover = fullTextHover
        for item in old.items where retainedIDs.contains(item.id) && visible.contains(item.id) {
            let original = old.fragments.filter { $0.itemID == item.id }
            let wasCut = old.fullTextHover.contains { $0.itemID == item.id }
            if wasCut || original.contains(where: { AXFullTextHover.isClipped($0.rect,by:allowed) }) {
                let boxes = clipped(old.clipRects + old.selectionClipRects).filter { box in original.contains { $0.rect.intersects(box) } }
                if !boxes.isEmpty { hover.append(.init(itemID:item.id,text:old.fullTextHover.first { $0.itemID == item.id }?.text ?? item.translatedText,boxes:boxes)) }
            }
        }
        let seconds=CFAbsoluteTimeGetCurrent()-started
        return AXRenderArtwork(background:bg,text:fg,debug:dbg,
            items:old.items.filter { visible.contains($0.id) }+items,fragments:fragments+self.fragments,
            clipRects:clipped(old.clipRects)+clipRects,diagnostics:diagnostics,elapsed:elapsed+seconds,
            selectionClipRects:clipped(old.selectionClipRects)+selectionClipRects,itemNodes:itemNodes,bodyReuseSeconds:seconds,fullTextHover:hover)
    }
}
