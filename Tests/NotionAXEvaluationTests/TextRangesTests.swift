import XCTest
@testable import NotionAXEvaluation

final class TextRangesTests: XCTestCase {
    func testNativeLineCanCrossIntoPreviousNodeWithoutChangingSource() {
        XCTAssertTrue(TextRangeSafety.lineCrossesNodeStart("😀 body", before: 5, in: " body"))
        XCTAssertFalse(TextRangeSafety.lineCrossesNodeStart(" body", before: 5, in: " body"))
        XCTAssertFalse(TextRangeSafety.lineCrossesNodeStart("foreign", before: 5, in: " body"))
        XCTAssertFalse(TextRangeSafety.lineCrossesNodeStart("next", before: 9, in: "body\nnext"))
        XCTAssertFalse(TextRangeSafety.lineCrossesNodeStart("prefixA😀", before: 2, in: "A😀"))
        XCTAssertFalse(TextRangeSafety.lineCrossesNodeStart("anything", before: 0, in: "body"))
    }
    func testReverseSuffixRejectsGapsStallsAndSplitSurrogates() {
        let text = "A😀\nB"
        XCTAssertTrue(TextRangeSafety.retreats(CFRange(location:3,length:2),before:5,in:text))
        XCTAssertTrue(TextRangeSafety.retreats(CFRange(location:1,length:2),before:3,in:text))
        XCTAssertFalse(TextRangeSafety.retreats(CFRange(location:2,length:1),before:3,in:text))
        XCTAssertFalse(TextRangeSafety.retreats(CFRange(location:3,length:1),before:5,in:text))
        XCTAssertFalse(TextRangeSafety.retreats(CFRange(location:5,length:0),before:5,in:text))
        XCTAssertFalse(TextRangeSafety.retreats(CFRange(location:-1,length:6),before:5,in:text))
    }
    func testStalledRangeAndGeometry() {
        XCTAssertFalse(TextRangeSafety.advances(CFRange(location: 0, length: 2), from: 2, in: "abcd"))
        XCTAssertFalse(TextRangeSafety.advances(CFRange(location: 3, length: 1), from: 1, in: "abcd"))
        XCTAssertFalse(TextRangeSafety.advances(CFRange(location: 0, length: 4), from: 2, in: "abcd"))
        let clip = CGRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertEqual(TextRangeSafety.visibility(CGRect(x: 0, y: 95, width: 20, height: 10), in: clip), "partial_unknown")
        XCTAssertEqual(TextRangeSafety.visibility(CGRect(x: 0, y: 110, width: 20, height: 10), in: clip), "outside")
        XCTAssertEqual(TextRangeSafety.visibility(.zero, in: clip), "invalid_bounds")
    }
    func testInvalidAndUTF16Boundaries() {
        let text = "A😀B"
        XCTAssertFalse(TextRangeSafety.valid(CFRange(location: -1, length: 1), in: text))
        XCTAssertFalse(TextRangeSafety.valid(CFRange(location: 0, length: 0), in: text))
        XCTAssertFalse(TextRangeSafety.valid(CFRange(location: 1, length: 1), in: text))
        XCTAssertFalse(TextRangeSafety.valid(CFRange(location: 2, length: 1), in: text))
        XCTAssertTrue(TextRangeSafety.valid(CFRange(location: 1, length: 2), in: text))
        XCTAssertFalse(TextRangeSafety.valid(CFRange(location: 3, length: Int.max), in: text))
    }
    func testRepeatedSubstringIsNotAnOffsetMapping() {
        XCTAssertNil(TextRangeSafety.uniqueOffset("同じ", in: "同じ・同じ"))
        XCTAssertNil(TextRangeSafety.uniqueOffset("", in: "abc"))
        XCTAssertEqual(TextRangeSafety.uniqueOffset("B", in: "😀B"), 2)
    }
    func testCharacterProbeBudgetDoesNotSplitEmoji() {
        XCTAssertEqual(TextRangeSafety.characters(String(repeating: "😀", count: 200)).reduce(0) { $0 + $1.length }, 256)
        XCTAssertEqual(TextRangeSafety.characters("A😀B", limit: 2).map(\.length), [1])
        XCTAssertEqual(TextRangeSafety.characters("A😀B", limit: 3).map(\.length), [1,2])
        XCTAssertEqual(TextRangeSafety.characters("A😀B").map(\.location), [0,1,3])
    }
}
