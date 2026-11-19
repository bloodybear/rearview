import XCTest
@testable import NotionAXCore

final class AXScrollDisplacementTests: XCTestCase {
    func testRequiresTwoConsistentVerticalMovements() {
        XCTAssertEqual(NativeSessionAXProvider.agreedScrollDisplacement([-220, -219.5, 0]), -220)
        XCTAssertEqual(NativeSessionAXProvider.agreedScrollDisplacement([0, 220, 220]), 220)
        XCTAssertNil(NativeSessionAXProvider.agreedScrollDisplacement([0, 0, 0]))
        XCTAssertNil(NativeSessionAXProvider.agreedScrollDisplacement([50, -50, 0]))
        XCTAssertNil(NativeSessionAXProvider.agreedScrollDisplacement([220]))
    }
}
