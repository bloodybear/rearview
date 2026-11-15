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
            XCTAssertEqual(result[0]["layoutExpansionRight"] as? Double,kind == "notion-text-block" ? 110 : nil)
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
