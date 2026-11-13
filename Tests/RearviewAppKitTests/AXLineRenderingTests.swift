#if DEBUG
import XCTest
import AppKit
import CoreText
@testable import Rearview
@testable import NotionAXCore

final class AXLineRenderingTests: XCTestCase {
    private func render(source: String = "日本語", translation: String = "한국어 👩‍💻 가나다라", heights: [Double] = [18,18], widths: [Double] = [60,60], clip: Bool = false, math: Bool = false, lineStatus: String? = nil, hidden: Bool = false, axRed: Bool = false, pixelScale: Double = 1) throws -> AXRenderArtwork {
        let canvasHeight = max(200,heights.count*25+40)
        let ctx = CGContext(data:nil,width:300,height:canvasHeight,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(NSColor.white.cgColor);ctx.fill(CGRect(x:0,y:0,width:300,height:canvasHeight))
        let box: [String:Double] = ["x":10,"y":10,"width":200,"height":Double(heights.count*25+30)]
        var paragraph: [String:Any] = ["node":1,"text":source,"box":box,"members":[1],"isCodeBlock":false,"protectNonSourceText":false,
            "lineRanges":heights.enumerated().map { i,h in ["text":"日本語","rangeStart":i*3,"rangeLength":3,"box":["x":10.0,"y":10.0+Double(i)*25,"width":widths[i],"height":h]] as [String:Any] }]
        if clip { paragraph["visibleBoxes"] = [["x":10,"y":10,"width":20,"height":80]] }
        if hidden { paragraph["visibleBoxes"] = [] as [[String:Double]] }
        if let lineStatus { paragraph["lineRangeStatus"] = lineStatus }
        if math {
            paragraph["inlineContent"] = [["kind":"text","id":0,"text":"日本語","sourceNodes":[1],"lineRanges":paragraph["lineRanges"]!], ["kind":"math","id":1,"node":2]]
        }
        let nodes: [[String:Any]] = axRed ? [["id":1,"role":"AXStaticText","value":"日本語","title":"","foregroundColorStatus":"uniform","foregroundColor":["red":0.7,"green":0,"blue":0,"alpha":1]]] : []
        let snapshot = try AXExtractionSnapshot(nodes:nodes,selected:[],paragraphs:[paragraph],metadata:["status":"complete","selectionRegion":["x":0,"y":0,"width":300/pixelScale,"height":Double(canvasHeight)/pixelScale]])
        var payload: [String:Any] = ["provider":"test","node":1,"source":source,"sourceLanguage":"ja","targetLanguage":"ko","protectNonSourceText":false,"sourceLanguageEligible":true,"status":"translated","translation":translation]
        if math { payload["segments"] = [["id":0,"source":"日本語","status":"translated","translation":translation]] }
        let entry = try JSONDecoder().decode(AXParagraphTranslation.self,from:JSONSerialization.data(withJSONObject:payload))
        let restored = try AXExtractionSnapshot(nodes:snapshot.nodes,selected:snapshot.selected,paragraphs:snapshot.paragraphs,metadata:snapshot.metadata)
        return AXLineRendering.build(.init(frame:.init(snapshot:restored,image:ctx.makeImage()!,frameID:1,receivedAt:0),entries:[entry]))
    }
    func testFullTranslationSurvivesCompressionAndEmoji() throws {
        let text = String(repeating:"한국어👩‍💻",count:30)
        let result = try render(translation:text,widths:[12,12])
        XCTAssertEqual(result.fragments.map(\.text).joined(),text)
        XCTAssertLessThan(result.diagnostics[0].commonScale,0.65)
        XCTAssertTrue(result.fragments.allSatisfy { $0.rect.maxX <= 22.001 })
    }
    func testNewlineAndInsufficientHeightKeepOriginal() throws {
        XCTAssertEqual(try render(source:"日本語\n日本語").diagnostics.first?.status,"source_newline_unsupported")
        XCTAssertEqual(try render(heights:[2,18]).diagnostics.first?.status,"insufficient_line_height")
        XCTAssertTrue(try render(source:"日本語\n").fragments.isEmpty)
    }
    func testClipPreservesLayoutAndOnlyFiltersSelection() throws {
        let full = try render(), clipped = try render(clip:true)
        XCTAssertEqual(full.diagnostics[0].lineScales,clipped.diagnostics[0].lineScales)
        XCTAssertTrue(clipped.diagnostics[0].clipped)
        XCTAssertLessThan(clipped.fragments.count,full.fragments.count)
    }
    func testSavedCreditAvoidsUnnecessaryCompression() throws {
        let probe = CTFontCreateUIFontForLanguage(.system,1,nil)!
        let h = CTFontGetAscent(probe)+CTFontGetDescent(probe)+max(0,CTFontGetLeading(probe))
        let font = CTFontCreateCopyWithAttributes(probe,18*0.98/h,nil,nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string:"가",attributes:[NSAttributedString.Key(kCTFontAttributeName as String):font]))
        let glyph = CTLineGetTypographicBounds(line,nil,nil,nil)
        let result = try render(translation:String(repeating:"가",count:12),heights:[18,18,18],widths:[3.2*glyph,3.5*glyph,10*glyph])
        XCTAssertEqual(result.diagnostics[0].lineScales[0],0.8,accuracy:0.001)
        XCTAssertEqual(result.diagnostics[0].lineScales[1],1,accuracy:0.001)
        XCTAssertEqual(result.fragments.map(\.text).joined(),String(repeating:"가",count:12))
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
    func testTranslatedNewlineExcluded() throws {
        XCTAssertEqual(try render(translation:"한국어\n한국어").diagnostics.first?.status,"translation_newline_unsupported")
    }
}
#endif
