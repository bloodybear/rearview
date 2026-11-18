import XCTest
@testable import NotionAXCore

final class AXDocumentSurfaceTests: XCTestCase {
    private let box: [String:Double] = ["x":0,"y":0,"width":300,"height":200]
    func testDirectSemanticDialogWithoutOverlayAndBodyRecovery() {
        let root: [String:Any] = ["id":0,"role":"AXWebArea","title":"Document","documentURL":"https://example.test/page","frame":box]
        let body: [String:Any] = ["id":1,"parent":0,"role":"AXGroup","domClasses":["notion-selectable"]]
        let dialog: [String:Any] = ["id":2,"parent":0,"role":"AXGroup","subrole":"AXApplicationDialog","frame":["x":10.0,"y":20.0,"width":80.0,"height":60.0]]
        let normal=AXDocumentSurfaceBuilder.build(rows:[root,body])
        XCTAssertEqual(normal.first?["bodyNodes"] as? [Int],[1])
        let modal=AXDocumentSurfaceBuilder.build(rows:[root,dialog])
        XCTAssertEqual(modal.first?["bodyNodes"] as? [Int],[])
        XCTAssertEqual((modal.first?["dialogBoxes"] as? [[String:Double]])?.count,1)
    }
    func testExcludesPopupBodyTabBarAndFullscreenBackdrop() {
        let rows: [[String:Any]] = [
            ["id":0,"role":"AXWebArea","title":"Document","frame":box],
            ["id":1,"parent":0,"role":"AXGroup","subrole":"AXApplicationDialog","frame":box],
            ["id":2,"parent":1,"role":"AXGroup","domClasses":["notion-selectable"]],
            ["id":3,"role":"AXWebArea","title":"Tab Bar","frame":box]
        ]
        let result=AXDocumentSurfaceBuilder.build(rows:rows)
        XCTAssertEqual(result.count,1)
        XCTAssertEqual(result[0]["bodyNodes"] as? [Int],[])
        XCTAssertEqual((result[0]["dialogBoxes"] as? [[String:Double]])?.count,0)
    }
}
