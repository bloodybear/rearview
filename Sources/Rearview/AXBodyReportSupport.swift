#if !LST_EXCLUDE_DEBUG_FEATURES
import AppKit
import NotionAXCore

/// Restore value snapshots for native saved-report review, never query AX.
@MainActor enum AXBodyReportSupport {
    static func restore(folder:URL,current:SessionCoordinator.AXTranslatedFrame) async throws -> AXBodyReuse? {
        let path=folder.appendingPathComponent("retained-body-rawAx.json")
        guard FileManager.default.fileExists(atPath:path.path) else { return nil }
        func read(_ suffix:String)throws->Data { try Data(contentsOf:folder.appendingPathComponent("retained-body-"+suffix)) }
        let snapshot=try AXExtractionSnapshot(nodes:read("rawAx.json"),selected:read("candidate.json"),paragraphs:read("paragraphs.json"),metadata:read("metadata.json"))
        let metadata=try JSONSerialization.jsonObject(with:current.frame.snapshot.metadata) as! [String:Any]
        guard let fields=metadata["bodyReuse"] as? [String:Any], fields["status"] as? String == "reused",
              let image=NSBitmapImageRep(data:try read("source.png"))?.cgImage,
              image.width==current.frame.image.width,image.height==current.frame.image.height,
              let r=metadata["selectionRegion"] as? [String:Double],let w=metadata["windowFrame"] as? [String:Double] else { throw CocoaError(.coderInvalidValue) }
        func rect(_ f:[String:Double])->CGRect { CGRect(x:f["x"]!,y:f["y"]!,width:f["width"]!,height:f["height"]!) }
        let scope=AXBodyScope(generation:0,processID:0,windowID:0,window:rect(w),selection:rect(r),pixels:CGSize(width:image.width,height:image.height),direction:"saved",protection:false)
        let entries=try JSONDecoder().decode([AXParagraphTranslation].self,from:read("translations.json"))
        let source=SessionCoordinator.AXTranslatedFrame(frame:.init(snapshot:snapshot,image:image,frameID:(fields["sourceFrameID"] as? NSNumber)?.uint64Value ?? 0,receivedAt:0),entries:entries)
        let retention=AXBodyRetention()
        retention.store(value:source,artwork:await AXLineRendering.render(source),scope:scope)
        guard let original=retention.resolve(snapshot:current.frame.snapshot,scope:scope).0 else { return nil }
        // Persisted effective masks include a parent pruned by a nested modal;
        // reconstruct them directly rather than pretending a live transition ran.
        guard let raw=fields["panels"] else { return original }
        let panels=try JSONDecoder().decode([CGRect].self,from:JSONSerialization.data(withJSONObject:raw))
        var regions=original.body.regions
        for panel in panels { regions=regions.flatMap { AXBodyRetention.subtract($0,panel) } }
        return AXBodyReuse(body:original.body,regions:regions,panels:panels)
    }
}
#endif
