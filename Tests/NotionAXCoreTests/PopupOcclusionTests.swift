import XCTest
@testable import NotionAXCore
final class PopupOcclusionTests: XCTestCase {
    func testSemanticPanelAndCollapsedHost() {
        func rows(_ width:Double)->[[String:Any]] {
            [["id":0,"role":"AXWebArea"],
             ["id":1,"parent":0,"domClasses":["notion-sidebar-container"],"frame":["x":0.0,"y":0,"width":width,"height":400]],
             ["id":2,"parent":1,"domClasses":["notion-sidebar"],"frame":["x":0.0,"y":40,"width":200,"height":350]],
             ["id":3,"parent":2], ["id":4,"parent":0]]
        }
        let floating=PopupOcclusion(rows:rows(1))
        XCTAssertEqual(floating.masks(for:4),[CGRect(x:0,y:40,width:200,height:350)])
        XCTAssertTrue(floating.masks(for:3).isEmpty)
        XCTAssertTrue(floating.masks(for:99).isEmpty)
        XCTAssertTrue(PopupOcclusion(rows:rows(200)).masks(for:4).isEmpty)
        XCTAssertTrue(PopupOcclusion(rows:[]).masks(for:4).isEmpty)
    }
    func testAnonymousOverlayIsNeverGuessed() {
        let rows:[[String:Any]] = [
            ["id":0,"role":"AXWebArea"],
            ["id":1,"parent":0,"domClasses":["notion-overlay-container","notion-default-overlay-container"],
             "frame":["x":0.0,"y":0,"width":500,"height":500]],
            ["id":2,"parent":1,"domClasses":["x1n2onr6","xvv7f4i"],
             "frame":["x":10.0,"y":10,"width":200,"height":200]],
            ["id":3,"parent":0]]
        let result=PopupOcclusion(rows:rows)
        XCTAssertTrue(result.masks(for:3).isEmpty)
        XCTAssertEqual(result.diagnostics.first?["reason"] as? String,"no_verified_semantic_panel_boundary")
        XCTAssertNil(result.diagnostics.first?["panelFrame"])
    }

    func testSemanticDialogUsesItsOwnFrameAndExcludesPopupContents() {
        let rows:[[String:Any]] = [
            ["id":0,"role":"AXWebArea"], ["id":1,"parent":0],
            ["id":2,"parent":0,"domClasses":["notion-overlay-container"]],
            ["id":3,"parent":2,"frame":["x":0.0,"y":0,"width":1,"height":1]],
            ["id":4,"parent":3,"role":"AXGroup","subrole":"AXApplicationDialog",
             "frame":["x":20.0,"y":30,"width":200,"height":100]],
            ["id":5,"parent":4],
            ["id":6,"parent":4,"subrole":"AXApplicationDialog",
             "frame":["x":20.0,"y":30,"width":200,"height":100]],
            ["id":7,"role":"AXWebArea"],["id":8,"parent":7]]
        let result=PopupOcclusion(rows:rows)
        XCTAssertEqual(result.masks(for:1),[CGRect(x:20,y:30,width:200,height:100)])
        XCTAssertTrue(result.masks(for:5).isEmpty)
        XCTAssertTrue(result.masks(for:8).isEmpty)
        XCTAssertEqual(result.diagnostics.count,1)
    }

    func testHiddenDialogAndLegacyMenuAreNotNewMasks() {
        for (visible,classes) in [(false,[String]()),(true,["notion-text-action-menu"])] {
            let rows:[[String:Any]] = [
                ["id":0,"role":"AXWebArea"],["id":1,"parent":0],
                ["id":2,"parent":0,"domClasses":["notion-overlay-container"]],
                ["id":3,"parent":2,"subrole":"AXApplicationDialog","popupVisibleOnly":visible,"domClasses":classes,
                 "frame":["x":10.0,"y":20,"width":200,"height":100]]]
            XCTAssertTrue(PopupOcclusion(rows:rows).masks(for:1).isEmpty)
        }
    }

    func testSameDialogMaskClipsImageWithoutChangingOriginalBox() {
        let image:[String:Double] = ["x":0,"y":0,"width":400,"height":400]
        let panel=CGRect(x:100,y:100,width:100,height:100)
        let rows:[[String:Any]] = [
            ["id":0,"role":"AXWebArea"],
            ["id":1,"parent":0,"domClasses":["notion-image-block"]],
            ["id":2,"parent":1,"domClasses":["notion-cursor-default"],"frame":image],
            ["id":3,"parent":0,"domClasses":["notion-overlay-container"]],
            ["id":4,"parent":3,"subrole":"AXApplicationDialog","frame":rect(panel)]]
        let masks=PopupOcclusion(rows:rows)
        let result=ImageRegionBuilder.build(rows:rows,selection:CGRect(x:0,y:0,width:400,height:400),
            viewport:{ _ in CGRect(x:0,y:0,width:400,height:400) },visible:{ _ in true },occlusions:{ masks.masks(for:$0) })
        XCTAssertEqual(result.first?["box"] as? [String:Double],image)
        let boxes=result.first?["displayBoxes"] as? [[String:Double]] ?? []
        XCTAssertEqual(boxes.count,4)
        XCTAssertTrue(boxes.allSatisfy { !CGRect(x:$0["x"]!,y:$0["y"]!,width:$0["width"]!,height:$0["height"]!).intersects(panel) })
    }

