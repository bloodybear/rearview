import XCTest
@testable import NotionAXCore

final class PreviewOcclusionTests: XCTestCase {
    func testCenterPeekCoversBackgroundParagraph() {
        let panel = CGRect(x:160,y:168,width:960,height:620)
        XCTAssertTrue(PreviewOcclusion.visibleBoxes(CGRect(x:286,y:401,width:708,height:28),behind:panel).isEmpty)
        let outside = CGRect(x:20,y:200,width:100,height:20)
        XCTAssertEqual(PreviewOcclusion.visibleBoxes(outside,behind:panel),[outside])
    }
    func testPartialCoverageKeepsSeparateVisibleFragments() {
        let box = CGRect(x:0,y:0,width:100,height:100)
        let panel = CGRect(x:20,y:20,width:60,height:60)
        let pieces = PreviewOcclusion.visibleBoxes(box,behind:panel)
        XCTAssertEqual(pieces.count,4)
        XCTAssertEqual(pieces.reduce(0){$0+$1.width*$1.height},6400)
        XCTAssertTrue(pieces.allSatisfy{!$0.intersects(panel)})
        XCTAssertEqual(PreviewOcclusion.visibleBoxes(box,behind:CGRect(x:50,y:0,width:100,height:100)),[CGRect(x:0,y:0,width:50,height:100)])
    }
}
