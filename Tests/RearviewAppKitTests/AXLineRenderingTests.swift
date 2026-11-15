#if DEBUG
import XCTest
import AppKit
import CoreText
@testable import Rearview
@testable import NotionAXCore

final class AXLineRenderingTests: XCTestCase {
    func testLayoutExpansionNeverShrinksOrMovesNativeLine() {
        let box = CGRect(x:20,y:30,width:80,height:18)
        XCTAssertEqual(AXLineRendering.layoutBox(box,expansionRight:150),CGRect(x:20,y:30,width:130,height:18))
        XCTAssertEqual(AXLineRendering.layoutBox(box,expansionRight:50),box)
        XCTAssertEqual(AXLineRendering.layoutBox(box,expansionRight:nil),box)
    }
    func testExpandedRenderingUsesCapacityAndPreservesOriginalGeometry() throws {
        let artwork = try render(expansionRight:210)
        let d = try XCTUnwrap(artwork.diagnostics.first { $0.status == "rendered" })
        XCTAssertEqual(d.lineBoxes.map(\.width),[200,200])
        XCTAssertEqual(d.originalLineBoxes?.map(\.width),[60,60])
        let background = try XCTUnwrap(artwork.background)
        let bytes = [UInt8](background.dataProvider!.data! as Data)
        // The unused right edge of the expanded capacity must stay transparent.
        XCTAssertEqual(bytes[20*background.bytesPerRow+205*4+3],0)
        let math = try render(math:true,expansionRight:210)
        XCTAssertEqual(math.diagnostics.first { $0.status == "rendered" }?.lineBoxes.map(\.width),[60,60])
    }
    private func render(source: String = "日本語", translation: String = "한국어 👩‍💻 가나다라", heights: [Double] = [18,18], widths: [Double] = [60,60], clip: Bool = false, math: Bool = false, lineStatus: String? = nil, hidden: Bool = false, axRed: Bool = false, pixelScale: Double = 1, logical: Bool = false, expansionRight: Double? = nil) throws -> AXRenderArtwork {
        let canvasHeight = max(200,heights.count*25+40)
        let ctx = CGContext(data:nil,width:300,height:canvasHeight,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(NSColor.white.cgColor);ctx.fill(CGRect(x:0,y:0,width:300,height:canvasHeight))
        let box: [String:Double] = ["x":10,"y":10,"width":200,"height":Double(heights.count*25+30)]
        var paragraph: [String:Any] = ["node":1,"text":source,"lineSourceText":source,"lineRangeStatus":"complete_unverified","box":box,"members":[1],"isCodeBlock":false,"protectNonSourceText":false,
            "lineRanges":heights.enumerated().map { i,h in ["text":"日本語","rangeStart":i*3,"rangeLength":3,"box":["x":10.0,"y":10.0+Double(i)*25,"width":widths[i],"height":h]] as [String:Any] }]
        paragraph["layoutExpansionRight"] = expansionRight
        var logicalEntries: [[String:Any]] = []
        if logical {
            let sourcePieces = AXLogicalLines.pieces(source)
            let translatedPieces = AXLogicalLines.pieces(translation)
            var nativeLines: [[String:Any]] = []
            for (i,piece) in sourcePieces.enumerated() {
                let raw = (source as NSString).substring(with:piece.0)
                if !raw.isEmpty {
                    nativeLines.append(["text":raw+piece.1,"rangeStart":piece.0.location,"rangeLength":piece.0.length+piece.1.utf16.count,
                        "box":["x":10.0,"y":10.0+Double(i)*25,"width":200.0,"height":18.0]])
                }
                logicalEntries.append(["id":i*2,"logicalIndex":i,"rangeStart":piece.0.location,"rangeLength":piece.0.length,
                    "source":raw,"delimiter":piece.1,"status":raw.isEmpty ? "nonrendering_text" : "translated",
                    "translation":(translation as NSString).substring(with:translatedPieces[i].0),"generatedBreaksFlattened":false])
            }
            if math { for i in logicalEntries.indices { logicalEntries[i]["sourcePart"] = 0 } }
            paragraph["lineRanges"] = nativeLines
        }
        if clip { paragraph["visibleBoxes"] = [["x":10,"y":10,"width":20,"height":80]] }
        if hidden { paragraph["visibleBoxes"] = [] as [[String:Double]] }
        if let lineStatus { paragraph["lineRangeStatus"] = lineStatus }
        if math {
            paragraph["inlineContent"] = [["kind":"text","id":0,"text":logical ? source : "日本語","sourceNodes":[1],"lineRangeStatus":"complete_unverified","lineRanges":paragraph["lineRanges"]!], ["kind":"math","id":1,"node":2]]
        }
        let nodes: [[String:Any]] = axRed ? [["id":1,"role":"AXStaticText","value":"日本語","title":"","foregroundColorStatus":"uniform","foregroundColor":["red":0.7,"green":0,"blue":0,"alpha":1]]] : []
        let snapshot = try AXExtractionSnapshot(nodes:nodes,selected:[],paragraphs:[paragraph],metadata:["status":"complete","selectionRegion":["x":0,"y":0,"width":300/pixelScale,"height":Double(canvasHeight)/pixelScale]])
        var payload: [String:Any] = ["provider":"test","node":1,"source":source,"sourceLanguage":"ja","targetLanguage":"ko","protectNonSourceText":false,"sourceLanguageEligible":true,"status":"translated","translation":translation]
        if logical { payload["logicalSegments"] = logicalEntries }
        if math { payload["segments"] = [["id":0,"source":"日本語","status":"translated","translation":translation]] }
        let entry = try JSONDecoder().decode(AXParagraphTranslation.self,from:JSONSerialization.data(withJSONObject:payload))
        let restored = try AXExtractionSnapshot(nodes:snapshot.nodes,selected:snapshot.selected,paragraphs:snapshot.paragraphs,metadata:snapshot.metadata)
        return AXLineRendering.build(.init(frame:.init(snapshot:restored,image:ctx.makeImage()!,frameID:1,receivedAt:0),entries:[entry]))
    }
    private func renderCode(hidden:Bool = false, geometry:Bool = true, failed:Bool = false, wraps:Bool = false, decorated:Bool = false) throws -> AXRenderArtwork {
        let source = "  x = \"日本語\";\n\n"
        let box: [String:Double] = ["x":10,"y":10,"width":200,"height":wraps ? 43 : 18]
        var runs: [[String:Any]] = []
        var values: [[String:Any]] = []
        for (id,part) in AXCodeTextSegments.split(source).enumerated() {
            let length = part.text.trimmingCharacters(in:.newlines).utf16.count
            var piece: [String:Any] = ["sourceNode":1,"rangeStart":part.range.location,"rangeLength":length,
                "text":String(part.text.prefix(length)),"status":"complete",
                "box":["x":10.0+Double(part.range.location)*8,"y":10.0,"width":Double(length)*8,"height":18.0]]
            if part.translates && !geometry { piece.removeValue(forKey:"box");piece["status"]="bounds_unavailable" }
            if wraps && part.range.location > 7 {
                piece["box"]=["x":26.0,"y":35.0,"width":Double(length)*8,"height":18.0]
            }
            var pieces = [piece]
            if wraps && part.translates {
                var first = piece, second = piece
                first["rangeLength"]=1;first["text"]="日";first["box"]=["x":66.0,"y":10.0,"width":8.0,"height":18.0]
                second["sourceNode"]=2;second["rangeStart"]=part.range.location+1;second["rangeLength"]=2;second["text"]="本語"
                second["box"]=["x":10.0,"y":35.0,"width":16.0,"height":18.0]
                pieces=[first,second]
            }
            runs.append(["id":id,"rangeStart":part.range.location,"rangeLength":part.range.length,"text":part.text,
                "translates":part.translates,"pieces":pieces,"status":part.translates && !geometry ? "partial" : "complete",
                "style":["foregroundColorStatus":"uniform","foregroundColor":["red":0.7,"green":0,"blue":0,"alpha":1],"bold":true,"italic":decorated,"underline":decorated,"strikethrough":decorated]])
            if part.translates {
                var value: [String:Any] = ["id":id,"rangeStart":part.range.location,"rangeLength":part.range.length,"source":part.text,"status":failed ? "failed" : "translated"]
                if !failed { value["translation"]="한국어 번역이 길어도 기호를 덮지 않습니다" }
                values.append(value)
            }
        }
        var paragraph: [String:Any] = ["node":1,"text":source,"lineSourceText":source,"lineRangeStatus":"complete_unverified","box":box,"members":[1],"lineSourceNodes":[1],"isCodeBlock":true,"protectNonSourceText":true,"codeSegments":runs,
            "lineRanges":[["text":source,"rangeStart":0,"rangeLength":source.utf16.count,"box":["x":10.0,"y":10.0,"width":200.0,"height":18.0]]]]
        if hidden { paragraph["visibleBoxes"]=[] as [[String:Double]] }
        let snapshot = try AXExtractionSnapshot(nodes:[],selected:[],paragraphs:[paragraph],metadata:["status":"complete","selectionRegion":["x":0,"y":0,"width":300,"height":100]])
        let payload: [String:Any] = ["provider":"test","node":1,"source":source,"sourceLanguage":"ja","targetLanguage":"ko","protectNonSourceText":true,"sourceLanguageEligible":true,"status":"translated","codeTranslations":values]
        let entry = try JSONDecoder().decode(AXParagraphTranslation.self,from:JSONSerialization.data(withJSONObject:payload))
        let ctx = CGContext(data:nil,width:300,height:100,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(NSColor.white.cgColor);ctx.fill(CGRect(x:0,y:0,width:300,height:100))
        return AXLineRendering.build(.init(frame:.init(snapshot:snapshot,image:ctx.makeImage()!,frameID:1,receivedAt:0),entries:[entry]))
    }
    func testCodePaintsOnlyJapaneseAndCopiesMixedSourceExactly() throws {
        let result = try renderCode()
        let text = "  x = \"한국어 번역이 길어도 기호를 덮지 않습니다\";\n\n"
        XCTAssertEqual(result.items.count,1)
        XCTAssertEqual(result.items[0].translatedText,text)
        XCTAssertEqual(result.fragments.map(\.text).joined(),text)
        XCTAssertEqual(result.clipRects,[CGRect(x:66,y:72,width:24,height:18)])
        XCTAssertTrue(result.diagnostics.contains { $0.status == "preserved_source" })
        XCTAssertEqual(result.diagnostics.first(where: { $0.status == "rendered" })?.foregroundSource,"ax_uniform")
        // Neither the mask nor translated glyphs may touch the original code syntax.
        for image in [result.background!,result.text!] {
            let bytes = [UInt8](image.dataProvider!.data! as Data)
            for y in 0..<image.height { for x in 0..<image.width where x < 66 || x >= 90 {
                XCTAssertEqual(bytes[y*image.bytesPerRow+x*4+3],0)
            } }
        }
    }
    func testCodeFailureAndInvisibleAreasNeverMaskSource() throws {
        let failure = try renderCode(failed:true)
        XCTAssertTrue(failure.clipRects.isEmpty)
        XCTAssertEqual(failure.fragments.map(\.text).joined(),"  x = \"日本語\";\n\n")
        XCTAssertTrue(try renderCode(geometry:false).clipRects.isEmpty)
        let hidden = try renderCode(hidden:true)
        XCTAssertTrue(hidden.fragments.isEmpty);XCTAssertTrue(hidden.clipRects.isEmpty)
    }
    func testCodeAcrossNodesAndSoftWrappedBoxesKeepsOneTranslationAndExactCopy() throws {
        let result = try renderCode(wraps:true)
        XCTAssertEqual(result.fragments.map(\.text).joined(),result.items[0].translatedText)
        XCTAssertEqual(result.clipRects.count,2)
        XCTAssertEqual(result.diagnostics.first(where: { $0.status == "rendered" })?.lineBoxes.count,2)
        let styled = try renderCode(decorated:true), plain = try renderCode()
        XCTAssertNotEqual(styled.text!.dataProvider!.data! as Data,plain.text!.dataProvider!.data! as Data)
    }
    @MainActor func testMixedCodeSelectionAndSearchUseNativeViewInBothPresentations() throws {
        let artwork = try renderCode()
        let ctx = CGContext(data:nil,width:300,height:100,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        let expected = artwork.items[0].translatedText
        for outside in [true,false] {
            let view = NativeTranslationMirrorView(frame:CGRect(x:0,y:0,width:300,height:100))
            view.showsCapturedImage=true;view.fillsBackgroundOutsideImage=outside
            view.setRenderingActive(true)
            var frame = MirrorFrame(image:ctx.makeImage()!,translatedItems:artwork.items,frameID:1)
            frame.axArtwork=artwork;view.frameSnapshot=frame
            view.setSelectionModeActive(true);view.selectAll(nil)
            XCTAssertEqual(view.clipboardText(),expected)
            var matches = 0
            view.onSearchCountChange = { count,_ in matches=count }
            view.setSearch(query:"x =",caseSensitive:true,regex:false)
            XCTAssertEqual(matches,1)
            view.setSearch(query:"한국어",caseSensitive:true,regex:false)
            XCTAssertEqual(matches,1)
        }
    }
    func testFullTranslationSurvivesCompressionAndEmoji() throws {
        let text = String(repeating:"한국어👩‍💻",count:30)
        let result = try render(translation:text,widths:[12,12])
        XCTAssertEqual(result.fragments.map(\.text).joined(),text)
        XCTAssertLessThan(result.diagnostics[0].commonScale,0.65)
        XCTAssertTrue(result.fragments.allSatisfy { $0.rect.maxX <= 22.001 })
    }
    func testSoftWrapConsumesOnlyOneOrdinarySpaceAndPreservesOffsets() throws {
        let probe = CTFontCreateUIFontForLanguage(.system,1,nil)!
        let h = CTFontGetAscent(probe)+CTFontGetDescent(probe)+max(0,CTFontGetLeading(probe))
        let font = CTFontCreateCopyWithAttributes(probe,18*0.98/h,nil,nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string:"가",attributes:[NSAttributedString.Key(kCTFontAttributeName as String):font]))
        let glyph = CTLineGetTypographicBounds(line,nil,nil,nil)
        for spaces in [" ","   ","\t","\u{00a0}"] {
            let text = "가나"+spaces+"다👩‍💻"
            let result = try render(translation:text,widths:[2*glyph,200])
            let hidden = spaces.first == " " ? [2] : []
            XCTAssertEqual(result.diagnostics.first?.hiddenWrapSpaceOffsets,hidden)
            XCTAssertEqual(result.fragments.map(\.text).joined(),text)
            XCTAssertEqual(result.items.first?.translatedText,text)
            XCTAssertEqual(result.fragments.last?.characterOffset,(text as NSString).length-("👩‍💻" as NSString).length)
            if !hidden.isEmpty {
                let firstOnSecondLine = try XCTUnwrap(result.fragments.first { $0.characterOffset > 2 })
                XCTAssertEqual(firstOnSecondLine.rect.minX,10,accuracy:0.001)
            }
        }
        let firstLineSpace = try render(translation:" 가나다",heights:[18],widths:[200])
        XCTAssertEqual(firstLineSpace.fragments.first?.text," ")
        XCTAssertEqual(firstLineSpace.diagnostics.first?.hiddenWrapSpaceOffsets,[])
    }
    func testNewlineAndInsufficientHeightKeepOriginal() throws {
        XCTAssertEqual(try render(source:"日本語\n日本語").diagnostics.first?.status,"logical_translation_unavailable")
        XCTAssertEqual(try render(heights:[2,18]).diagnostics.first?.status,"insufficient_line_height")
        XCTAssertTrue(try render(source:"日本語\n").fragments.isEmpty)
    }
    func testClipPreservesLayoutAndOnlyFiltersSelection() throws {
        let full = try render(), clipped = try render(clip:true)
        XCTAssertEqual(full.diagnostics[0].lineScales,clipped.diagnostics[0].lineScales)
        XCTAssertTrue(clipped.diagnostics[0].clipped)
        XCTAssertLessThan(clipped.fragments.count,full.fragments.count)
    }
    func testInitialSpareCapacityAvoidsUnnecessaryCompression() throws {
        let probe = CTFontCreateUIFontForLanguage(.system,1,nil)!
        let h = CTFontGetAscent(probe)+CTFontGetDescent(probe)+max(0,CTFontGetLeading(probe))
        let font = CTFontCreateCopyWithAttributes(probe,18*0.98/h,nil,nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string:"가",attributes:[NSAttributedString.Key(kCTFontAttributeName as String):font]))
        let glyph = CTLineGetTypographicBounds(line,nil,nil,nil)
        let result = try render(translation:String(repeating:"가",count:12),heights:[18,18,18],widths:[3.2*glyph,3.5*glyph,10*glyph])
        XCTAssertEqual(result.diagnostics[0].commonScale,1,accuracy:0.001)
        XCTAssertEqual(result.diagnostics[0].lineScales[0],1,accuracy:0.001)
        XCTAssertEqual(result.diagnostics[0].lineScales[1],1,accuracy:0.001)
        XCTAssertEqual(result.fragments.map(\.text).joined(),String(repeating:"가",count:12))
    }
    func testTightCapacityStillEarnsAndSpendsCompressionCredit() throws {
        let probe = CTFontCreateUIFontForLanguage(.system,1,nil)!
        let h = CTFontGetAscent(probe)+CTFontGetDescent(probe)+max(0,CTFontGetLeading(probe))
        let font = CTFontCreateCopyWithAttributes(probe,18*0.98/h,nil,nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string:"가",attributes:[NSAttributedString.Key(kCTFontAttributeName as String):font]))
        let glyph = CTLineGetTypographicBounds(line,nil,nil,nil)
        for lastWidth in [5.3,2.0] {
            let text = String(repeating:"가",count:12)
            let result = try render(translation:text,heights:[18,18,18],widths:[3.2*glyph,3.5*glyph,lastWidth*glyph])
            XCTAssertLessThan(result.diagnostics[0].lineScales[0],1)
            if lastWidth == 5.3 { XCTAssertEqual(result.diagnostics[0].lineScales[1],1,accuracy:0.001) }
            else { XCTAssertLessThan(result.diagnostics[0].commonScale,1) }
            XCTAssertEqual(result.fragments.map(\.text).joined(),text)
        }
    }
    func testFormulaSerializationNewlineDoesNotExcludeText() throws {
        let result = try render(source:"日本語\nFORMULA\n",math:true)
        XCTAssertEqual(result.diagnostics.first?.status,"rendered")
    }
    func testRetinaProjectionKeepsScreenPointGeometrySeparate() throws {
        let result = try render(translation:"한국어",heights:[18],widths:[60],pixelScale:2)
        let box = try XCTUnwrap(result.diagnostics.first?.lineBoxes.first)
        XCTAssertEqual(box,CGRect(x:20,y:144,width:120,height:36))
        XCTAssertTrue(result.fragments.allSatisfy { $0.rect.minX >= 20 && $0.rect.maxX <= 140.001 })
    }
    func testAXForegroundOverridesSampledColor() throws {
        let red = try render(axRed:true), sampled = try render()
        XCTAssertNotEqual(red.text!.dataProvider!.data! as Data,sampled.text!.dataProvider!.data! as Data)
        let bytes = [UInt8](red.text!.dataProvider!.data! as Data)
        XCTAssertTrue(stride(from:0,to:bytes.count,by:4).contains { bytes[$0] > bytes[$0+1] && bytes[$0+3] > 0 })
        XCTAssertEqual(red.diagnostics.first?.foregroundSource,"ax_uniform")
        XCTAssertGreaterThanOrEqual(red.diagnostics.first!.foregroundContrast!,4.5)
    }
    func testEmptyClipNeverPaintsText() throws {
        let result = try render(hidden:true)
        let data = result.text!.dataProvider!.data! as Data
        XCTAssertTrue(data.allSatisfy { $0 == 0 })
        XCTAssertTrue(result.fragments.isEmpty)
        XCTAssertTrue(result.clipRects.isEmpty)
    }
    func testFailedLineConnectionNeverMasksOriginal() throws {
        let result = try render(lineStatus:"marker_string_mismatch")
        XCTAssertEqual(result.diagnostics[0].status,"line_marker_string_mismatch")
        XCTAssertTrue(result.items.isEmpty)
        XCTAssertTrue(result.clipRects.isEmpty)
    }
    func testLayoutCostAtDifferentLineCounts() throws {
        for count in [1,10,100] {
            var samples: [Double] = []
            for _ in 0..<3 {
                let result = try render(translation:String(repeating:"한국어",count:count*3),heights:Array(repeating:18,count:count),widths:Array(repeating:60,count:count))
                samples.append(result.elapsed*1000)
            }
            print("AX layout benchmark lines=\(count) milliseconds=\(samples)")
        }
    }
    func testLogicalLinesKeepBlankLineGeometryAndCopyNewlines() throws {
        let value = try render(source:"最初\n\n次\n",translation:"첫째\n\n 둘째\n",heights:[18,18,18,18],widths:[200,200,200,200],logical:true)
        XCTAssertEqual(value.diagnostics.filter { $0.status == "rendered" }.count,2)
        XCTAssertEqual(value.fragments.map(\.text).joined(),"첫째\n\n 둘째\n")
        XCTAssertEqual(value.items.count,1)
        XCTAssertEqual(value.diagnostics.filter { $0.status == "rendered" }.map(\.logicalIndex),[0,2])
        XCTAssertTrue(value.diagnostics.allSatisfy { $0.hiddenWrapSpaceOffsets.isEmpty })
    }
    func testMathTextSegmentAlsoUsesHardBreakLineGroups() throws {
        let value = try render(source:"最初\n次",translation:"처음\n다음",math:true,logical:true)
        XCTAssertEqual(value.fragments.map(\.text).joined(),"처음\n다음")
        XCTAssertEqual(value.diagnostics.filter { $0.status == "rendered" }.map(\.segment),[0,0])
    }
    func testTranslatedNewlineExcluded() throws {
        XCTAssertEqual(try render(translation:"한국어\n한국어").diagnostics.first?.status,"translation_newline_unsupported")
    }
}
#endif
