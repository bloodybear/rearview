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
}
