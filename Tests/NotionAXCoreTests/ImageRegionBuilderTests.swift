import XCTest
@testable import NotionAXCore

final class ImageRegionBuilderTests: XCTestCase {
    func testImageUsesInnerFrameAndExcludesCaption() throws {
        let rows = fixture()
        let result = ImageRegionBuilder.build(rows:rows,selection:CGRect(x:0,y:0,width:400,height:400),
            viewport:{ _ in CGRect(x:0,y:0,width:400,height:400) },visible:{ _ in true },occlusions:{ _ in [] })
        XCTAssertEqual(result.count,1)
        XCTAssertEqual(result[0]["imageNode"] as? Int,1)
        XCTAssertEqual((result[0]["box"] as? [String:Double])?["height"],100)
        XCTAssertEqual(result[0]["status"] as? String,"selected")
    }
    func testClipAndPreviewLeaveOnlyDisjointVisiblePixels() {
        let result = ImageRegionBuilder.build(rows:fixture(),selection:CGRect(x:20,y:20,width:80,height:70),
            viewport:{ _ in CGRect(x:0,y:0,width:400,height:400) },visible:{ _ in true },
            occlusions:{ _ in [CGRect(x:40,y:0,width:20,height:400)] })
        let boxes = result[0]["displayBoxes"] as! [[String:Double]]
        XCTAssertEqual(boxes.count,2)
        XCTAssertEqual(boxes.map { $0["width"]! }.reduce(0,+),60)
        XCTAssertTrue(boxes.allSatisfy { $0["y"]==20 && $0["height"]==70 })
    }
    func testAmbiguousInvisibleAndNonImageAreNotOCRTargets() {
        var rows=fixture()
        let run = { (r:[[String:Any]],visible:Bool) in
            ImageRegionBuilder.build(rows:r,selection:CGRect(x:0,y:0,width:400,height:400),
                viewport:{ _ in CGRect(x:0,y:0,width:400,height:400) },visible:{ _ in visible },occlusions:{ _ in [] })
        }
        XCTAssertEqual(run(rows,false)[0]["status"] as? String,"excluded_by_ax_visible_only")
        rows.append(["id":3,"parent":0,"domClasses":["notion-cursor-default"]])
        XCTAssertEqual(run(rows,true)[0]["status"] as? String,"image_geometry_ambiguous")
        rows[0]["domClasses"]=["notion-code-block"]
        XCTAssertTrue(run(rows,true).isEmpty)
    }
    private func fixture() -> [[String:Any]] {
        [["id":0,"domClasses":["notion-image-block"],"frame":["x":0.0,"y":0.0,"width":120.0,"height":150.0]],
         ["id":1,"parent":0,"domClasses":["notion-cursor-default"],"frame":["x":10.0,"y":10.0,"width":100.0,"height":100.0]],
         ["id":2,"parent":0,"role":"AXStaticText","value":"caption","frame":["x":10.0,"y":110.0,"width":100.0,"height":20.0]]]
    }
}
