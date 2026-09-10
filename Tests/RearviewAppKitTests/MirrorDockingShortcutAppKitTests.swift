#if DEBUG
import AppKit
import XCTest
@testable import Rearview

@MainActor
final class MirrorDockingShortcutAppKitTests: XCTestCase {
    func testOverlayDockingShortcutSwitchesToMirrorAndDocks() throws {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        application.finishLaunching()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))

        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            throw XCTSkip("AppKit 화면이 없는 환경에서는 도킹 단축키 테스트를 실행할 수 없습니다.")
        }
        let visibleFrame = screen.visibleFrame
        guard visibleFrame.width >= 520, visibleFrame.height >= 360 else {
            throw XCTSkip("도킹 배치를 검증할 만큼 사용 가능한 화면이 넓지 않습니다.")
        }

        let selection = CGRect(
            x: visibleFrame.minX + 20,
            y: visibleFrame.midY - 90,
            width: min(240, visibleFrame.width * 0.25),
            height: 180
        )
        let window = TranslationMirrorWindow(
            selection: selection,
            screen: screen,
            backgroundOpacity: MirrorBackgroundOpacity.defaultValue,
            displayMode: .overlay,
            overlaySettings: OverlayPresentationSettings.load(),
            initialDockingState: .undocked
        )
        defer { window.closeForSessionStop() }

        window.performDockingShortcut(.right)

        XCTAssertEqual(window.currentDisplayMode, .mirror)
        XCTAssertEqual(window.currentDockingState, .right)
        XCTAssertNotNil(window.dockingSeamFrame)
    }
}
#endif
