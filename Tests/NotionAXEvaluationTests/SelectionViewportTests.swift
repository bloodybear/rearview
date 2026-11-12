import XCTest
@testable import NotionAXEvaluation

final class SelectionViewportTests: XCTestCase {
    func testSidebarIsNotClippedToBodyOrPeek() {
        let body = CGRect(x:270,y:140,width:754,height:620)
        let sidebar = CGRect(x:0,y:96,width:270,height:664)
        let window = CGRect(x:0,y:60,width:1024,height:700)
        let label = CGRect(x:46,y:408,width:199,height:18)
        XCTAssertFalse(body.intersects(label))
        XCTAssertTrue(SelectionViewport.region(surface:sidebar,content:body,window:window).contains(label))
        XCTAssertEqual(SelectionViewport.region(surface:nil,content:body,window:window),body)
    }
    func testRightPagePreviewHasIndependentViewport() {
        let body = CGRect(x:0,y:140,width:512,height:720)
        let preview = CGRect(x:512,y:96,width:768,height:764)
        let window = CGRect(x:0,y:60,width:1280,height:800)
        let label = CGRect(x:927,y:324,width:264,height:43)
        XCTAssertFalse(body.intersects(label))
        XCTAssertTrue(SelectionViewport.region(surface:preview,content:body,window:window).contains(label))
        XCTAssertEqual(SelectionViewport.region(surface:nil,content:body,window:window),body)
    }
    func testOffscreenSidebarDoesNotWidenSelection() {
        let window = CGRect(x:0,y:60,width:1024,height:700)
        let hidden = CGRect(x:-270,y:96,width:269,height:664)
        XCTAssertTrue(SelectionViewport.region(surface:hidden,content:window,window:window).isNull)
    }
}
