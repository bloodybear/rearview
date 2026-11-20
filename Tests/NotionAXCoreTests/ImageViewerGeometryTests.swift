import XCTest
@testable import NotionAXCore

final class ImageViewerGeometryTests: XCTestCase {
    func testViewerGeometryFollowsZoomWithAndWithoutToolbar() throws {
        let selection = CGRect(x: 0, y: 84, width: 1024, height: 616)
        let fitted = CGRect(x: 32, y: 103, width: 960, height: 494)
        let zoomed = CGRect(x: 0, y: 0, width: 1024, height: 700)
        let toolbar = CGRect(x: 399, y: 642, width: 226, height: 28)
        let initial = try XCTUnwrap(ImageViewerGeometry.detect(in: rows(image: fitted, toolbar: toolbar)))
        let enlarged = try XCTUnwrap(ImageViewerGeometry.detect(in: rows(image: zoomed, toolbar: toolbar)))
        let idle = try XCTUnwrap(ImageViewerGeometry.detect(in: rows(image: zoomed)))
        XCTAssertEqual(initial.image, fitted)
        XCTAssertEqual(enlarged.image, zoomed)
        XCTAssertEqual(idle.image, zoomed)
        XCTAssertNil(idle.toolbar)
        let boxes = try XCTUnwrap(enlarged.region(in: selection)["displayBoxes"] as? [[String: Double]])
        XCTAssertEqual(boxes.reduce(0) { $0 + $1["width"]! * $1["height"]! },
                       selection.width * selection.height - toolbar.width * toolbar.height)
        XCTAssertEqual(idle.region(in: selection)["status"] as? String, "selected")
    }

    func testGenericPortalOrAmbiguousViewerDoesNotMatch() {
        let image = CGRect(x: 32, y: 103, width: 960, height: 494)
        var tree = rows(image: image)
        tree[4]["subrole"] = nil
        XCTAssertNil(ImageViewerGeometry.detect(in: tree))
        tree = rows(image: image)
        let second = tree.dropFirst().map { row -> [String: Any] in
            var row = row
            if let parent = row["parent"] as? Int, parent > 0 { row["parent"] = parent + 5 }
            return row
        }
        tree.append(contentsOf: second)
        XCTAssertNil(ImageViewerGeometry.detect(in: tree))
    }

    private func rows(image: CGRect, toolbar: CGRect? = nil) -> [[String: Any]] {
        func frame(_ r: CGRect) -> [String: Double] {
            ["x": r.minX, "y": r.minY, "width": r.width, "height": r.height]
        }
        let panel = frame(CGRect(x: 0, y: 0, width: 1024, height: 700))
        var result: [[String: Any]] = [
            ["role": "AXGroup", "domClasses": ["notion-default-overlay-container"], "frame": panel],
            ["parent": 0, "role": "AXGroup", "frame": panel],
        ]
        for parent in 1...4 {
            result.append(["parent": parent, "role": "AXGroup", "subrole": "AXEmptyGroup", "frame": frame(image)])
        }
        if let toolbar {
            result.append(["parent": 1, "role": "AXGroup", "frame": frame(toolbar)])
            result.append(["parent": 6, "role": "AXButton", "title": "150%"])
            result.append(["parent": 6, "role": "AXButton"])
        }
        return result
    }
}
