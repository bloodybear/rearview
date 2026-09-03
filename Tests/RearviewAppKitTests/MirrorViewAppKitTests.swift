#if DEBUG
import AppKit
import XCTest
@_spi(Testing) import Rearview

@MainActor
final class MirrorViewAppKitTests: XCTestCase {
    func testNativeCompositePreservesUnifiedSelection() {
        XCTAssertTrue(
            runInApplicationEventLoop {
                NativeMirrorViewTesting.verifiesNativeCompositeAndSelection()
            },
            "네이티브 단일 이미지 합성 또는 선택 fragment 계약이 깨졌습니다."
        )
    }

    func testHorizontalCompressionKeepsOneLineAndSelectionGeometryAligned() {
        XCTAssertTrue(
            runInApplicationEventLoop {
                NativeMirrorViewTesting.verifiesHorizontalCompressionAndFontScaling()
            },
            "가로 압축·폰트 축소 또는 선택 fragment 좌표 계약이 깨졌습니다."
        )
    }

    func testLiveResizeKeepsNativeCompositeStable() {
        XCTAssertTrue(
            runInApplicationEventLoop {
                NativeMirrorViewTesting.verifiesLiveResizeKeepsNativeComposite()
            },
            "live resize 중 native composite가 유지되지 않습니다."
        )
    }

    func testOverlayPanelRoutesInteractiveMouseEvents() {
        XCTAssertTrue(
            runInApplicationEventLoop {
                OverlayPanelTesting.verifiesInteractionRouting()
            },
            "오버레이 패널의 마우스 무시/상호작용 hit-test 계약이 깨졌습니다."
        )
    }

    func testDockPreviewRapidReentryRestoresVisibleState() {
        XCTAssertTrue(
            runInApplicationEventLoop {
                MirrorDockPreviewTesting.verifiesRapidReentry()
            },
            "도킹 후보 재진입 시 고스트 프리뷰가 다시 표시되지 않습니다."
        )
    }

    private func runInApplicationEventLoop(
        _ operation: @escaping @MainActor () -> Bool
    ) -> Bool {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        application.finishLaunching()

        // XCTest owns the process run loop. Pump it around the AppKit operation
        // instead of entering a nested NSApplication.run(), which does not
        // return reliably from an XCTest runner.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        let result = operation()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        return result
    }
}
#endif
