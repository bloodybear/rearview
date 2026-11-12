import XCTest
@testable import NotionAXEvaluation

final class TimelineClippingTests: XCTestCase {
    func testFullyHiddenAndPartiallyVisibleLabels() {
        let panel = CGRect(x:0, y:140, width:570, height:620)
        XCTAssertTrue(TimelineClipping.visibleBox(CGRect(x:270,y:406,width:98,height:18), behind:panel).isNull)
        XCTAssertEqual(TimelineClipping.visibleBox(CGRect(x:489,y:497,width:222,height:18), behind:panel), CGRect(x:570,y:497,width:141,height:18))
        let visible = CGRect(x:597,y:569,width:182,height:18)
        XCTAssertEqual(TimelineClipping.visibleBox(visible, behind:panel), visible)
    }
    func testStickyHeaderHidesListRowAndClipsNextRow() {
        let header = CGRect(x:0,y:140,width:576,height:68)
        XCTAssertTrue(StickyHeaderClipping.belowHeader(CGRect(x:122,y:155,width:182,height:18),header:header).isNull)
        XCTAssertEqual(StickyHeaderClipping.belowHeader(CGRect(x:90,y:182,width:279,height:37),header:header),CGRect(x:90,y:208,width:279,height:11))
        let visible = CGRect(x:122,y:227,width:182,height:18)
        XCTAssertEqual(StickyHeaderClipping.belowHeader(visible,header:header),visible)
    }
    func testCoveredDateHeadersAndVisibleDates() {
        let panel = CGRect(x:0,y:421,width:570,height:339)
        XCTAssertTrue(TimelineClipping.visibleBox(CGRect(x:404,y:435,width:69,height:18), behind:panel).isNull)
        XCTAssertTrue(TimelineClipping.visibleBox(CGRect(x:17,y:463,width:16,height:16), behind:panel).isNull)
        let visibleDay = CGRect(x:581,y:463,width:8,height:16)
        XCTAssertEqual(TimelineClipping.visibleBox(visibleDay, behind:panel), visibleDay)
    }
    func testDoNotInventRectForNonLeftOrVerticalOverlap() {
        let box = CGRect(x:100,y:100,width:100,height:20)
        XCTAssertEqual(TimelineClipping.visibleBox(box, behind:CGRect(x:150,y:90,width:10,height:50)), box)
        XCTAssertEqual(TimelineClipping.visibleBox(box, behind:CGRect(x:0,y:110,width:150,height:50)), box)
    }
}
