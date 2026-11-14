import XCTest
@testable import NotionAXCore

final class LogicalLinesTests: XCTestCase {
    private func line(_ text: String, _ start: Int, local: Int? = nil) throws -> AXLine {
        var data: [String:Any] = ["text":text,"rangeStart":start,"rangeLength":text.utf16.count,
            "box":["x":0,"y":0,"width":100,"height":18]]
        data["segmentRangeStart"] = local
        return try JSONDecoder().decode(AXLine.self,from:JSONSerialization.data(withJSONObject:data))
    }
    func testHardBreakAndSoftWrapUseDifferentGroups() throws {
        let groups = try AXLogicalLines.split("長い文です\n次",lines:[line("長い",0),line("文です\n",2),line("次",6)])
        XCTAssertEqual(groups.map(\.text),["長い文です","次"])
        XCTAssertEqual(groups.map(\.lineIndices),[[0,1],[2]])
    }
    func testBlankLeadingTrailingAndCRLFKeepExactDelimiters() throws {
        let source = "\n👩‍💻\r\n\n次\n"
        let groups = try AXLogicalLines.split(source,lines:[line("👩‍💻\r\n",1),line("次\n",9)])
        XCTAssertEqual(groups.map { $0.text+$0.delimiter }.joined(),source)
        XCTAssertEqual(groups.map(\.lineIndices),[[],[0],[],[1],[]])
    }
    func testSegmentLocalUTF16RangesOverrideParagraphOffset() throws {
        XCTAssertEqual(try AXLogicalLines.split("次\n",lines:[line("次\n",88,local:0)]).first?.lineIndices,[0])
    }
    func testAmbiguousOrMissingOrMismatchedRangesAreRejected() throws {
        XCTAssertThrowsError(try AXLogicalLines.split("a\nb",lines:[line("a\nb",0)]))
        XCTAssertThrowsError(try AXLogicalLines.split("a\nb",lines:[line("a\n",0)]))
        XCTAssertThrowsError(try AXLogicalLines.split("a",lines:[line("b",0)]))
        XCTAssertThrowsError(try AXLogicalLines.split("abcd",lines:[line("ab",0)]))
        XCTAssertThrowsError(try AXLogicalLines.split("ab",lines:[line("ab",0),line("b",1)]))
    }
    func testGeneratedBreaksBecomeOneSpaceEachWithoutTrimming() {
        XCTAssertEqual(AXLogicalLines.flattenGeneratedBreaks("  a\r\n\nb\u{2028}c\t"),"  a  b c\t")
    }
}