    func testRecoveredControlTitleUsesVerifiedOwnerForOcclusion() {
        let rows:[[String:Any]] = [
            ["id":0,"role":"AXWebArea"],
            ["id":1,"parent":0,"role":"AXButton"],
            ["id":2,"controlTextOwner":1,"role":"AXStaticText"],
            ["id":3,"parent":0,"domClasses":["notion-overlay-container"]],
            ["id":4,"parent":3,"subrole":"AXApplicationDialog","frame":rect(CGRect(x:10,y:20,width:100,height:100))],
            ["id":5,"parent":4,"role":"AXButton"],
            ["id":6,"controlTextOwner":5,"role":"AXStaticText"]]
        let result=PopupOcclusion(rows:rows)
        XCTAssertEqual(result.masks(for:2),[CGRect(x:10,y:20,width:100,height:100)])
        XCTAssertTrue(result.masks(for:6).isEmpty)
    }

    func testFullOverlayDialogDoesNotMaskTranslucentBackdrop() {
        let box=rect(CGRect(x:0,y:0,width:500,height:500))
        let rows:[[String:Any]] = [
            ["id":0,"role":"AXWebArea"],["id":1,"parent":0],
            ["id":2,"parent":0,"domClasses":["notion-overlay-container"],"frame":box],
            ["id":3,"parent":2,"subrole":"AXApplicationDialog","frame":box]]
        let result=PopupOcclusion(rows:rows)
        XCTAssertTrue(result.masks(for:1).isEmpty)
        XCTAssertEqual(result.diagnostics.first?["reason"] as? String,"no_verified_semantic_panel_boundary")
    }

    func testSavedPopupReportsPreserveGeometryAndMasks() throws {
        guard let value=ProcessInfo.processInfo.environment["AX_POPUP_VALIDATION_BATCHES"] else { throw XCTSkip("Saved report parity is opt-in") }
        for path in value.split(separator:":") {
            let batch=URL(fileURLWithPath:String(path))
            let data=try JSONSerialization.jsonObject(with:Data(contentsOf:batch)) as! [String:Any]
            for row in data["results"] as! [[String:Any]] where row["status"] as? String == "ok" {
                let folder=batch.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(row["report"] as! String).deletingLastPathComponent()
                func read(_ name:String)throws->Any { try JSONSerialization.jsonObject(with:Data(contentsOf:folder.appendingPathComponent(name))) }
                let old=(try read("native-paragraphs.json") as! [String:Any])["units"] as! [[String:Any]]
                let rebuilt=AXParagraphBuilder.build(nodes:try read("rawAx.json") as! [[String:Any]],selected:try read("candidate.json") as! [[String:Any]])
                XCTAssertEqual(old.count,rebuilt.count)
                for unit in old {
                    let replacement=try XCTUnwrap(rebuilt.first { $0["node"] as? Int == unit["node"] as? Int })
                    for key in ["text","members","box","lineRanges","occlusionBoxes","displayBoxes"] {
                        XCTAssertEqual(NSDictionary(dictionary:[key:unit[key] ?? NSNull()]),NSDictionary(dictionary:[key:replacement[key] ?? NSNull()]),"\(row["scenario"] ?? "") / \(key)")
                    }
                }
            }
        }
    }

    func testOverlappingPanelsSubtractUnionAndClosingClearsMasks() throws {
        let panels=[CGRect(x:10,y:20,width:100,height:100),CGRect(x:50,y:60,width:100,height:100)]
        var rows:[[String:Any]] = [["id":0,"role":"AXWebArea"],["id":1,"parent":0],["id":2,"parent":0,"domClasses":["notion-overlay-container"]]]
        for (i,box) in panels.enumerated() { rows.append(["id":i+3,"parent":2,"subrole":"AXApplicationDialog","frame":rect(box)]) }
        let masks=PopupOcclusion(rows:rows).masks(for:1)
        XCTAssertEqual(masks,panels)
        let unit:[String:Any] = ["node":1,"text":"日本語","box":rect(CGRect(x:0,y:0,width:250,height:250)),"members":[1],"lineRanges":[],"isCodeBlock":false,"protectNonSourceText":false,"occlusionBoxes":masks.map(rect)]
        let paragraph=try JSONDecoder().decode(AXParagraph.self,from:JSONSerialization.data(withJSONObject:unit))
        XCTAssertEqual(paragraph.displayRegions.reduce(0) { $0+$1.width*$1.height },46100)
        XCTAssertTrue(paragraph.displayRegions.allSatisfy { region in panels.allSatisfy { !region.cgRect.intersects($0) } })
        XCTAssertTrue(PopupOcclusion(rows:Array(rows.prefix(3))).masks(for:1).isEmpty)
    }

}
