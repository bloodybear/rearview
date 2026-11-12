import XCTest
import ApplicationServices
@testable import NotionAXCore

final class AXVisibleSelectionTests: XCTestCase {
    func testOnlySearchableOffscreenElementsAreExcluded() {
        XCTAssertTrue(AXVisibleSelection.excludes(discovered:true,visible:false))
        XCTAssertFalse(AXVisibleSelection.excludes(discovered:true,visible:true))
        XCTAssertFalse(AXVisibleSelection.excludes(discovered:false,visible:false))
        XCTAssertFalse(AXVisibleSelection.excludes(discovered:false,visible:true))
    }
    func testMembershipUsesAXIdentity() {
        let first = AXUIElementCreateApplication(123)
        let same = AXUIElementCreateApplication(123)
        let other = AXUIElementCreateApplication(456)
        let membership = AXElementMembership([first])
        XCTAssertTrue(membership.contains(same))
        XCTAssertFalse(membership.contains(other))
    }
}
