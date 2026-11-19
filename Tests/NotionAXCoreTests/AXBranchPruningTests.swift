import XCTest
@testable import NotionAXCore

final class AXBranchPruningTests: XCTestCase {
    private let capture = CGRect(x: 0, y: 144, width: 640, height: 616)

    func testBodyOnlyPrunesKnownBlocksOutsideOrClampedAtTheBoundary() {
        let classes = ["notion-text-block"]
        XCTAssertTrue(skip(CGRect(x: 20, y: 144, width: 300, height: 1), classes: classes))
        XCTAssertTrue(skip(CGRect(x: 20, y: 760, width: 300, height: 0), classes: classes))
        XCTAssertTrue(skip(CGRect(x: 20, y: 100, width: 300, height: 32), classes: classes))
        XCTAssertFalse(skip(CGRect(x: 20, y: 142, width: 300, height: 20), classes: classes))
        XCTAssertFalse(skip(CGRect(x: 20, y: 300, width: 300, height: 1), classes: classes))
        XCTAssertFalse(skip(nil, classes: classes))
        XCTAssertFalse(skip(CGRect(x: 20, y: 760, width: 300, height: 0), classes: []))
    }

    func testNativeTableCellUsesItsOwnTableViewport() {
        let table = CGRect(x: 100, y: 200, width: 380, height: 400)
        let scope = AXBranchPruning.Scope.body.descending(into: ["notion-table-tbody-selectable"], frame: table)
        let clipped = CGRect(x: 479, y: 300, width: 1, height: 40)
        XCTAssertTrue(skip(clipped, classes: [], role: "AXCell", scope: scope))
        XCTAssertFalse(skip(clipped, classes: [], role: "AXCell"))
        XCTAssertFalse(skip(CGRect(x: 460, y: 300, width: 50, height: 40), classes: [], role: "AXCell", scope: scope))
    }

    func testProtectedSurfacesKeepTheirDescendants() {
        let scope = AXBranchPruning.Scope.body.descending(into: ["notion-timeline-view"], frame: capture)
            .descending(into: ["notion-table-tbody-selectable"], frame: capture)
        XCTAssertFalse(skip(CGRect(x: 0, y: 760, width: 300, height: 0),
                            classes: ["notion-collection-item"], scope: scope))
    }

    private func skip(_ frame: CGRect?, classes: [String], role: String = "AXGroup",
                      scope: AXBranchPruning.Scope = .body) -> Bool {
        AXBranchPruning.shouldSkipChildren(role: role, classes: classes, frame: frame,
                                          captureViewport: capture, scope: scope)
    }
}
