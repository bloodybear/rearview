import XCTest
@testable import NotionAXCore
final class StickyHeaderClippingTests: XCTestCase {
    func testPartiallyCoveredDatabaseCellAndParagraph() {
        let header = CGRect(x:0,y:140,width:1024,height:36)
        XCTAssertEqual(StickyHeaderClipping.belowHeader(CGRect(x:0,y:151,width:200,height:37),header:header),CGRect(x:0,y:176,width:200,height:12))
        XCTAssertEqual(StickyHeaderClipping.belowHeader(CGRect(x:0,y:160,width:200,height:18),header:header),CGRect(x:0,y:176,width:200,height:2))
        XCTAssertTrue(StickyHeaderClipping.belowHeader(CGRect(x:0,y:145,width:200,height:18),header:header).isNull)
        let visible = CGRect(x:0,y:200,width:200,height:18)
        XCTAssertEqual(StickyHeaderClipping.belowHeader(visible,header:header),visible)
    }
    func testTimelineCalendarUsesWholeHeaderBandDespiteCollapsedPortal() throws {
        let header = try XCTUnwrap(StickyHeaderClipping.timelineHeader(
            listHeader:CGRect(x:0,y:140,width:576,height:68),
            timeline:CGRect(x:0,y:140,width:1018,height:620),
            calendarPortal:CGRect(x:0,y:140,width:1024,height:1)))
        XCTAssertEqual(header, CGRect(x:0,y:140,width:1018,height:68))
        // Right-hand properties behind both the month and date rows.
        for box in [CGRect(x:570,y:154,width:163,height:18), CGRect(x:570,y:190,width:65,height:18)] {
            XCTAssertTrue(StickyHeaderClipping.belowHeader(box,header:header).isNull)
        }
        XCTAssertEqual(StickyHeaderClipping.belowHeader(CGRect(x:600,y:200,width:100,height:18),header:header),
                       CGRect(x:600,y:208,width:100,height:10))
        let below = CGRect(x:600,y:218,width:100,height:18)
        XCTAssertEqual(StickyHeaderClipping.belowHeader(below,header:header),below)
    }

    func testTimelineHeaderRejectsUnrelatedOrMissingCalendarGeometry() {
        let list = CGRect(x:0,y:140,width:576,height:68)
        let timeline = CGRect(x:0,y:140,width:1018,height:620)
        for calendar in [CGRect.zero, CGRect(x:0,y:759,width:1024,height:1), CGRect(x:0,y:140,width:576,height:1)] {
            XCTAssertNil(StickyHeaderClipping.timelineHeader(listHeader:list,timeline:timeline,calendarPortal:calendar))
        }
        XCTAssertNil(StickyHeaderClipping.timelineHeader(listHeader:list,
            timeline:CGRect(x:0,y:421,width:1018,height:339),
            calendarPortal:CGRect(x:0,y:140,width:1024,height:1)))
    }
}
