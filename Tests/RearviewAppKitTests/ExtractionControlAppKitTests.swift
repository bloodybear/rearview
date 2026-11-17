#if DEBUG
import AppKit
import XCTest
import NotionAXCore
@testable import Rearview

@MainActor
final class ExtractionControlAppKitTests: XCTestCase {
    func testModeButtonStateBadgeAndCallbackInBothPresentations() throws {
        _ = NSApplication.shared
        guard let screen = NSScreen.main else { throw XCTSkip("No display") }
        for mode in [TranslationDisplayMode.mirror, .overlay] {
            let bar = OverlayControlBarController(selection: CGRect(x: 10, y: 10, width: 1000, height: 500), screen: screen,
                displayMode: mode, overlayOpacity: 1, translationBackgroundOpacity: 1, controlBarOpacity: 1,
                activeOverlayOpacity: 1, activeControlBarOpacity: 1, regionBorderOpacity: 1,
                ignoresMouseEvents: false, hosting: .mirrorToolbar)
            let view = bar.takeContentViewForMirrorToolbar(width: 1500)
            func buttons(_ view: NSView) -> [NSButton] {
                (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { buttons($0) }
            }
            bar.setExtractionMode(.ax)
            bar.setApplicationCapture(applications: [], selected: nil)
            let button = try XCTUnwrap(buttons(view).first { $0.accessibilityLabel()?.contains("AX 선택") == true })
            XCTAssertTrue(button.isEnabled)
            XCTAssertTrue(button.image?.isTemplate == true)
            XCTAssertTrue(button.accessibilityLabel()?.contains("OCR") == true)
            let notion = CaptureApplication(processID: 123, bundleIdentifier: "notion.id", name: "Notion")
            bar.setApplicationCapture(applications: [notion], selected: notion)
            XCTAssertTrue(button.accessibilityLabel()?.hasPrefix("AX 모드") == true)
            var calls = 0
            bar.onExtractionModeToggle = { calls += 1 }
            button.performClick(nil)
            XCTAssertEqual(calls, 1)
            bar.setExtractionMode(.ocr)
            XCTAssertTrue(button.accessibilityLabel()?.hasPrefix("OCR 모드") == true)
            bar.releaseContentViewFromMirrorToolbar()
        }
    }
}
#endif
