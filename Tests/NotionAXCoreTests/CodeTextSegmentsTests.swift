import Foundation
import XCTest
@testable import NotionAXCore
final class CodeTextSegmentsTests: XCTestCase {
    func testConfirmedBoundariesAndLosslessReassembly() {
        for (text, expected) in [
            ("・… 。 「」", []),
            ("・設定・", ["設定"]),
            ("設定・保存", ["設定・保存"]),
            ("「保存してください。」", ["保存してください"]),
            ("申請を受け付け、資料を確認する", ["申請を受け付け、資料を確認する"]),
            ("  設定 を 保存する\r\n", ["設定 を 保存する"]),
            ("状態 == 完了", ["状態", "完了"]),
            ("😀const x = \"保存\"; 保存", ["保存", "保存"])
        ] {
            let parts = AXCodeTextSegments.split(text)
            XCTAssertEqual(parts.map(\.text).joined(),text)
            XCTAssertEqual(parts.filter(\.translates).map(\.text),expected)
            for part in parts { XCTAssertEqual((text as NSString).substring(with:part.range),part.text) }
        }
    }
}
