import XCTest
import AppKit
@testable import NotionAXCore

final class AXForegroundStyleTests: XCTestCase {
    private let key = NSAttributedString.Key("AXForegroundColor")
    private let red = CGColor(srgbRed:0.6,green:0,blue:0,alpha:1)

    func testChecksEveryRunButAllowsOtherFormattingChanges() {
        let source = "日本👩‍💻語"
        let text = NSMutableAttributedString(string:source,attributes:[key:red])
        text.addAttribute(.underlineStyle,value:1,range:NSRange(location:2,length:5))
        XCTAssertNotNil(AXForegroundStyle.uniformColor(in:text,matching:source))
        text.addAttribute(key,value:CGColor(srgbRed:0,green:0,blue:0.6,alpha:1),range:NSRange(location:text.length-1,length:1))
        XCTAssertNil(AXForegroundStyle.uniformColor(in:text,matching:source))
    }

    func testMissingColorAndPartialOrDifferentNativeTextAreUnverified() {
        let text = NSMutableAttributedString(string:"日本語",attributes:[key:red])
        text.removeAttribute(key,range:NSRange(location:1,length:1))
        XCTAssertNil(AXForegroundStyle.uniformColor(in:text,matching:"日本語"))
        XCTAssertNil(AXForegroundStyle.uniformColor(in:NSAttributedString(string:"日",attributes:[key:red]),matching:"日本語"))
        XCTAssertNil(AXForegroundStyle.uniformColor(in:NSAttributedString(string:"日本語",attributes:[key:red]),matching:"日本文"))
    }
}
