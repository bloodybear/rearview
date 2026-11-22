import ApplicationServices
import XCTest
@testable import NotionAXCore

final class AXScrollCoordinateProbeTests: XCTestCase {
    func testOffsetsArePerCoordinateAndKeepStationaryElementsFixed() {
        let element = AXUIElementCreateApplication(1)
        func coordinate(_ id: Int, _ y: Int, range: Range<Int>? = nil) -> AXScrollCoordinateProbe.Coordinate {
            .init(element: element, text: String(id), range: range,
                  box: CGRect(x: 20, y: y, width: 60, height: 16), node: id)
        }
        let old = [coordinate(1, 120), coordinate(1, 123, range: 0..<1), coordinate(2, 180), coordinate(3, 230)]
        let current = [coordinate(1, 93), coordinate(1, 93, range: 0..<1),
                       coordinate(2, 145), coordinate(3, 230), coordinate(4, 295)]
        let result = AXScrollCoordinateProbe.compare(previous: old, current: current, displacement: -20,
            viewport: CGRect(x: 0, y: 0, width: 300, height: 400), exclusions: [])
        XCTAssertEqual(result.records.compactMap { $0["dy"] as? CGFloat }, [7, 10, 15, 0, 15])
        XCTAssertEqual(result.records.compactMap { $0["source"] as? String },
                       ["matched", "matched", "matched", "stationary_or_inconsistent", "inherited"])
    }

    func testContinuingScrollUsesCorrectedCoordinatesAndSkipsUnverifiedPositions() {
        let element = AXUIElementCreateApplication(1)
        let viewport = CGRect(x: 0, y: 0, width: 300, height: 400)
        func line(_ node: Int, _ y: Int) -> AXScrollCoordinateProbe.Coordinate {
            .init(element: element, text: String(node), range: 0..<1,
                  box: CGRect(x: 20, y: y, width: 60, height: 16), node: node)
        }
        let first = AXScrollCoordinateProbe.compare(previous: [line(1, 120), line(2, 210)],
            current: [line(2, 210), line(1, 80)], displacement: -20, viewport: viewport, exclusions: [])
        XCTAssertNil(first.coordinates[0].alignedBox)
        XCTAssertEqual(first.coordinates[1].alignedBox?.minY, 100)

        let second = AXScrollCoordinateProbe.compare(previous: first.coordinates,
            current: [line(2, 190), line(1, 80)], displacement: -20, viewport: viewport, exclusions: [],
            referenceIsStable: false)
        XCTAssertEqual(second.records.compactMap { $0["source"] as? String }, ["unavailable", "matched"])
        XCTAssertNil(second.coordinates[0].alignedBox)
        XCTAssertEqual(second.coordinates[1].alignedBox?.minY, 80)

        let third = AXScrollCoordinateProbe.compare(previous: second.coordinates,
            current: [line(1, 48)], displacement: -20, viewport: viewport, exclusions: [], referenceIsStable: false)
        XCTAssertEqual(third.coordinates[0].alignedBox?.minY, 60)
    }
}
