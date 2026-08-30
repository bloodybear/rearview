import Foundation
import AppKit
import Carbon
import Testing
@testable import Rearview

@Suite
struct SettingsAndShortcutTests {
    @Test func displayLanguageLocalizationAndResetRoundTrip() {
        withTestDefaults { defaults in
            #expect(AppDisplayLanguage.load(
                from: defaults, preferredLanguages: ["fr-FR", "ja-JP", "en-US"]
            ) == .japanese)
            #expect(AppDisplayLanguage.load(
                from: defaults, preferredLanguages: ["fr-FR", "zh-Hans"]
            ) == .english)
            AppDisplayLanguage.japanese.save(to: defaults)
            #expect(AppDisplayLanguage.load(
                from: defaults, preferredLanguages: ["ko-KR"]
            ) == .japanese)
            defaults.set("unsupported", forKey: AppDisplayLanguage.defaultsKey)
            #expect(AppDisplayLanguage.load(
                from: defaults, preferredLanguages: ["ko_KR"]
            ) == .korean)
            AppDisplayLanguage.english.save(to: defaults)
            AppSettings.reset(to: defaults)
            #expect(AppDisplayLanguage.load(
                from: defaults, preferredLanguages: ["ja-JP"]
            ) == .japanese)
            #expect(L10n.text("설정", language: .english) == "Settings")
            #expect(L10n.text("설정", language: .japanese) == "設定")
            #expect(L10n.format("번역 중 %d/%d", 2, 5, language: .english) == "Translating 2/5")
        }
    }

    @Test func translationTextProtectionDefaultsAndRoundTrip() {
        withTestDefaults { defaults in
            #expect(TranslationTextProtection.load(from: defaults) == AppDefaults.protectNonSourceText)
            #expect(AppDefaults.protectNonSourceText)
            TranslationTextProtection.save(false, to: defaults)
            #expect(!TranslationTextProtection.load(from: defaults))
            AppSettings.reset(to: defaults)
            #expect(TranslationTextProtection.load(from: defaults) == AppDefaults.protectNonSourceText)
            #expect(L10n.text("원문 외 텍스트 보호", language: .english) == "Protect Non-Source Text")
            #expect(L10n.text(
                "활성화하면 원문 언어 이외의 텍스트(영어·반대 언어·숫자)를 번역 대상에서 제외하고 원문 그대로 유지합니다. 번역은 분리된 텍스트 단위로 처리되므로 전체 문맥이 나뉠 수 있습니다. 비활성화하면 혼합된 텍스트 전체를 하나의 번역 단위로 처리해 문맥을 반영할 수 있지만, 영어·반대 언어·숫자도 번역되거나 변경될 수 있습니다.",
                language: .english
            ).contains("separate text units"))
        }
    }

    @Test func mirrorDockingStateAndFrameRoundTrip() {
        withTestDefaults { defaults in
            #expect(MirrorDockingState.undocked.toggled(with: .right) == .right)
            #expect(MirrorDockingState.right.toggled(with: .right) == .undocked)
            #expect(MirrorDockingState.left.toggled(with: .right) == .right)
            #expect(MirrorDockingState.load(from: defaults) == .undocked)
            #expect(MirrorDockAlignment.shortcutDefault(for: .top) == .center)
            #expect(MirrorDockAlignment.shortcutDefault(for: .bottom) == .center)
            #expect(MirrorDockAlignment.shortcutDefault(for: .left) == .center)
            #expect(MirrorDockAlignment.shortcutDefault(for: .right) == .center)

            MirrorDockingState.right.save(to: defaults)
            let frame = CGRect(x: 10, y: 20, width: 300, height: 200)
            MirrorDockingState.saveUndockedFrame(frame, to: defaults)
            #expect(MirrorDockingState.load(from: defaults) == .right)
            #expect(MirrorDockingState.loadUndockedFrame(from: defaults) == frame)
            AppSettings.reset(to: defaults)
            #expect(MirrorDockingState.load(from: defaults) == .undocked)
            #expect(MirrorDockingState.loadUndockedFrame(from: defaults) == nil)
        }
    }

    @Test func focusAndShortcutConflictPolicies() {
        #expect(!DisplayModeFocusBehavior.preserveKeyWindow.shouldTransferFocus(isDisplayKeyWindow: true))
        #expect(!DisplayModeFocusBehavior.transferIfDisplayIsKeyWindow.shouldTransferFocus(isDisplayKeyWindow: false))
        #expect(DisplayModeFocusBehavior.transferIfDisplayIsKeyWindow.shouldTransferFocus(isDisplayKeyWindow: true))

        let configured = [ConfiguredShortcut(
            identifier: "selection",
            keyCode: UInt32(kVK_ANSI_1),
            modifiers: UInt32(cmdKey | shiftKey),
            isEnabled: true
        )]
        #expect(!isShortcutRegistrationAvailable(
            keyCode: UInt32(kVK_ANSI_1), modifiers: UInt32(cmdKey | shiftKey),
            identifier: "toolbar.displayMode", existing: configured
        ))
        #expect(isShortcutRegistrationAvailable(
            keyCode: UInt32(kVK_ANSI_2), modifiers: UInt32(cmdKey | shiftKey),
            identifier: "toolbar.displayMode", existing: configured
        ))
        #expect(isShortcutRegistrationAvailable(
            keyCode: UInt32(kVK_ANSI_C), modifiers: UInt32(cmdKey),
            identifier: "toolbar.copyAll", existing: []
        ))
        #expect(isShortcutRegistrationAvailable(
            keyCode: UInt32(kVK_ANSI_Q), modifiers: UInt32(cmdKey),
            identifier: "stopTranslation", existing: []
        ))
        #expect(isShortcutRegistrationAvailable(
            keyCode: UInt32(kVK_Space), modifiers: 0,
            identifier: "toolbar.sessionControlSingleKey", existing: []
        ))
        #expect(!isShortcutRegistrationAvailable(
            keyCode: UInt32(kVK_Space), modifiers: 0,
            identifier: "toolbar.refreshMode", existing: []
        ))
    }

    @Test func toolbarShortcutDefaultsAndPresentation() {
        withTestDefaults { defaults in
            #expect(ToolbarShortcutAction.allCases.count == 26)
            #expect(ToolbarHotKey.defaultValue(for: .dockTop).keyCode == UInt32(kVK_UpArrow))
            #expect(ToolbarHotKey.defaultValue(for: .dockBottom).keyCode == UInt32(kVK_DownArrow))
            #expect(ToolbarHotKey.defaultValue(for: .dockLeft).keyCode == UInt32(kVK_LeftArrow))
            #expect(ToolbarHotKey.defaultValue(for: .dockRight).keyCode == UInt32(kVK_RightArrow))
            let space = ToolbarHotKey(
                keyCode: UInt32(kVK_Space), modifiers: 0, keyLabel: "Space", isEnabled: true
            )
            #expect(ToolbarHotKey.defaultValue(for: .sessionControlSingleKey) == space)
            #expect(space.title == "␣")
            #expect(space.settingsTitle == "SPACE")

            for action in ToolbarShortcutAction.configurableActions {
                #expect(ToolbarHotKey.defaultValue(for: action) == AppDefaults.toolbarHotKey(for: action))
            }

            let shortcut = ToolbarHotKey(
                keyCode: UInt32(kVK_ANSI_Z), modifiers: UInt32(cmdKey | shiftKey),
                keyLabel: "Z", isEnabled: true
            )
            shortcut.save(action: .displayMode, to: defaults)
            #expect(ToolbarHotKey.load(action: .displayMode, from: defaults) == shortcut)
            #expect(ToolbarHotKey.load(action: .copyAll, from: defaults)
                == ToolbarHotKey.defaultValue(for: .copyAll))
            let tooltip = toolbarShortcutToolTip("표시 모드", action: .displayMode, defaults: defaults)
            #expect(tooltip.hasPrefix("표시 모드\n"))
            #expect(tooltip.contains(shortcut.title))
            #expect(immediateTranslationHotKeyToolTip("즉시 번역", defaults: defaults)
                == "즉시 번역\n⌥⌘2")

            let immediate = ImmediateTranslationHotKey(
                keyCode: UInt32(kVK_ANSI_N), modifiers: UInt32(controlKey | optionKey), keyLabel: "N"
            )
            immediate.save(to: defaults)
            #expect(ImmediateTranslationHotKey.load(from: defaults) == immediate)
            #expect(immediate.title == "⌃⌥N")
            let activation = MirrorActivationHotKey(
                keyCode: UInt32(kVK_ANSI_M), modifiers: UInt32(cmdKey | optionKey), keyLabel: "M"
            )
            activation.save(to: defaults)
            #expect(MirrorActivationHotKey.load(from: defaults) == activation)
            #expect(ImmediateTranslationHotKey(
                keyCode: UInt32(kVK_ANSI_2), modifiers: UInt32(cmdKey | optionKey),
                keyLabel: "2", isEnabled: false
            ).title == L10n.text("사용 안 함"))
            #expect(MirrorActivationHotKey(
                keyCode: UInt32(kVK_ANSI_3), modifiers: UInt32(cmdKey | optionKey),
                keyLabel: "3", isEnabled: false
            ).title == L10n.text("사용 안 함"))
        }
    }

    @Test func selectionShortcutsAndMenuMappingRoundTrip() {
        withTestDefaults { defaults in
            #expect(ToolbarHotKey.load(selectionAction: .displayMode, from: defaults)
                == ToolbarHotKey.defaultValue(selectionAction: .displayMode))
            #expect(ToolbarHotKey.defaultValue(selectionAction: .displayMode).keyCode == UInt32(kVK_ANSI_2))
            #expect(ToolbarHotKey.defaultValue(selectionAction: .displayMode).modifiers == 0)
            #expect(ToolbarHotKey.defaultValue(selectionAction: .dockTop)
                == ToolbarHotKey(keyCode: UInt32(kVK_ANSI_W), modifiers: 0, keyLabel: "W", isEnabled: true))
            #expect(ToolbarHotKey.defaultValue(selectionAction: .dockBottom)
                == ToolbarHotKey(keyCode: UInt32(kVK_ANSI_S), modifiers: 0, keyLabel: "S", isEnabled: true))
            #expect(ToolbarHotKey.defaultValue(selectionAction: .dockLeft)
                == ToolbarHotKey(keyCode: UInt32(kVK_ANSI_A), modifiers: 0, keyLabel: "A", isEnabled: true))
            #expect(ToolbarHotKey.defaultValue(selectionAction: .dockRight)
                == ToolbarHotKey(keyCode: UInt32(kVK_ANSI_D), modifiers: 0, keyLabel: "D", isEnabled: true))

            let shortcut = ToolbarHotKey(
                keyCode: UInt32(kVK_ANSI_M), modifiers: 0, keyLabel: "M", isEnabled: true
            )
            shortcut.save(selectionAction: .displayMode, to: defaults)
            #expect(ToolbarHotKey.load(selectionAction: .displayMode, from: defaults) == shortcut)
            let disabled = ToolbarHotKey(
                keyCode: UInt32(kVK_ANSI_M), modifiers: 0, keyLabel: "M", isEnabled: false
            )
            disabled.save(selectionAction: .dockTop, to: defaults)
            #expect(ToolbarHotKey.load(selectionAction: .dockTop, from: defaults) == disabled)
            #expect(ToolbarHotKey.load(selectionAction: .dockBottom, from: defaults)
                == ToolbarHotKey.defaultValue(selectionAction: .dockBottom))

            AppSettings.reset(to: defaults)
            #expect(ToolbarHotKey.load(selectionAction: .dockTop, from: defaults)
                == ToolbarHotKey.defaultValue(selectionAction: .dockTop))

            let menuItem = NSMenuItem(title: "표시 모드", action: nil, keyEquivalent: "")
            applyMenuShortcut(shortcut, to: menuItem)
            #expect(menuItem.keyEquivalent == "m")
            #expect(menuItem.keyEquivalentModifierMask.isEmpty)
            let spaceItem = NSMenuItem(title: "세션 제어", action: nil, keyEquivalent: "")
            applyMenuShortcut(ToolbarHotKey.defaultValue(for: .sessionControlSingleKey), to: spaceItem)
            #expect(spaceItem.keyEquivalent == "␣")
            #expect(spaceItem.keyEquivalentModifierMask.isEmpty)
            let disabledItem = NSMenuItem(title: "비활성", action: nil, keyEquivalent: "q")
            disabledItem.keyEquivalentModifierMask = [.command]
            applyMenuShortcut(disabled, to: disabledItem)
            #expect(disabledItem.keyEquivalent.isEmpty)
            #expect(disabledItem.keyEquivalentModifierMask.isEmpty)
        }
    }

    @Test func keyLabelsAndDisplayModesUseStableFallbacks() {
        withTestDefaults { defaults in
            #expect(HotKeyKeyLabel.resolve(keyCode: UInt16(kVK_ANSI_1), fallback: "!") == "1")
            #expect(HotKeyKeyLabel.resolve(keyCode: UInt16(kVK_ANSI_A), fallback: "å") == "A")
            #expect(HotKeyKeyLabel.resolve(keyCode: UInt16(kVK_ANSI_Slash), fallback: "?") == "/")
            #expect(TranslationDirection.load(from: defaults) == AppDefaults.translationDirection)
            #expect(RefreshMode.load(from: defaults) == AppDefaults.refreshMode)
            RefreshMode.manual.save(to: defaults)
            #expect(RefreshMode.load(from: defaults) == .manual)
            defaults.set("unsupported", forKey: RefreshMode.defaultsKey)
            #expect(RefreshMode.load(from: defaults) == AppDefaults.refreshMode)
            #expect(MirrorUpdateStyle.resolve(nil) == AppDefaults.mirrorUpdateStyle)
            #expect(MirrorUpdateStyle.resolve("invalid") == AppDefaults.mirrorUpdateStyle)
            #expect(MirrorUpdateStyle.resolve("progressive") == .progressive)
            #expect(TranslationDisplayMode.resolve(nil) == AppDefaults.translationDisplayMode)
            #expect(TranslationDisplayMode.resolve("invalid") == AppDefaults.translationDisplayMode)
            #expect(TranslationDisplayMode.resolve("overlay") == .overlay)
            TranslationDisplayMode.overlay.save(to: defaults)
            #expect(TranslationDisplayMode.load(from: defaults) == .overlay)
            #expect(RefreshMode.resolve(nil) == AppDefaults.refreshMode)
            #expect(RefreshMode.resolve("invalid") == AppDefaults.refreshMode)
            #expect(RefreshMode.resolve("manual") == .manual)
        }
    }

    @Test func opacityPresentationAndInputPoliciesRoundTrip() {
        withTestDefaults { defaults in
            #expect(OverlayControlBarOpacity.clamp(-1) == 0)
            #expect(OverlayControlBarOpacity.clamp(2) == 1)
            #expect(OverlayControlBarOpacity.load(from: defaults) == AppDefaults.inactiveControlBarOpacity)
            #expect(OverlayActiveOpacity.load(from: defaults) == OverlayActiveOpacity.defaultValue)
            #expect(OverlayControlBarActiveOpacity.load(from: defaults)
                == OverlayControlBarActiveOpacity.defaultValue)
            #expect(OverlayOpacity.load(from: defaults) == AppDefaults.inactiveOverlayOpacity)
            #expect(OverlayOpacity.clamp(0) == 0.1)
            #expect(expectApproximatelyEqual(OverlayOpacity.clamp(0.55), 0.55))
            #expect(OverlayOpacity.clamp(2) == 1)
            #expect(OverlayControlBarOpacity.clamp(0) == 0)
            #expect(MirrorBackgroundOpacity.clamp(-0.2) == 0)
            #expect(expectApproximatelyEqual(MirrorBackgroundOpacity.clamp(0.55), 0.55))
            #expect(MirrorBackgroundOpacity.clamp(1.2) == 1)
            #expect(RegionBorderOpacity.clamp(-0.2) == 0)
            #expect(expectApproximatelyEqual(RegionBorderOpacity.clamp(0.70), 0.70))
            #expect(RegionBorderOpacity.clamp(1.2) == 1)

            OverlayOpacity.save(0.65, to: defaults)
            #expect(expectApproximatelyEqual(OverlayOpacity.load(from: defaults), 0.65))
            OverlayActiveOpacity.save(0.91, to: defaults)
            #expect(expectApproximatelyEqual(OverlayActiveOpacity.load(from: defaults), 0.91))
            OverlayControlBarActiveOpacity.save(0.82, to: defaults)
            #expect(expectApproximatelyEqual(OverlayControlBarActiveOpacity.load(from: defaults), 0.82))
            RegionBorderOpacity.save(0.45, to: defaults)
            #expect(expectApproximatelyEqual(RegionBorderOpacity.load(from: defaults), 0.45))

            var presentation = OverlayPresentationSettings.load(from: defaults)
            presentation.inactiveContentOpacity = 0.51
            presentation.activeContentOpacity = 0.92
            presentation.inactiveControlBarOpacity = 0.43
            presentation.activeControlBarOpacity = 0.84
            presentation.regionBorderOpacity = 0.46
            presentation.ignoresMouseEvents = true
            presentation.save(to: defaults)
            #expect(OverlayPresentationSettings.load(from: defaults) == presentation)
            #expect(OverlayIgnoresMouseEvents.load(from: defaults) == AppDefaults.overlayIgnoresMouseEvents)
            OverlayIgnoresMouseEvents.save(false, to: defaults)
            #expect(!OverlayIgnoresMouseEvents.load(from: defaults))
            #expect(overlayAcceptsMouseEvents(selectionModeEnabled: true, ignoresMouseEvents: true))
            #expect(!overlayAcceptsMouseEvents(selectionModeEnabled: false, ignoresMouseEvents: true))
            #expect(overlayAcceptsMouseEvents(selectionModeEnabled: false, ignoresMouseEvents: false))
        }
    }

    @Test func toolbarCatalogAndShortcutSourcesRespectProductRules() {
        #expect(!AppSettings.defaultsKeys.contains("overlayControlBarCollapsed"))
        #expect(overlayControlBarShortcutSource(for: .pause) == .toolbar(.sessionControlSingleKey))
        #expect(overlayControlBarShortcutSource(for: .translate) == .immediateTranslation)
        #expect(overlayControlBarShortcutSource(for: .opacity) == nil)
        #expect(overlayControlBarShortcutSource(for: .zoomOut) == .toolbar(.zoomOut))

        let overlay = OverlayControlBarCatalog.availableItems(
            displayMode: .overlay, debugFeaturesEnabled: true
        )
        let overlayIDs = overlay.map(\.id)
        #expect(overlay.contains(where: { $0.id == .search }))
        #expect(!overlay.contains(where: { $0.id == .zoomOut }))
        #expect(overlayControlBarResponsiveLayout(width: 800, items: overlay)
            == OverlayControlBarResponsiveLayout(visibleItemIDs: overlayIDs, overflowItemIDs: []))
        var previousVisibleCount = 0
        for width in stride(from: CGFloat(200), through: 650, by: 1) {
            let layout = overlayControlBarResponsiveLayout(width: width, items: overlay)
            #expect(layout.visibleItemIDs + layout.overflowItemIDs == overlayIDs)
            #expect(layout.visibleItemIDs.count >= previousVisibleCount)
            #expect(layout.showsOverflow == !layout.overflowItemIDs.isEmpty)
            previousVisibleCount = layout.visibleItemIDs.count
        }
        let releaseOverlay = OverlayControlBarCatalog.availableItems(
            displayMode: .overlay, debugFeaturesEnabled: false
        )
        #expect(overlayControlBarResponsiveLayout(width: 800, items: releaseOverlay)
            == OverlayControlBarResponsiveLayout(
                visibleItemIDs: releaseOverlay.map(\.id), overflowItemIDs: []
            ))
        let mirror = OverlayControlBarCatalog.availableItems(
            displayMode: .mirror, debugFeaturesEnabled: true
        )
        let mirrorIDs = mirror.map(\.id)
        #expect(mirrorIDs.contains(.zoomOut))
        #expect(mirrorIDs.contains(.followSelectionSize))
        let mirrorLayoutWithoutReservedSpacer = overlayControlBarResponsiveLayout(
            width: 800, items: mirror, includesChrome: false
        )
        let mirrorLayoutWithReservedSpacer = overlayControlBarResponsiveLayout(
            width: 800,
            items: mirror,
            includesChrome: false,
            minimumSpacerWidth: OverlayControlBarMetrics.mirrorDragSpacerWidth
        )
        #expect(
            mirrorLayoutWithReservedSpacer.visibleItemIDs.count
                < mirrorLayoutWithoutReservedSpacer.visibleItemIDs.count
        )
        #expect(
            mirrorLayoutWithReservedSpacer.visibleItemIDs
                + mirrorLayoutWithReservedSpacer.overflowItemIDs == mirrorIDs
        )
        #expect(overlayControlBarResponsiveLayout(width: 1, items: mirror, includesChrome: false)
            .overflowItemIDs == mirrorIDs)
        #expect(overlayControlBarHoverAlpha(isEnabled: true, pointerInside: false, mouseDown: false) == nil)
        #expect(overlayControlBarHoverAlpha(isEnabled: true, pointerInside: true, mouseDown: false) == 0.16)
        #expect(overlayControlBarHoverAlpha(isEnabled: true, pointerInside: true, mouseDown: true) == 0.24)
        #expect(overlayControlBarHoverAlpha(isEnabled: false, pointerInside: true, mouseDown: true) == nil)
        #expect(!overlayControlBarIsEmphasized(pointerInside: false, dragging: false))
        #expect(overlayControlBarIsEmphasized(pointerInside: true, dragging: false))
        #expect(overlayControlBarIsEmphasized(pointerInside: false, dragging: true))
    }

    @Test func capturePolicyAndFeatureSettingsRoundTrip() {
        withTestDefaults { defaults in
            #expect(TargetApplicationTracking.load(from: defaults) == AppDefaults.targetApplicationTracking)
            TargetApplicationTracking.save(false, to: defaults)
            #expect(!TargetApplicationTracking.load(from: defaults))
            #expect(MirrorAlwaysOnTop.load(from: defaults) == AppDefaults.mirrorAlwaysOnTop)
            MirrorAlwaysOnTop.save(false, to: defaults)
            #expect(!MirrorAlwaysOnTop.load(from: defaults))
            MirrorAlwaysOnTop.save(true, to: defaults)
            #expect(MirrorAlwaysOnTop.load(from: defaults))
            #expect(SelectionHotKey.load(from: defaults) == AppDefaults.selectionHotKey)
            let selection = SelectionHotKey(keyCode: 18, modifiers: UInt32(cmdKey), keyLabel: "1")
            selection.save(to: defaults)
            #expect(SelectionHotKey.load(from: defaults) == selection)
            #expect(selection.title == "⌘1")
            #expect(DebugFeatures.load(from: defaults) == AppDefaults.debugFeaturesEnabled)
            DebugFeatures.save(true, to: defaults)
#if LST_EXCLUDE_DEBUG_FEATURES
            #expect(!DebugFeatures.load(from: defaults))
#else
            #expect(DebugFeatures.load(from: defaults))
#endif
            #expect(MirrorFollowsSelectionSize.load(from: defaults) == AppDefaults.mirrorFollowsSelectionSize)
            MirrorFollowsSelectionSize.save(false, to: defaults)
            #expect(!MirrorFollowsSelectionSize.load(from: defaults))

            #expect(CapturePolicy().targetFPS == AppDefaults.captureTargetFPS)
            #expect(CapturePolicy().realtimeOCRInterval
                == .milliseconds(AppDefaults.realtimeOCRIntervalMilliseconds))
            let low = CapturePolicy(targetFPS: 0, realtimeOCRIntervalMilliseconds: 99)
            #expect(low.targetFPS == 1)
            #expect(low.realtimeOCRIntervalMilliseconds == 100)
            let high = CapturePolicy(targetFPS: 31, realtimeOCRIntervalMilliseconds: 2_001)
            #expect(high.targetFPS == 30)
            #expect(high.realtimeOCRIntervalMilliseconds == 2_000)
            let saved = CapturePolicy(targetFPS: 7, realtimeOCRIntervalMilliseconds: 850)
            saved.save(to: defaults)
            #expect(CapturePolicy.load(from: defaults) == saved)
        }
    }
}
