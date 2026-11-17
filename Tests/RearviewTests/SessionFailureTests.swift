import XCTest
import NotionAXCore
@testable import Rearview

final class SessionFailureTests: XCTestCase {
    @MainActor func testPermissionActionUsesCorrectSettingsPane() {
        let notice = SessionFailureNotice()
        var opened: URL?
        notice.openSettings = { opened = $0; return true }
        notice.show(.make(AXExtractionError.permissionDenied, stage: .ax), anchor: nil)
        notice.activate()
        XCTAssertTrue(opened?.absoluteString.contains("Privacy_Accessibility") == true)
        notice.show(.make(TranslatorError.screenPermission, stage: .capture), anchor: nil)
        notice.activate()
        XCTAssertTrue(opened?.absoluteString.contains("Privacy_ScreenCapture") == true)
        notice.dismiss()
    }

    func testPermissionClassificationAndDeduplication() {
        let permission = SessionFailure.make(AXExtractionError.permissionDenied, stage: .ax)
        XCTAssertEqual(permission.permission, .accessibility)
        XCTAssertEqual(SessionFailure.make(TranslatorError.screenPermission, stage: .capture).permission, .screenCapture)
        XCTAssertNil(SessionFailure.make(AXExtractionError.windowMappingFailed, stage: .ax).permission)
        var notices = SessionFailureDeduplicator()
        XCTAssertTrue(notices.shouldPresent(permission, userInitiated: false))
        XCTAssertFalse(notices.shouldPresent(permission, userInitiated: false))
        XCTAssertTrue(notices.shouldPresent(permission, userInitiated: true))
        notices.succeeded(.ocr)
        XCTAssertFalse(notices.shouldPresent(permission, userInitiated: false))
        notices.succeeded(.ax)
        XCTAssertTrue(notices.shouldPresent(permission, userInitiated: false))
        notices.reset()
        XCTAssertTrue(notices.shouldPresent(permission, userInitiated: false))
    }
}
