import XCTest
import NotionAXCore
@testable import Rearview

final class TextExtractionPreferenceTests: XCTestCase {
    func testPersistenceDefaultAndEffectiveMode() throws {
        let name = "TextExtractionPreferenceTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(TextExtractionPreference.load(from: defaults), .ax)
        TextExtractionPreference.save(.ocr, to: defaults)
        XCTAssertEqual(TextExtractionPreference.load(from: defaults), .ocr)
        TextExtractionPreference.save(.ax, to: defaults)
        XCTAssertEqual(TextExtractionPreference.load(from: defaults), .ax)
        XCTAssertEqual(TextExtractionPreference.effective(.ax, bundleIdentifier: "notion.id"), .ax)
        XCTAssertEqual(TextExtractionPreference.effective(.ax, bundleIdentifier: nil), .ocr)
        XCTAssertEqual(TextExtractionPreference.effective(.ax, bundleIdentifier: "other"), .ocr)
        XCTAssertEqual(TextExtractionPreference.effective(.ocr, bundleIdentifier: "notion.id"), .ocr)
        AppSettings.reset(to: defaults)
        XCTAssertEqual(TextExtractionPreference.load(from: defaults), .ax)
        defaults.set("invalid", forKey: TextExtractionPreference.defaultsKey)
        XCTAssertEqual(TextExtractionPreference.load(from: defaults), .ax)
    }
}
