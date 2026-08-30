import AppKit
import Testing
@testable import Rearview

@Suite
struct ScreenCapturePermissionWindowTests {
    @Test
    func permissionCatalogIsCompleteForEverySupportedLanguage() {
        let keys = [
            "화면 기록 권한이 필요합니다",
            "Rearview는 선택한 화면 영역의 텍스트를 인식하고 번역합니다. 계속하려면 화면 기록 권한이 필요합니다.",
            "계속",
            "다시 확인",
            "시스템 설정에서 Rearview의 화면 기록 권한을 켜 주세요.",
            "시스템 설정 열기",
            "화면 기록 권한이 확인되었습니다",
            "%@을 눌러 번역할 화면 영역을 선택하세요. 메뉴바의 Rearview 아이콘에서 ‘영역 선택…’을 선택해 시작할 수도 있습니다.",
            "메뉴바의 Rearview 아이콘에서 ‘영역 선택…’을 선택해 시작하세요.",
            "확인"
        ]
        for language in AppDisplayLanguage.allCases {
            for key in keys {
                #expect(L10n.hasTranslation(for: key, language: language))
            }
        }
    }

    @Test @MainActor
    func bothPermissionWindowsHaveCompleteLocalizedLayouts() {
        for language in AppDisplayLanguage.allCases {
            for kind in ScreenCapturePermissionWindowKind.allCases {
                let controller = ScreenCapturePermissionWindowController(
                    kind: kind,
                    language: language
                )
                controller.showWindow(nil)
                defer { controller.window?.orderOut(nil) }
                controller.window?.contentView?.layoutSubtreeIfNeeded()

                #expect(controller.window?.title == "Rearview")
                #expect(textField(
                    "screen-capture-permission-title", in: controller.window?.contentView
                )?.stringValue == L10n.text(
                    "화면 기록 권한이 필요합니다", language: language
                ))
                #expect(textField(
                    "screen-capture-permission-message", in: controller.window?.contentView
                )?.stringValue.isEmpty == false)
                #expect(!hasAmbiguousLayout(in: controller.window?.contentView))
                #expect(permissionContentFits(in: controller.window?.contentView))
                #expect(visibleButtons(in: controller.window?.contentView).allSatisfy {
                    !$0.title.isEmpty && $0.title != "Button"
                })
            }
        }
    }

    @Test @MainActor
    func introductionHasOnlyContinue() {
        let controller = ScreenCapturePermissionWindowController(
            kind: .introduction,
            language: .english
        )

        #expect(button(
            "screen-capture-permission-request", in: controller.window?.contentView
        )?.title == "Continue")
        #expect(button(
            "screen-capture-permission-settings", in: controller.window?.contentView
        ) == nil)
        #expect(visibleButtons(in: controller.window?.contentView).count == 1)
    }

    @Test @MainActor
    func recoveryKeepsItsContentStableWhileChecking() {
        let controller = ScreenCapturePermissionWindowController(
            kind: .recovery,
            language: .english
        )
        let message = textField(
            "screen-capture-permission-message", in: controller.window?.contentView
        )?.stringValue

        #expect(button(
            "screen-capture-permission-request", in: controller.window?.contentView
        )?.title == "Check Again")
        #expect(button(
            "screen-capture-permission-settings", in: controller.window?.contentView
        )?.title == "Open System Settings")
        #expect(button(
            "screen-capture-permission-settings", in: controller.window?.contentView
        )?.keyEquivalent == "\r")
        #expect(visibleButtons(in: controller.window?.contentView).count == 2)

        controller.setChecking(true)

        #expect(textField(
            "screen-capture-permission-message", in: controller.window?.contentView
        )?.stringValue == message)
        #expect(button(
            "screen-capture-permission-request", in: controller.window?.contentView
        )?.isEnabled == false)
        #expect(button(
            "screen-capture-permission-settings", in: controller.window?.contentView
        )?.isEnabled == true)
    }

    @Test @MainActor
    func confirmedPermissionShowsNextStepAndOnlyConfirmationButton() {
        for language in AppDisplayLanguage.allCases {
            let controller = ScreenCapturePermissionWindowController(
                kind: .recovery,
                language: language
            )
            controller.showPermissionConfirmed(selectionShortcutTitle: "⇧⌘1")
            controller.window?.contentView?.layoutSubtreeIfNeeded()

            #expect(textField(
                "screen-capture-permission-title", in: controller.window?.contentView
            )?.stringValue == L10n.text(
                "화면 기록 권한이 확인되었습니다", language: language
            ))
            #expect(textField(
                "screen-capture-permission-message", in: controller.window?.contentView
            )?.stringValue == L10n.format(
                "%@을 눌러 번역할 화면 영역을 선택하세요. 메뉴바의 Rearview 아이콘에서 ‘영역 선택…’을 선택해 시작할 수도 있습니다.",
                "⇧⌘1",
                language: language
            ))
            #expect(button(
                "screen-capture-permission-request", in: controller.window?.contentView
            )?.title == L10n.text("확인", language: language))
            #expect(button(
                "screen-capture-permission-settings", in: controller.window?.contentView
            ) == nil)
            #expect(visibleButtons(in: controller.window?.contentView).count == 1)
            #expect(!hasAmbiguousLayout(in: controller.window?.contentView))
            #expect(permissionContentFits(in: controller.window?.contentView))
        }
    }

    @Test @MainActor
    func confirmedPermissionUsesMenuBarOnlyCopyWhenShortcutIsDisabled() {
        let controller = ScreenCapturePermissionWindowController(
            kind: .recovery,
            language: .korean
        )
        controller.showPermissionConfirmed(selectionShortcutTitle: nil)

        #expect(textField(
            "screen-capture-permission-message", in: controller.window?.contentView
        )?.stringValue == "메뉴바의 Rearview 아이콘에서 ‘영역 선택…’을 선택해 시작하세요.")
    }

    @Test @MainActor
    func confirmationButtonUsesTheConfirmationAction() {
        let controller = ScreenCapturePermissionWindowController(kind: .recovery)
        var retries = 0
        var confirmations = 0
        controller.onRetryPermission = { retries += 1 }
        controller.onConfirmPermission = { confirmations += 1 }
        controller.showPermissionConfirmed(selectionShortcutTitle: "⇧⌘1")

        button(
            "screen-capture-permission-request", in: controller.window?.contentView
        )?.performClick(nil)

        #expect(retries == 0)
        #expect(confirmations == 1)
    }

    @Test @MainActor
    func titleBarCloseQuitsBeforePermissionButOnlyClosesConfirmation() {
        var quitRequests = 0
        let introduction = ScreenCapturePermissionWindowController(kind: .introduction)
        introduction.onQuit = { quitRequests += 1 }
        #expect(introduction.windowShouldClose(introduction.window!) == false)
        #expect(quitRequests == 1)

        let recovery = ScreenCapturePermissionWindowController(kind: .recovery)
        recovery.onQuit = { quitRequests += 1 }
        #expect(recovery.windowShouldClose(recovery.window!) == false)
        #expect(quitRequests == 2)

        recovery.showPermissionConfirmed(selectionShortcutTitle: "⇧⌘1")
        #expect(recovery.windowShouldClose(recovery.window!) == true)
        #expect(quitRequests == 2)
    }

    @Test @MainActor
    func actionRowUsesTheSameBottomInsetForEveryPresentation() {
        for language in AppDisplayLanguage.allCases {
            let introduction = ScreenCapturePermissionWindowController(
                kind: .introduction,
                language: language
            )
            #expect(actionRowBottomInset(in: introduction) == 24)

            let recovery = ScreenCapturePermissionWindowController(
                kind: .recovery,
                language: language
            )
            #expect(actionRowBottomInset(in: recovery) == 24)
            recovery.showPermissionConfirmed(selectionShortcutTitle: "⇧⌘1")
            #expect(actionRowBottomInset(in: recovery) == 24)
        }
    }

    @Test
    func permissionConfirmationHistoryPersistsAfterItIsShown() {
        let suiteName = "ScreenCapturePermissionConfirmationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(!ScreenCapturePermissionConfirmation.hasBeenShown(in: defaults))
        ScreenCapturePermissionConfirmation.markShown(in: defaults)
        #expect(ScreenCapturePermissionConfirmation.hasBeenShown(in: defaults))
    }

    @Test @MainActor
    func onlyRecoveryWindowRequestsAProbeWhenItBecomesKey() {
        var introductionActivations = 0
        let introduction = ScreenCapturePermissionWindowController(kind: .introduction)
        introduction.onRecoveryWindowBecameKey = { introductionActivations += 1 }
        introduction.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
        #expect(introductionActivations == 0)

        var recoveryActivations = 0
        let recovery = ScreenCapturePermissionWindowController(kind: .recovery)
        recovery.onRecoveryWindowBecameKey = { recoveryActivations += 1 }
        recovery.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
        #expect(recoveryActivations == 1)

        recovery.showPermissionConfirmed(selectionShortcutTitle: "⇧⌘1")
        recovery.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
        #expect(recoveryActivations == 1)
    }

    @Test @MainActor
    func initialExplanationIsTranslationDirectionNeutral() {
        for language in AppDisplayLanguage.allCases {
            let controller = ScreenCapturePermissionWindowController(
                kind: .introduction,
                language: language
            )
            let message = textField(
                "screen-capture-permission-message", in: controller.window?.contentView
            )?.stringValue ?? ""
            #expect(!message.localizedCaseInsensitiveContains("Japanese"))
            #expect(!message.contains("일본어"))
            #expect(!message.contains("日本語"))
        }
    }

    @MainActor
    private func button(_ identifier: String, in view: NSView?) -> NSButton? {
        descendant(identifier, in: view) as? NSButton
    }

    @MainActor
    private func textField(_ identifier: String, in view: NSView?) -> NSTextField? {
        descendant(identifier, in: view) as? NSTextField
    }

    @MainActor
    private func descendant(_ identifier: String, in view: NSView?) -> NSView? {
        guard let view else { return nil }
        if view.accessibilityIdentifier() == identifier { return view }
        for subview in view.subviews {
            if let result = descendant(identifier, in: subview) { return result }
        }
        return nil
    }

    @MainActor
    private func visibleButtons(in view: NSView?) -> [NSButton] {
        guard let view else { return [] }
        return (view as? NSButton).map { [$0] }
            ?? view.subviews.flatMap { visibleButtons(in: $0) }
    }

    @MainActor
    private func hasAmbiguousLayout(in view: NSView?) -> Bool {
        guard let view else { return false }
        return view.hasAmbiguousLayout
            || view.subviews.contains { hasAmbiguousLayout(in: $0) }
    }

    @MainActor
    private func permissionContentFits(in contentView: NSView?) -> Bool {
        guard let contentView else { return false }
        let identifiers = [
            "screen-capture-permission-title",
            "screen-capture-permission-message",
            "screen-capture-permission-request",
            "screen-capture-permission-settings"
        ]
        for identifier in identifiers {
            guard let view = descendant(identifier, in: contentView) else { continue }
            let frame = view.convert(view.bounds, to: contentView)
            guard contentView.bounds.insetBy(dx: -1, dy: -1).contains(frame) else {
                return false
            }
        }
        return true
    }

    @MainActor
    private func actionRowBottomInset(
        in controller: ScreenCapturePermissionWindowController
    ) -> CGFloat? {
        guard let contentView = controller.window?.contentView else { return nil }
        contentView.layoutSubtreeIfNeeded()
        guard let row = descendant(
            "screen-capture-permission-actions", in: contentView
        ) else { return nil }
        return row.convert(row.bounds, to: contentView).minY
    }
}
