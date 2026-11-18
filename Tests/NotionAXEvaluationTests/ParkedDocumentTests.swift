import Foundation
import NotionAXCore
import XCTest

final class ParkedDocumentTests: XCTestCase {
    func testRecognizesDocumentsParkedAtOrBeyondWindowEdge() {
        let window = CGRect(x: 3350, y: -641, width: 1546, height: 1355)
        let parked = CGRect(x: 4661, y: 713, width: 1312, height: 1610)
        XCTAssertTrue(isParkedNotionDocument(parked, window: window))
        XCTAssertTrue(isParkedNotionDocument(parked.offsetBy(dx: 0, dy: 1), window: window))
        let active = CGRect(x: 3350, y: -605, width: 1546, height: 1319)
        XCTAssertFalse(isParkedNotionDocument(active, window: window))
        XCTAssertFalse(isParkedNotionDocument(.zero, window: window))
    }
}
