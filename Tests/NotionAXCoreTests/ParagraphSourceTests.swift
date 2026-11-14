import XCTest
@testable import NotionAXCore

final class ParagraphSourceTests: XCTestCase {
    private func paragraph(_ status: String, source: String) throws -> AXParagraph {
        let value: [String:Any] = ["node":1,"text":"\nparent serialization", "lineSourceText":source,
            "lineRangeStatus":status,"box":["x":0,"y":0,"width":100,"height":20],
            "members":[2],"lineRanges":[],"isCodeBlock":false,"protectNonSourceText":false]
        return try JSONDecoder().decode(AXParagraph.self,from:JSONSerialization.data(withJSONObject:value))
    }
    func testNativeSourceRetainsRealBreaksAndUTF16() throws {
        let text = "👩‍💻 日本語\n次の行\n"
        XCTAssertEqual(try paragraph("complete_unverified",source:text).translationSourceText,text)
    }
    func testUnavailableRangesNeverUseParentSerialization() throws {
        for status in ["native_leaf_text_mismatch","native_source_read_failed","native_source_empty","no_static_text_descendants","query_limit_reached"] {
            XCTAssertNil(try paragraph(status,source:"日本語").translationSourceText)
        }
    }
    func testOmittingParentValuePreservesMembershipAndGeometry() throws {
        let box: [String:Double] = ["x":0,"y":0,"width":100,"height":20]
        let original: [[String:Any]] = [["id":0,"role":"AXTextArea","value":"\n日本語","frame":box],
            ["id":1,"parent":0,"role":"AXStaticText","value":"日本語","frame":box]]
        var omitted = original
        omitted[0]["value"] = ""; omitted[0]["valueCollection"] = "omitted_parent_value"
        let selected: [[String:Any]] = [["node":1,"text":"日本語","textSource":"AXValue","box":box]]
        let a = AXParagraphBuilder.build(nodes:original,selected:selected)[0]
        let b = AXParagraphBuilder.build(nodes:omitted,selected:selected)[0]
        for key in ["node","box","members","unitType"] { XCTAssertEqual(NSDictionary(dictionary:[key:a[key]!]),NSDictionary(dictionary:[key:b[key]!])) }
    }
}
