import XCTest
@testable import NotionAXCore

final class ParagraphBuilderTests: XCTestCase {
    func testNearestBoundaryPreservesDuplicatePositionsAndUTF16() {
        let f: [String:Double] = ["x":0,"y":0,"width":100,"height":30]
        let nodes: [[String:Any]] = [
            ["id":0,"role":"AXTextArea","value":"document","frame":f],
            ["id":1,"parent":0,"role":"AXTextArea","value":"😀同じ","frame":f],
            ["id":2,"parent":1,"role":"AXStaticText","value":"😀同じ","frame":f],
            ["id":3,"parent":0,"role":"AXStaticText","value":"😀同じ","frame":f]]
        let selected: [[String:Any]] = [2,3].map { ["node":$0,"text":"😀同じ","textSource":"AXValue","box":f] }
        let units = AXParagraphBuilder.build(nodes:nodes,selected:selected)
        XCTAssertEqual(units.map{$0["node"] as! Int},[1,3])
        XCTAssertEqual(units.map{$0["text"] as! String},["😀同じ","😀同じ"])
        XCTAssertEqual(units[0]["members"] as? [Int],[2])
        XCTAssertEqual((units[0]["box"] as! [String:Double]),f)
    }
    func testExpansionOnlyForPlainNativeTextArea() {
        let f: [String:Double] = ["x":10,"y":20,"width":100,"height":30]
        for kind in ["notion-text-block","notion-code-block","notion-table-block","notion-bulleted_list-block"] {
            let nodes: [[String:Any]] = [
                ["id":0,"role":"AXGroup","domClasses":["notion-selectable",kind]],
                ["id":1,"parent":0,"role":"AXTextArea","value":"日本語","frame":f],
                ["id":2,"parent":1,"role":"AXStaticText","value":"日本語","frame":f]]
            let result = AXParagraphBuilder.build(nodes:nodes,selected:[["node":2,"text":"日本語","textSource":"AXValue","box":f]])
            XCTAssertEqual(result[0]["layoutExpansionRight"] as? Double,kind != "notion-code-block" ? 110 : nil)
        }
    }
    func testVerifiedParentChangesBoxWithoutChangingTextIdentity() {
        let source: [String:Double] = ["x":18,"y":22,"width":20,"height":17]
        let area: [String:Double] = ["x":18,"y":20,"width":180,"height":21]
        let control: [String:Double] = ["x":10,"y":10,"width":200,"height":40]
        for verified in [false,true] {
            let nodes: [[String:Any]] = [
                ["id":0,"role":"AXButton","frame":control],
                ["id":1,"role":"AXStaticText","controlTextOwner":0,"frame":source,
                 "ownershipParentFrames":[["role":"AXGroup","frame":area,"singleTextOwnerVerified":verified]]]]
            let unit = AXParagraphBuilder.build(nodes:nodes,selected:[["node":1,"text":"日本語","textSource":"AXValue","controlTextOwner":0,"box":source]])[0]
            XCTAssertEqual(unit["node"] as? Int,1)
            XCTAssertEqual(unit["text"] as? String,"日本語")
            XCTAssertEqual(unit["members"] as? [Int],[1])
            XCTAssertEqual(unit["box"] as? [String:Double],verified ? area : source)
            XCTAssertEqual(unit["layoutExpansionRight"] as? Double,verified ? 198 : nil)
            XCTAssertNil(unit["displayBoxes"])
        }
    }
    func testOnlyNodeOverflowExtendsToCellEvenWhenTextEndsBeforeCellEdge() {
        let area: [String:Double] = ["x":18,"y":20,"width":180,"height":21]
        let cell: [String:Double] = ["x":10,"y":10,"width":200,"height":40]
        for width in [179.0,180.0,187.0,192.0] {
            let source: [String:Double] = ["x":18,"y":22,"width":width,"height":17]
            let nodes: [[String:Any]] = [
                ["id":2,"role":"AXGroup","domClasses":["notion-table-view-cell"],"frame":cell],
                ["id":0,"parent":2,"role":"AXButton","frame":cell],
                ["id":1,"role":"AXStaticText","controlTextOwner":0,"frame":source,
                 "ownershipParentFrames":[["role":"AXGroup","frame":area,"singleTextOwnerVerified":true]],
                 "paragraphLineInvestigation":["lineRanges":[["box":["x":18.0,"y":22.0,"width":900.0,"height":17.0]]]]]]
            let unit = AXParagraphBuilder.build(nodes:nodes,selected:[["node":1,"text":"日本語","textSource":"AXValue","controlTextOwner":0,"box":source]])[0]
            XCTAssertEqual(unit["box"] as? [String:Double],area)
            XCTAssertEqual(unit["layoutExpansionRight"] as? Double,width > 180 ? 210 : 198)
            XCTAssertEqual(unit["displayBoxes"] as? [[String:Double]],width > 180 ? [["x":18,"y":20,"width":192,"height":21]] : nil)
            XCTAssertEqual((unit["lineRanges"] as! [[String:Any]])[0]["box"] as? [String:Double],["x":18,"y":22,"width":900,"height":17])
        }
    }
    func testCellOverflowExtendsDisplayAndAppliesHeaderAndPreviewClipping() {
        let source: [String:Double] = ["x":18,"y":22,"width":187,"height":17]
        let area: [String:Double] = ["x":18,"y":20,"width":180,"height":21]
        let control: [String:Double] = ["x":10,"y":10,"width":200,"height":40]
        let nodes: [[String:Any]] = [
            ["id":2,"role":"AXGroup","domClasses":["notion-table-view-cell"],"frame":control],
            ["id":0,"parent":2,"role":"AXButton","frame":control],
            ["id":1,"role":"AXStaticText","controlTextOwner":0,"frame":source,
             "ownershipParentFrames":[["role":"AXGroup","frame":area,"singleTextOwnerVerified":true]]]]
        let unit = AXParagraphBuilder.build(nodes:nodes,selected:[[
            "node":1,"text":"日本語","textSource":"AXValue","controlTextOwner":0,"box":source,
            "tableHeaderOcclusion":["headerFrame":["x":0.0,"y":0.0,"width":300.0,"height":25.0]],
            "previewOcclusions":[["panelFrame":["x":205.0,"y":0.0,"width":100.0,"height":100.0]]]]])[0]
        let masks = unit["displayBoxes"] as! [[String:Double]]
        XCTAssertEqual(masks,[["x":18,"y":25,"width":187,"height":16]])
        XCTAssertEqual(unit["layoutExpansionRight"] as? Double,210)
    }
    func testSymmetricInsetOnlyChangesExpansionLimit() {
        for width in [30.0, 85.0] {
            let area: [String:Double] = ["x":0,"y":0,"width":100,"height":30]
            let leaf: [String:Double] = ["x":9,"y":5,"width":width,"height":17]
            let nodes: [[String:Any]] = [
                ["id":0,"role":"AXTextArea","value":"日本語","frame":area],
                ["id":1,"parent":0,"role":"AXStaticText","frame":leaf]]
            let u = AXParagraphBuilder.build(nodes:nodes,selected:[["node":1,"text":"日本語","textSource":"AXValue","box":leaf]])[0]
            XCTAssertEqual(u["layoutExpansionRight"] as? Double,width == 30 ? 91 : 100)
            XCTAssertEqual(u["box"] as? [String:Double],area)
        }
    }
    func testCancellationBeforeQueueWork() async {
        let provider = NativeSessionAXProvider()
        let task = Task {
            try Task.checkCancellation()
            return try await provider.collect(AXExtractionRequest(processID:0,windowID:0,windowFrame:.zero,selectionRegion:.zero))
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("cancelled request succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        await provider.endSession()
    }
}
