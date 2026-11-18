#if DEBUG
import XCTest
import AppKit
@testable import Rearview
@testable import NotionAXCore

@MainActor final class AXBodyRetentionTests: XCTestCase {
    private var scope: AXBodyScope { .init(generation:1,processID:42,windowID:7,window:CGRect(x:0,y:0,width:300,height:200),
        selection:CGRect(x:0,y:0,width:300,height:200),pixels:CGSize(width:300,height:200),direction:"ja-ko",protection:false) }
    private let box: [String:Double] = ["x":10,"y":20,"width":200,"height":20]
    private func value(frameID:UInt64=1,body:Bool=true,panels:[CGRect]=[],url:String="https://example.test/page",limited:Bool=false) throws -> SessionCoordinator.AXTranslatedFrame {
        let root:[String:Any] = ["id":0,"role":"AXWebArea","value":"","title":"Document"]
        let node:[String:Any] = ["id":1,"parent":0,"role":"AXStaticText","value":"日本語","title":"","frame":box]
        let paragraph:[String:Any] = ["node":1,"text":"日本語","lineSourceText":"日本語","lineRangeStatus":"complete_unverified",
            "box":box,"members":[1],"lineRanges":[["text":"日本語","rangeStart":0,"rangeLength":3,"box":box]],"isCodeBlock":false,"protectNonSourceText":false]
        func rect(_ r:CGRect)->[String:Double] { ["x":r.minX,"y":r.minY,"width":r.width,"height":r.height] }
        let surface:[String:Any] = ["node":0,"url":url,"frame":rect(scope.window),"bodyNodes":body ? [1]:[],"dialogBoxes":panels.map(rect)]
        let snapshot=try AXExtractionSnapshot(nodes:body ? [root,node]:[root],selected:[],paragraphs:body ? [paragraph]:[],
            metadata:["status":"complete","truncated":limited,"documentSurfaces":[surface],"selectionRegion":rect(scope.selection)])
        let ctx=CGContext(data:nil,width:300,height:200,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(NSColor.white.cgColor);ctx.fill(scope.window)
        let entry=AXParagraphTranslation(node:1,source:"日本語",sourceLanguage:"ja",targetLanguage:"ko",protectNonSourceText:false,
            parts:nil,mathPolicy:nil,sourceLanguageEligible:true,status:"translated",translation:"한국어")
        return .init(frame:.init(snapshot:snapshot,image:ctx.makeImage()!,frameID:frameID,receivedAt:0),entries:body ? [entry]:[])
    }
    func testRetainsOnlyValuesAndReclipsOriginalForEveryPopup() throws {
        let retention=AXBodyRetention(), original=try value()
        let artwork=AXLineRendering.build(original)
        retention.store(value:original,artwork:artwork,scope:scope)
        let panel=CGRect(x:30,y:0,width:30,height:200)
        let modal=try value(frameID:2,body:false,panels:[panel])
        let (reuse,diagnostic)=retention.resolve(snapshot:modal.frame.snapshot,scope:scope)
        let resolved=try XCTUnwrap(reuse)
        XCTAssertEqual(diagnostic.status,"reused");XCTAssertEqual(diagnostic.sourceFrameID,1)
        let composite=AXLineRendering.build(modal).adding(resolved,size:scope.pixels)
        for image in [try XCTUnwrap(composite.background),try XCTUnwrap(composite.text)] {
            let bytes=[UInt8](image.dataProvider!.data! as Data)
            for y in 0..<200 {for x in 30..<60 {XCTAssertEqual(bytes[y*image.bytesPerRow+x*4+3],0)}}
        }
        XCTAssertFalse(composite.fragments.isEmpty)
        XCTAssertTrue(composite.fragments.allSatisfy { !$0.rect.intersects(panel) })
        XCTAssertEqual(retention.body?.frame.frameID,1)
        var reused=modal;reused.retainedBody=resolved
        retention.store(value:reused,artwork:composite,scope:scope)
        XCTAssertEqual(retention.body?.frame.frameID,1)
        let moved=try value(body:false,panels:[CGRect(x:200,y:0,width:30,height:200)])
        let next=try XCTUnwrap(retention.resolve(snapshot:moved.frame.snapshot,scope:scope).0)
        XCTAssertTrue(next.regions.contains { $0.contains(CGPoint(x:40,y:170)) },"Old popup holes must not accumulate")
        let closed=try value(frameID:3)
        XCTAssertNil(retention.resolve(snapshot:closed.frame.snapshot,scope:scope).0)
        retention.store(value:closed,artwork:AXLineRendering.build(closed),scope:scope)
        XCTAssertEqual(retention.body?.frame.frameID,3)
    }
    func testFullyCoveredBodyIsTransparentAndNotSelectable() throws {
        let original=try value(),r=AXBodyRetention()
        r.store(value:original,artwork:AXLineRendering.build(original),scope:scope)
        let modal=try value(body:false,panels:[CGRect(x:0,y:0,width:250,height:150)])
        let reuse=try XCTUnwrap(r.resolve(snapshot:modal.frame.snapshot,scope:scope).0)
        let art=AXLineRendering.build(modal).adding(reuse,size:scope.pixels)
        XCTAssertTrue(art.fragments.isEmpty);XCTAssertTrue(art.items.isEmpty)
        for image in [try XCTUnwrap(art.background),try XCTUnwrap(art.text)] {
            let bytes=[UInt8](image.dataProvider!.data! as Data)
            XCTAssertTrue(stride(from:3,to:bytes.count,by:4).allSatisfy { bytes[$0]==0 })
        }
    }
    func testRetainedSelectionAndSearchInBothViews() throws {
        let original=try value(),r=AXBodyRetention()
        r.store(value:original,artwork:AXLineRendering.build(original),scope:scope)
        let modal=try value(frameID:2,body:false,panels:[CGRect(x:200,y:0,width:30,height:200)])
        let reuse=try XCTUnwrap(r.resolve(snapshot:modal.frame.snapshot,scope:scope).0)
        let art=AXLineRendering.build(modal).adding(reuse,size:scope.pixels)
        for captured in [true,false] {
            let view=NativeTranslationMirrorView(frame:CGRect(origin:.zero,size:scope.pixels))
            view.showsCapturedImage=captured;view.setRenderingActive(true)
            var frame=MirrorFrame(image:modal.frame.image,translatedItems:art.items,frameID:2)
            frame.axArtwork=art;view.frameSnapshot=frame
            view.setSelectionModeActive(true);view.selectAll(nil)
            XCTAssertEqual(view.clipboardText(),"한국어")
            var count=0;view.onSearchCountChange={ value,_ in count=value }
            view.setSearch(query:"한국어",caseSensitive:true,regex:false)
            XCTAssertEqual(count,1)
        }
    }
    func testFullyHiddenRetainedCharacterIsNotSearchable() throws {
        let original=try value(),r=AXBodyRetention(),art=AXLineRendering.build(try value())
        let glyph=try XCTUnwrap(art.fragments.first(where:{$0.text == "국"}))
        r.store(value:original,artwork:art,scope:scope)
        let panel=CGRect(x:glyph.rect.minX-0.1,y:scope.pixels.height-glyph.rect.maxY-0.1,width:glyph.rect.width+0.2,height:glyph.rect.height+0.2)
        let modal=try value(frameID:2,body:false,panels:[panel])
        let reuse=try XCTUnwrap(r.resolve(snapshot:modal.frame.snapshot,scope:scope).0)
        let combined=AXLineRendering.build(modal).adding(reuse,size:scope.pixels)
        let view=NativeTranslationMirrorView(frame:CGRect(origin:.zero,size:scope.pixels))
        view.setRenderingActive(true)
        var frame=MirrorFrame(image:modal.frame.image,translatedItems:combined.items,frameID:2)
        frame.axArtwork=combined;view.frameSnapshot=frame
        var count=0;view.onSearchCountChange={ value,_ in count=value }
        view.setSearch(query:"국",caseSensitive:true,regex:false)
        XCTAssertEqual(count,0)
    }
    func testImageOCRLayersAreReusedWithPanelClipsAndSavedCompatibly() throws {
        let original=try value(),r=AXBodyRetention()
        var metadata=try JSONSerialization.jsonObject(with:original.frame.snapshot.metadata) as! [String:Any]
        metadata["imageRegions"]=[["node":1,"status":"selected","box":box,"displayBoxes":[box]]]
        let snapshot=try AXExtractionSnapshot(nodes:original.frame.snapshot.nodes,selected:original.frame.snapshot.selected,
            paragraphs:original.frame.snapshot.paragraphs,metadata:JSONSerialization.data(withJSONObject:metadata))
        let layer=AXImageOCRLayer(image:original.frame.image,pixelBox:CGRect(x:10,y:160,width:200,height:20),items:[],debugItems:[])
        let seeded=SessionCoordinator.AXTranslatedFrame(frame:.init(snapshot:snapshot,image:original.frame.image,frameID:1,receivedAt:0),entries:original.entries,imageOCR:.init(layers:[layer]))
        r.store(value:seeded,artwork:AXLineRendering.build(seeded),scope:scope)
        let modal=try value(body:false,panels:[CGRect(x:50,y:0,width:30,height:200)])
        let reuse=try XCTUnwrap(r.resolve(snapshot:modal.frame.snapshot,scope:scope).0)
        let reused=try XCTUnwrap(reuse.imageLayers.first)
        XCTAssertEqual(reused.pixelBox,layer.pixelBox)
        XCTAssertTrue((reused.displayPixelBoxes ?? []).allSatisfy { !$0.intersects(CGRect(x:50,y:0,width:30,height:200)) })
        let encoded=try JSONEncoder().encode(AXImageOCRSavedLayer(reused))
        let saved=try JSONDecoder().decode(AXImageOCRSavedLayer.self,from:encoded)
        XCTAssertEqual(saved.restore(source:original.frame.image)?.displayPixelBoxes,reused.displayPixelBoxes)
        var legacy=try JSONSerialization.jsonObject(with:encoded) as! [String:Any]
        legacy.removeValue(forKey:"displayPixelBoxes");legacy.removeValue(forKey:"imageFile")
        let old=try JSONDecoder().decode(AXImageOCRSavedLayer.self,from:JSONSerialization.data(withJSONObject:legacy))
        XCTAssertNil(old.displayPixelBoxes)
    }
    func testNestedPopupKeepsPrunedParentButSharedEdgeResizeDoesNot() throws {
        let r=AXBodyRetention(),original=try value()
        r.store(value:original,artwork:AXLineRendering.build(original),scope:scope)
        let parent=CGRect(x:10,y:10,width:180,height:140),child=CGRect(x:40,y:50,width:80,height:30)
        _=r.resolve(snapshot:try value(body:false,panels:[parent]).frame.snapshot,scope:scope)
        let nested=r.resolve(snapshot:try value(body:false,panels:[child]).frame.snapshot,scope:scope)
        XCTAssertEqual(nested.0?.panels.count,2)
        XCTAssertEqual(nested.1.inheritedPanels?.count,1)
        let repeated=r.resolve(snapshot:try value(body:false,panels:[child]).frame.snapshot,scope:scope)
        XCTAssertEqual(repeated.0?.panels.count,2)
        let resized=CGRect(x:10,y:10,width:180,height:90)
        let replaced=r.resolve(snapshot:try value(body:false,panels:[resized]).frame.snapshot,scope:scope)
        XCTAssertEqual(replaced.0?.panels.count,1)
        XCTAssertEqual(replaced.1.inheritedPanels?.count,0)
        let restored=r.resolve(snapshot:try value(body:false,panels:[parent]).frame.snapshot,scope:scope)
        XCTAssertEqual(restored.0?.panels.count,1)
        XCTAssertEqual(restored.1.inheritedPanels?.count,0)
    }
    func testRejectsMissingCacheUnknownPopupLimitsAndDifferentDocument() throws {
        let r=AXBodyRetention(), modal=try value(body:false,panels:[CGRect(x:30,y:0,width:30,height:200)])
        XCTAssertEqual(r.resolve(snapshot:modal.frame.snapshot,scope:scope).1.status,"no_previous_body")
        let original=try value();r.store(value:original,artwork:AXLineRendering.build(original),scope:scope)
        XCTAssertEqual(r.resolve(snapshot:try value(body:false).frame.snapshot,scope:scope).1.status,"no_verified_dialog")
        XCTAssertNil(r.resolve(snapshot:try value(body:false,limited:true).frame.snapshot,scope:scope).0)
        XCTAssertEqual(r.resolve(snapshot:try value(body:false,url:"other").frame.snapshot,scope:scope).1.status,"document_changed_or_unavailable")
        XCTAssertNil(r.body)
    }
    func testScopeChangeAndResetDiscardRetainedBody() throws {
        let original=try value(),r=AXBodyRetention()
        r.store(value:original,artwork:AXLineRendering.build(original),scope:scope)
        let changed=AXBodyScope(generation:2,processID:42,windowID:7,window:scope.window,selection:scope.selection,pixels:scope.pixels,direction:"ja-ko",protection:false)
        XCTAssertNil(r.resolve(snapshot:try value(body:false).frame.snapshot,scope:changed).0)
        XCTAssertNil(r.body)
        r.store(value:original,artwork:AXLineRendering.build(original),scope:scope);r.reset();XCTAssertNil(r.body)
    }
}
#endif
