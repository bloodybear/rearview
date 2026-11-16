import XCTest
@testable import NotionAXCore

final class ParagraphBuilderTests: XCTestCase {
    func testTemporaryTextEditingMenuInset() {
        let frame = CGRect(x:239,y:332,width:225,height:350)
        XCTAssertEqual(PreviewOcclusion.textEditingMenuPanel(frame),CGRect(x:255,y:348,width:193,height:318))
        let tiny = CGRect(x:10,y:10,width:25,height:25)
        XCTAssertEqual(PreviewOcclusion.textEditingMenuPanel(tiny),tiny)
    }
    func testMenuMaskPreservesLayoutAndExcludesMenuDescendants() throws {
        let data = Data("{\"node\":1,\"text\":\"日本語\",\"box\":{\"x\":0,\"y\":0,\"width\":100,\"height\":100},\"members\":[],\"lineRanges\":[],\"isCodeBlock\":false,\"protectNonSourceText\":false,\"occlusionBoxes\":[{\"x\":25,\"y\":25,\"width\":50,\"height\":50}]}".utf8)
        let paragraph = try JSONDecoder().decode(AXParagraph.self,from:data)
        XCTAssertEqual(paragraph.baseDisplayRegions.count,1)
        XCTAssertEqual(paragraph.displayRegions.count,4)
        XCTAssertEqual(paragraph.displayRegions.reduce(0) { $0+$1.width*$1.height },7500)
        XCTAssertTrue(paragraph.displayRegions.allSatisfy { !$0.cgRect.intersects(CGRect(x:25,y:25,width:50,height:50)) })
    }
    func testIconAndLabelGroupsBecomeSeparateUnits() {
        let f:[String:Double] = ["x":0,"y":0,"width":100,"height":30]
        var nodes:[[String:Any]] = [
            ["id":0,"role":"AXRadioButton","title":"✅ 日本語","frame":f],
            ["id":1,"parent":0,"role":"AXGroup","frame":f],
            ["id":2,"parent":1,"role":"AXStaticText","value":"✅","frame":f],
            ["id":3,"parent":0,"role":"AXGroup","frame":f],
            ["id":4,"parent":3,"role":"AXStaticText","value":"日本語","frame":f]]
        let selected:[[String:Any]] = [(2,"✅"),(4,"日本語")].map { ["node":$0.0,"text":$0.1,"textSource":"AXValue","box":f] }
        let units=AXParagraphBuilder.build(nodes:nodes,selected:selected)
        XCTAssertEqual(units.map{$0["node"] as! Int},[1,3])
        XCTAssertEqual(units.map{$0["text"] as! String},["✅","日本語"])
        XCTAssertTrue(units.allSatisfy{$0["layoutExpansionRight"] == nil})
        XCTAssertEqual(AXParagraphBuilder.build(nodes:nodes,selected:[selected[1]]).first?["node"] as? Int,0)
        nodes[2]["value"]="普通"
        XCTAssertEqual(AXParagraphBuilder.build(nodes:nodes,selected:selected).count,1)
    }
    func testSavedBatchGroupingCompatibility() throws {
        guard let path=ProcessInfo.processInfo.environment["AX_GROUPING_BASELINE"] else { throw XCTSkip("Saved report audit is opt-in") }
        let root=URL(fileURLWithPath:path)
        let batch=try JSONSerialization.jsonObject(with:Data(contentsOf:root)) as! [String:Any]
        var removed=0, added=0
        for row in batch["results"] as! [[String:Any]] {
            let folder=root.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(row["report"] as! String).deletingLastPathComponent()
            func load(_ file:String)throws->Any { try JSONSerialization.jsonObject(with:Data(contentsOf:folder.appendingPathComponent(file))) }
            let old=(try load("native-paragraphs.json") as! [String:Any])["units"] as! [[String:Any]]
            let new=AXParagraphBuilder.build(nodes:try load("rawAx.json") as! [[String:Any]],selected:try load("candidate.json") as! [[String:Any]])
            let oldIDs=Set(old.map{$0["node"] as! Int}),newIDs=Set(new.map{$0["node"] as! Int})
            removed += oldIDs.subtracting(newIDs).count;added += newIDs.subtracting(oldIDs).count
            for unit in old where newIDs.contains(unit["node"] as! Int) {
                let replacement=new.first{$0["node"] as! Int == unit["node"] as! Int}!
                for key in ["members","box","lineRanges","lineSourceText"] {
                    XCTAssertEqual(NSDictionary(dictionary:[key:unit[key] ?? NSNull()]),NSDictionary(dictionary:[key:replacement[key] ?? NSNull()]),"\(row["scenario"]!) \(key)")
                }
            }
        }
        XCTAssertEqual(removed,3);XCTAssertEqual(added,6)
    }
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
