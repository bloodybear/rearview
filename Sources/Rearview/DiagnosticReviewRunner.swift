#if !LST_EXCLUDE_DEBUG_FEATURES
import AppKit
import NotionAXCore

/// Reads an already extracted diagnostic directory. It never unzips, captures, or queries providers.
@MainActor enum DiagnosticReviewRunner {
    static func run() async -> Int32 {
        func argument(_ flag:String)->String? { guard let i=CommandLine.arguments.firstIndex(of:flag),i+1<CommandLine.arguments.count else { return nil };return CommandLine.arguments[i+1] }
        do {
            guard let input=argument("--review-diagnostics") else { throw CocoaError(.fileReadInvalidFileName) }
            let folder=URL(fileURLWithPath:input).resolvingSymlinksInPath()
            let output=argument("--diagnostic-review-output").map { URL(fileURLWithPath:$0) } ?? FileManager.default.temporaryDirectory.appendingPathComponent("RearviewDiagnosticReview-\(UUID())")
            let selected=argument("--diagnostic-frame").flatMap(UUID.init(uuidString:))
            let result=try await review(folder:folder,frame:selected,output:output)
            print("Diagnostic review: \(result.path)")
            return 0
        } catch { fputs("Diagnostic review failed: \(error)\n",stderr);return 1 }
    }
    @discardableResult static func review(folder:URL,frame selected:UUID?,output:URL) async throws -> URL {
        let fm=FileManager.default
        let root=folder.resolvingSymlinksInPath()
        func safeRead(_ relative:String) throws -> Data {
            let url=root.appendingPathComponent(relative).resolvingSymlinksInPath()
            guard url.path.hasPrefix(root.path+"/") else { throw CocoaError(.fileReadNoPermission) }
            return try Data(contentsOf:url)
        }
        let decoder=JSONDecoder();decoder.dateDecodingStrategy = .iso8601
        let manifest=try decoder.decode(DiagnosticManifest.self,from:safeRead("manifest.json"))
        guard manifest.schemaVersion==1,manifest.contentIncluded else { throw CocoaError(.featureUnsupported) }
        guard let id=selected ?? manifest.displayed ?? manifest.current ?? manifest.failed,
              let meta=manifest.frames.first(where: { $0.id==id }) else { throw CocoaError(.coderValueNotFound) }
        let base=id.uuidString+"/"
        func read(_ name:String) throws -> Data { try safeRead(base+name) }
        func image(_ name:String) throws -> CGImage {
            guard let image=NSBitmapImageRep(data:try read(name))?.cgImage else { throw CocoaError(.coderInvalidValue) };return image
        }
        let source=try image("source.png")
        var frame=MirrorFrame(image:source,translatedItems:[],frameID:meta.frameID)
        let mode=meta.summary["mode"] ?? "unknown"
        if mode=="ax" {
            let snapshot=try AXExtractionSnapshot(nodes:read("ax-nodes.json"),selected:read("ax-selected.json"),paragraphs:read("ax-paragraphs.json"),metadata:read("ax-metadata.json"))
            let entries=try JSONDecoder().decode([AXParagraphTranslation].self,from:read("ax-translations.json"))
            var value=SessionCoordinator.AXTranslatedFrame(frame:.init(snapshot:snapshot,image:source,frameID:meta.frameID,receivedAt:meta.receivedAt),entries:entries)
            if meta.files.contains("retained-source.png") {
                let oldSnapshot=try AXExtractionSnapshot(nodes:read("retained-nodes.json"),selected:read("retained-selected.json"),paragraphs:read("retained-paragraphs.json"),metadata:read("retained-metadata.json"))
                let oldImage=try image("retained-source.png")
                let oldEntries=try JSONDecoder().decode([AXParagraphTranslation].self,from:read("retained-translations.json"))
                let old=SessionCoordinator.AXTranslatedFrame(frame:.init(snapshot:oldSnapshot,image:oldImage,frameID:0,receivedAt:0),entries:oldEntries)
                let metadata=try JSONSerialization.jsonObject(with:oldSnapshot.metadata) as? [String:Any] ?? [:]
                func rect(_ key:String)throws->CGRect {
                    guard let f=metadata[key] as? [String:Double],let x=f["x"],let y=f["y"],let w=f["width"],let h=f["height"] else { throw CocoaError(.coderInvalidValue) }
                    return CGRect(x:x,y:y,width:w,height:h)
                }
                let scope=try AXBodyScope(generation:0,processID:0,windowID:0,window:rect("windowFrame"),selection:rect("selectionRegion"),pixels:CGSize(width:oldImage.width,height:oldImage.height),direction:"saved",protection:false)
                let retention=AXBodyRetention();retention.store(value:old,artwork:await AXLineRendering.render(old),scope:scope)
                guard let body=retention.body else { throw CocoaError(.coderInvalidValue) }
                value.retainedBody=try .init(body:body,regions:JSONDecoder().decode([CGRect].self,from:read("retained-regions.json")),panels:JSONDecoder().decode([CGRect].self,from:read("retained-panels.json")))
            }
            let art=await AXLineRendering.render(value)
            frame.axArtwork=art;frame=withItems(frame,items:art.items)
        } else if mode=="ocr" {
            let saved=try JSONDecoder().decode(AXImageOCRSavedLayer.self,from:read("mirror-items.json"))
            guard let layer=saved.restore(source:source) else { throw CocoaError(.coderInvalidValue) }
            frame=withItems(frame,items:layer.items)
        } else { throw CocoaError(.featureUnsupported) }
        if meta.files.contains("image-layers.json") {
            let saved=try JSONDecoder().decode([AXImageOCRSavedLayer].self,from:read("image-layers.json"))
            for layer in saved {
                let pixels=try layer.imageFile.map(image)
                guard let restored=layer.restore(source:source,savedImage:pixels) else { throw CocoaError(.coderInvalidValue) }
                frame.imageOCRLayers.append(restored)
            }
        }
        // Never overwrite the original evidence or an existing review.
        let resolvedOutput=output.resolvingSymlinksInPath()
        guard !resolvedOutput.path.hasPrefix(root.path+"/"),resolvedOutput != root,!fm.fileExists(atPath:output.path) else { throw CocoaError(.fileWriteFileExists) }
        try fm.createDirectory(at:output,withIntermediateDirectories:true)
        let view=NativeTranslationMirrorView(frame:CGRect(x:0,y:0,width:source.width,height:source.height))
        view.setRenderingActive(true)
        view.backgroundOpacity=Double(meta.summary["backgroundOpacity"] ?? "1") ?? 1
        view.frameSnapshot=frame
        guard let rendered=view.compositedImage(),let tiff=rendered.tiffRepresentation,let png=NSBitmapImageRep(data:tiff)?.representation(using:.png,properties:[:]) else { throw CocoaError(.coderInvalidValue) }
        try png.write(to:output.appendingPathComponent("rerendered.png"))
        var hasRecorded=false
        if let original=try? read("composite.png") { try original.write(to:output.appendingPathComponent("recorded.png"));hasRecorded=true }
        let html="""
        <!doctype html><meta charset="utf-8"><title>Rearview 진단 렌더링 비교</title>
        <style>body{font:14px system-ui}img{max-width:100%;border:1px solid #aaa}</style>
        <h1>진단 렌더링 비교</h1><p>프레임 \(meta.frameID) · \(mode) · \(id)</p>
        <p>저장된 추출·번역 결과로 렌더링했습니다. AX·OCR·번역 호출은 수행하지 않았습니다.</p>
        <h2>저장 당시 합성 결과</h2>\(hasRecorded ? "<img src=\"recorded.png\">" : "<p>저장된 합성 이미지가 없습니다.</p>")
        <h2>현재 코드로 다시 렌더링한 결과</h2><img src="rerendered.png">
        """
        try html.write(to:output.appendingPathComponent("index.html"),atomically:true,encoding:.utf8)
        return output
    }
    private static func withItems(_ original:MirrorFrame,items:[MirrorItem])->MirrorFrame {
        var frame=MirrorFrame(image:original.image,translatedItems:items,frameID:original.frameID);frame.axArtwork=original.axArtwork;return frame
    }
}
#endif
