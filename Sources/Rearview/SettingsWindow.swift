import AppKit
import Carbon

private final class SettingsDocumentView: NSView {
    override var isFlipped: Bool { true }
}

private final class SettingsRootView: NSView {
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: SettingsLayoutMetrics.minimumContentHeight)
    }
}

private final class SettingsSidebarButton: NSButton {
    var isCategorySelected = false {
        didSet { needsDisplay = true; needsLayout = true }
    }

    override func updateLayer() {
        super.updateLayer()
        layer?.cornerRadius = 7
        layer?.backgroundColor = isCategorySelected
            ? NSColor.controlAccentColor.withAlphaComponent(0.16).cgColor
            : NSColor.clear.cgColor
        contentTintColor = isCategorySelected ? .controlAccentColor : .labelColor
    }
}

// Settings rows use a stable two-column contract. The label column is the
// only flexible part; controls must fit inside the fixed trailing column.
enum SettingsLayoutMetrics {
    static let sidebarWidth: CGFloat = 200
    static let sidebarDividerWidth: CGFloat = 1
    static let minimumWindowSize = CGSize(width: 900, height: 600)
    static let initialWindowSize = CGSize(width: 980, height: 720)
    static let minimumContentHeight: CGFloat = 568
    static let contentHorizontalInset: CGFloat = 24
    static let cardHorizontalInset: CGFloat = 16
    static let rowControlGap: CGFloat = 20
    static let trailingControlColumnWidth: CGFloat = 220
    static let rowVerticalInset: CGFloat = 12
    static let compoundRowVerticalInset: CGFloat = 16
    static let compoundControlSpacing: CGFloat = 8

    static var minimumLabelColumnWidth: CGFloat {
        minimumWindowSize.width
            - sidebarWidth
            - sidebarDividerWidth
            - (contentHorizontalInset * 2)
            - (cardHorizontalInset * 2)
            - rowControlGap
            - trailingControlColumnWidth
    }
}

@MainActor
private final class SettingsWindow: NSWindow {
    var onCancel: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    private struct SettingsPage {
        let identifier: String
        let title: String
        let documentView: SettingsDocumentView
    }
    var onSettingsReset: (() -> Void)?
    var onDebugFeaturesChange: ((Bool) -> Void)?
    var onMirrorBackgroundOpacityChange: ((CGFloat) -> Void)?
    var onDisplayModeChange: ((TranslationDisplayMode) -> Void)?
    var onDisplayLanguageChange: ((AppDisplayLanguage) -> Void)?
    var onTranslationDirectionChange: ((TranslationDirection) -> Void)?
    var onNonSourceTextProtectionChange: ((Bool) -> Void)?
    var onOverlayOpacityChange: ((CGFloat) -> Void)?
    var onActiveOverlayOpacityChange: ((CGFloat) -> Void)?
    var onOverlayControlBarOpacityChange: ((CGFloat) -> Void)?
    var onActiveOverlayControlBarOpacityChange: ((CGFloat) -> Void)?
    var onOverlayMouseEventIgnoringChange: ((Bool) -> Void)?
    var onRegionBorderOpacityChange: ((CGFloat) -> Void)?
    var onMirrorAlwaysOnTopChange: ((Bool) -> Void)?
    var onMirrorFollowSelectionSizeChange: ((Bool) -> Void)?
    var onTargetApplicationTrackingChange: ((Bool) -> Void)?
    var onLaunchAtLoginChange: ((Bool) -> Bool)?
    var onMirrorUpdateStyleChange: ((MirrorUpdateStyle) -> Void)?
    var onSelectionHotKeyChange: ((SelectionHotKey) -> Bool)?
    var onImmediateTranslationHotKeyChange: ((ImmediateTranslationHotKey) -> Bool)?
    var onMirrorActivationHotKeyChange: ((MirrorActivationHotKey) -> Bool)?
    var onHotKeyRecordingChange: ((Bool) -> Void)?
    var onSelectionHotKeyRemove: (() -> Bool)?
    var onImmediateTranslationHotKeyRemove: (() -> Bool)?
    var onMirrorActivationHotKeyRemove: (() -> Bool)?
    var onToolbarHotKeyChange: ((ToolbarShortcutAction, ToolbarHotKey) -> Bool)?
    var onToolbarHotKeyRemove: ((ToolbarShortcutAction) -> Bool)?
    var onSelectionShortcutChange: ((SelectionShortcutAction, ToolbarHotKey) -> Bool)?
    var onSelectionShortcutRemove: ((SelectionShortcutAction) -> Bool)?
    var onCapturePolicyChange: ((CapturePolicy) -> Void)?
    var onOCRSettingsChange: ((OCRMode, OCRSettings) -> Void)?
    var onRefinementOCRPolicyChange: ((RefinementOCRPolicy) -> Void)?
#if LST_EXCLUDE_DEBUG_FEATURES
    var updateSettingsProvider: (() -> UpdateSettingsSnapshot)?
    var onAutomaticChecksChange: ((Bool) -> Void)?
    var onAutomaticDownloadsChange: ((Bool) -> Void)?
#endif

    private let debugFeatures = NSSwitch()
    private let mirrorBackgroundOpacityField = NSTextField()
    private let mirrorBackgroundOpacityStepper = NSStepper()
    private let displayModeControl = NSSegmentedControl()
    private let displayLanguagePopup = NSPopUpButton()
    private let translationDirectionControl = NSSegmentedControl()
    private let protectNonSourceText = NSSwitch()
    private let overlayOpacityField = NSTextField()
    private let overlayOpacityStepper = NSStepper()
    private let activeOverlayOpacityField = NSTextField()
    private let activeOverlayOpacityStepper = NSStepper()
    private let overlayControlBarOpacityField = NSTextField()
    private let overlayControlBarOpacityStepper = NSStepper()
    private let activeOverlayControlBarOpacityField = NSTextField()
    private let activeOverlayControlBarOpacityStepper = NSStepper()
    private let overlayIgnoresMouseEvents = NSSwitch()
    private let regionBorderOpacityField = NSTextField()
    private let regionBorderOpacityStepper = NSStepper()
    private let mirrorAlwaysOnTop = NSSwitch()
    private let mirrorFollowSize = NSSwitch()
    private let targetApplicationTracking = NSSwitch()
    private let launchAtLogin = NSSwitch()
    private let mirrorUpdateStylePopup = NSPopUpButton()
    private let selectionHotKeyButton = NSButton()
    private let immediateTranslationHotKeyButton = NSButton()
    private let mirrorActivationHotKeyButton = NSButton()
    private let selectionHotKeyRemoveButton = NSButton()
    private let immediateTranslationHotKeyRemoveButton = NSButton()
    private let mirrorActivationHotKeyRemoveButton = NSButton()
    private var hotKeyMonitor: Any?
    private var toolbarHotKeyButtons: [ToolbarShortcutAction: NSButton] = [:]
    private var toolbarHotKeyRemoveButtons: [ToolbarShortcutAction: NSButton] = [:]
    private var selectionShortcutButtons: [SelectionShortcutAction: NSButton] = [:]
    private var selectionShortcutRemoveButtons: [SelectionShortcutAction: NSButton] = [:]
    private let captureFPSField = NSTextField()
    private let captureFPSStepper = NSStepper()
    private let imageSaveDirectoryField = NSTextField(labelWithString: "")
    private let imageSaveDirectoryButton = NSButton()
    private let imageSaveFilenameField = NSTextField()
    private let ocrIntervalField = NSTextField()
    private let ocrIntervalStepper = NSStepper()
    private let ocrFilterConfidenceField = NSTextField()
    private let ocrFilterConfidenceStepper = NSStepper()
    private let ocrHeightFields = [OCRMode.realtime: NSTextField(), .refinement: NSTextField()]
    private let ocrScaleFields = [OCRMode.realtime: NSTextField(), .refinement: NSTextField()]
    private let ocrCorrectionSwitches = [OCRMode.realtime: NSSwitch(), .refinement: NSSwitch()]
    private let ocrAutoLanguageSwitches = [OCRMode.realtime: NSSwitch(), .refinement: NSSwitch()]
    private let refinementDelayField = NSTextField()
    private let refinementDelayStepper = NSStepper()
    private let automaticStrategyPopup = NSPopUpButton()
    private let manualStrategyPopup = NSPopUpButton()
    private let refinementAlwaysRunSwitch = NSSwitch()
    private let refinementConfidenceField = NSTextField()
    private let recognitionLanguagesPopup = NSPopUpButton()
    private let resetButton = NSButton()
#if LST_EXCLUDE_DEBUG_FEATURES
    private let automaticChecks = NSSwitch()
    private let automaticDownloads = NSSwitch()
#endif
    private weak var settingsScrollView: NSScrollView?
    private var activeDocumentWidthConstraint: NSLayoutConstraint?
    private var settingsPages: [SettingsPage] = []
    private var sidebarButtons: [SettingsSidebarButton] = []
    private var preferenceRowLayoutRecords: [
        (title: String, row: NSStackView, controlColumn: NSView, control: NSView)
    ] = []

    init() {
        let window = SettingsWindow(
            contentRect: CGRect(
                origin: .zero,
                size: SettingsLayoutMetrics.initialWindowSize
            ),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
        )
        window.title = L10n.text("Rearview 설정")
        window.isReleasedWhenClosed = false
        window.level = RegionWindowLevel.settings
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.fullScreenAuxiliary]
        window.minSize = SettingsLayoutMetrics.minimumWindowSize
        super.init(window: window)
        window.onCancel = { [weak self] in self?.close() }
        window.delegate = self
        buildContent()
    }

    required init?(coder: NSCoder) { nil }

    func layoutContractViolationsForSelfTest() -> [String] {
        guard !preferenceRowLayoutRecords.isEmpty else {
            return ["settings preference rows were not built"]
        }
        for index in settingsPages.indices {
            showSettingsCategory(at: index)
            window?.contentView?.layoutSubtreeIfNeeded()
            settingsPages[index].documentView.layoutSubtreeIfNeeded()
        }
        showSettingsCategory(at: 0)

        let tolerance: CGFloat = 0.5
        var violations: [String] = []
        if settingsPages.count != sidebarButtons.count || settingsPages.isEmpty {
            violations.append("settings sidebar/page count mismatch")
        }
        for record in preferenceRowLayoutRecords {
            record.row.layoutSubtreeIfNeeded()
            let controlColumnFrame = record.row.convert(
                record.controlColumn.bounds, from: record.controlColumn
            )
            let controlFrame = record.row.convert(record.control.bounds, from: record.control)

            if abs(controlColumnFrame.maxX - record.row.bounds.maxX) > tolerance {
                violations.append(
                    "\(record.title): control column is not trailing-aligned "
                        + "(row: \(record.row.bounds), column: \(controlColumnFrame))"
                )
            }
            if controlFrame.minY < record.row.bounds.minY - tolerance
                || controlFrame.maxY > record.row.bounds.maxY + tolerance {
                violations.append(
                    "\(record.title): control overflows its preference row "
                        + "(row: \(record.row.bounds), control: \(controlFrame))"
                )
            }
        }
        return violations
    }

    func refresh() {
        debugFeatures.state = DebugFeatures.load() ? .on : .off
        mirrorAlwaysOnTop.state = MirrorAlwaysOnTop.load() ? .on : .off
        mirrorBackgroundOpacityField.integerValue = Int((MirrorBackgroundOpacity.load() * 100).rounded())
        mirrorBackgroundOpacityStepper.integerValue = mirrorBackgroundOpacityField.integerValue
        displayModeControl.selectedSegment = TranslationDisplayMode.load() == .mirror ? 0 : 1
        displayLanguagePopup.selectItem(
            at: AppDisplayLanguage.allCases.firstIndex(of: .load()) ?? 0
        )
        translationDirectionControl.selectedSegment = TranslationDirection.load() == .japaneseToKorean ? 0 : 1
        protectNonSourceText.state = TranslationTextProtection.load() ? .on : .off
        overlayOpacityField.integerValue = Int((OverlayOpacity.load() * 100).rounded())
        overlayOpacityStepper.integerValue = overlayOpacityField.integerValue
        activeOverlayOpacityField.integerValue = Int((OverlayActiveOpacity.load() * 100).rounded())
        activeOverlayOpacityStepper.integerValue = activeOverlayOpacityField.integerValue
        overlayControlBarOpacityField.integerValue = Int((OverlayControlBarOpacity.load() * 100).rounded())
        overlayControlBarOpacityStepper.integerValue = overlayControlBarOpacityField.integerValue
        activeOverlayControlBarOpacityField.integerValue = Int((OverlayControlBarActiveOpacity.load() * 100).rounded())
        activeOverlayControlBarOpacityStepper.integerValue = activeOverlayControlBarOpacityField.integerValue
        overlayIgnoresMouseEvents.state = OverlayIgnoresMouseEvents.load() ? .on : .off
        regionBorderOpacityField.integerValue = Int((RegionBorderOpacity.load() * 100).rounded())
        regionBorderOpacityStepper.integerValue = regionBorderOpacityField.integerValue
        mirrorFollowSize.state = MirrorFollowsSelectionSize.load() ? .on : .off
        targetApplicationTracking.state = TargetApplicationTracking.load() ? .on : .off
        launchAtLogin.state = LaunchAtLogin.load() ? .on : .off
        mirrorUpdateStylePopup.selectItem(
            at: MirrorUpdateStyle.allCases.firstIndex(of: .load()) ?? 0
        )
        selectionHotKeyButton.title = SelectionHotKey.load().title
        immediateTranslationHotKeyButton.title = ImmediateTranslationHotKey.load().title
        mirrorActivationHotKeyButton.title = MirrorActivationHotKey.load().title
        selectionHotKeyRemoveButton.isEnabled = SelectionHotKey.load().isEnabled
        immediateTranslationHotKeyRemoveButton.isEnabled = ImmediateTranslationHotKey.load().isEnabled
        mirrorActivationHotKeyRemoveButton.isEnabled = MirrorActivationHotKey.load().isEnabled
        for action in ToolbarShortcutAction.configurableActions {
            toolbarHotKeyButtons[action]?.title = ToolbarHotKey.load(action: action).settingsTitle
            toolbarHotKeyRemoveButtons[action]?.isEnabled = ToolbarHotKey.load(action: action).isEnabled
        }
        for action in SelectionShortcutAction.allCases {
            selectionShortcutButtons[action]?.title = ToolbarHotKey.load(selectionAction: action).settingsTitle
            selectionShortcutRemoveButtons[action]?.isEnabled = ToolbarHotKey.load(selectionAction: action).isEnabled
        }
        imageSaveDirectoryField.stringValue = ImageSaveSettings.directoryURL().path
        imageSaveFilenameField.stringValue = ImageSaveSettings.filenameTemplate()
        let policy = CapturePolicy.load()
        captureFPSField.integerValue = policy.targetFPS
        captureFPSStepper.integerValue = policy.targetFPS
        ocrIntervalField.integerValue = policy.realtimeOCRIntervalMilliseconds
        ocrIntervalStepper.integerValue = policy.realtimeOCRIntervalMilliseconds
        ocrFilterConfidenceField.stringValue = String(format: "%.2f", OCRRecognitionPolicy.minimumConfidence)
        ocrFilterConfidenceStepper.doubleValue = Double(OCRRecognitionPolicy.minimumConfidence)
        let refinementPolicy = RefinementOCRPolicy.load()
        automaticStrategyPopup.selectItem(withTitle: refinementPolicy.automaticStrategy.title)
        manualStrategyPopup.selectItem(withTitle: refinementPolicy.manualStrategy.title)
        refinementAlwaysRunSwitch.state = refinementPolicy.alwaysRun ? .on : .off
        refinementConfidenceField.stringValue = String(format: "%.2f", refinementPolicy.confidenceThreshold)
        refinementDelayField.integerValue = refinementPolicy.delayMilliseconds
        refinementDelayStepper.integerValue = refinementPolicy.delayMilliseconds
        for mode in [OCRMode.realtime, .refinement] {
            let settings = OCRSettings.load(mode: mode)
            ocrHeightFields[mode]?.stringValue = String(format: "%.3f", settings.minimumTextHeight)
            ocrScaleFields[mode]?.stringValue = String(format: "%.1f", settings.imageScale)
            ocrCorrectionSwitches[mode]?.state = settings.usesLanguageCorrection ? .on : .off
            ocrAutoLanguageSwitches[mode]?.state = settings.automaticallyDetectsLanguage ? .on : .off
        }
        recognitionLanguagesPopup.selectItem(withTitle: OCRRecognitionLanguageChoice.load().title)
#if LST_EXCLUDE_DEBUG_FEATURES
        if let updateSettings = updateSettingsProvider?() {
            automaticChecks.state = updateSettings.automaticallyChecksForUpdates ? .on : .off
            automaticDownloads.state = updateSettings.automaticallyDownloadsUpdates ? .on : .off
            automaticDownloads.isEnabled = updateSettings.allowsAutomaticUpdates
        } else {
            automaticChecks.state = .on
            automaticDownloads.state = .off
            automaticDownloads.isEnabled = false
        }
#endif
    }

    private func buildContent() {
        configureControls()
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        settingsScrollView = scrollView

        let globalShortcutSection = makeSection(title: L10n.text("전역 단축키"), rows: [
            makePreferenceRow(
                title: L10n.text("영역 선택"),
                description: L10n.text("새 번역 영역을 선택합니다."),
                control: makeHotKeyControl(selectionHotKeyButton, remove: selectionHotKeyRemoveButton)
            ),
            makePreferenceRow(
                title: L10n.text("즉시 번역"),
                description: L10n.text("현재 영역을 즉시 캡처하고 번역합니다."),
                control: makeHotKeyControl(immediateTranslationHotKeyButton, remove: immediateTranslationHotKeyRemoveButton)
            ),
            makePreferenceRow(
                title: L10n.text("번역 표시 활성화"),
                description: L10n.text("현재 번역 표시를 활성화하고 조작 대상으로 만듭니다."),
                control: makeHotKeyControl(mirrorActivationHotKeyButton, remove: mirrorActivationHotKeyRemoveButton)
            ),
        ])
        let generalShortcutSection = makeSection(title: L10n.text("일반"), rows:
            makeToolbarShortcutRows(for: [.openSettings, .stopTranslation])
        )
        let sessionControlShortcutSection = makeSection(title: L10n.text("번역 세션 제어"), rows:
            makeToolbarShortcutRows(for: [
                .applicationCapture, .displayMode, .translationDirection,
                .refreshMode, .modeSpecificDisplayControl, .sessionControlSingleKey,
            ])
        )
        let textSelectionShortcutSection = makeSection(title: L10n.text("텍스트 및 선택"), rows:
            makeToolbarShortcutRows(for: [
                .selectAll, .copySelection, .copyAndClearSelection,
                .copyAll, .copyImage, .saveImage, .search, .selectionMode,
            ])
        )
        let mirrorSizeShortcutSection = makeSection(title: L10n.text("미러 크기"), rows:
            makeToolbarShortcutRows(for: [
                .zoomOut, .zoomActual, .zoomIn, .fitWindowToContent, .followSelectionSize,
                .dockTop, .dockBottom, .dockLeft, .dockRight,
            ])
        )
        let selectionShortcutSection = makeSection(
            title: L10n.text("영역 선택"),
            rows: makeSelectionShortcutRows()
        )
        var shortcutSections = [
            globalShortcutSection,
            generalShortcutSection,
            sessionControlShortcutSection,
            textSelectionShortcutSection,
            mirrorSizeShortcutSection,
            selectionShortcutSection,
        ]
        if ToolbarShortcutAction.configurableActions.contains(.debugOverlay) {
            shortcutSections.append(makeSection(title: L10n.text("개발자 도구"), rows:
                makeToolbarShortcutRows(for: [.debugOverlay])
            ))
        }

        let startupSection = makeSection(title: L10n.text("시작 및 실행"), rows: [
            makePreferenceRow(
                title: L10n.text("macOS 시작 시 자동 실행"),
                description: L10n.text("사용자 로그인 후 Rearview를 자동으로 실행합니다."),
                control: launchAtLogin
            ),
        ])
        let languageAndTranslationSection = makeSection(title: L10n.text("언어 및 번역"), rows: [
            makePreferenceRow(
                title: L10n.text("표시 언어"),
                description: L10n.text("앱의 메뉴, 설정 및 번역 UI에 사용할 언어를 선택합니다."),
                control: displayLanguagePopup
            ),
            makePreferenceRow(
                title: L10n.text("번역 방향"),
                description: L10n.text("화면에서 번역할 소스 언어와 결과 언어를 선택합니다."),
                control: translationDirectionControl
            ),
            makePreferenceRow(
                title: L10n.text("원문 외 텍스트 보호"),
                description: L10n.text("활성화하면 원문 언어 이외의 텍스트(영어·반대 언어·숫자)를 번역 대상에서 제외하고 원문 그대로 유지합니다. 번역은 분리된 텍스트 단위로 처리되므로 전체 문맥이 나뉠 수 있습니다. 비활성화하면 혼합된 텍스트 전체를 하나의 번역 단위로 처리해 문맥을 반영할 수 있지만, 영어·반대 언어·숫자도 번역되거나 변경될 수 있습니다."),
                control: protectNonSourceText,
                verticalInset: SettingsLayoutMetrics.compoundRowVerticalInset
            ),
        ])
#if LST_EXCLUDE_DEBUG_FEATURES
        let updateSettingsSection = makeSection(title: L10n.text("업데이트"), rows: [
            makePreferenceRow(
                title: L10n.text("업데이트 자동 확인"),
                description: L10n.text("새 업데이트를 백그라운드에서 자동으로 확인합니다. 확인 주기는 하루에 한 번입니다."),
                control: automaticChecks
            ),
            makePreferenceRow(
                title: L10n.text("업데이트 자동 다운로드 및 설치"),
                description: L10n.text("업데이트를 백그라운드에서 다운로드하고 다음 앱 종료 시 설치합니다."),
                control: automaticDownloads,
                verticalInset: SettingsLayoutMetrics.compoundRowVerticalInset
            ),
        ])
#endif
        let settingsManagementSection = makeSection(title: L10n.text("설정 관리"), rows: [
            makePreferenceRow(
                title: L10n.text("모든 설정 초기화"),
                description: L10n.text("단축키, 표시 방식, 캡처, OCR 및 업데이트 설정을 기본값으로 되돌립니다. macOS 시스템 권한은 변경하지 않습니다."),
                control: resetButton
            ),
        ])

        let displayModeSection = makeSection(title: L10n.text("표시 방식"), rows: [
            makePreferenceRow(
                title: L10n.text("번역 표시 모드"),
                description: L10n.text("별도 미러창 또는 선택 영역 위 오버레이에 번역 결과를 표시합니다."),
                control: displayModeControl
            ),
        ])
        let mirrorDisplaySection = makeSection(title: L10n.text("미러 창"), rows: [
            makePreferenceRow(title: L10n.text("항상 위"), description: L10n.text("미러창을 다른 창 위에 유지합니다. 설정값은 미러 모드에 적용됩니다."), control: mirrorAlwaysOnTop),
            makePreferenceRow(title: L10n.text("번역 배경 불투명도"), description: L10n.text("번역 배경의 불투명도를 조절합니다. 설정값은 미러 모드에 적용됩니다."), control: makeNumberControl(field: mirrorBackgroundOpacityField, stepper: mirrorBackgroundOpacityStepper, unit: "%")),
            makePreferenceRow(title: L10n.text("선택 영역 크기 연동"), description: L10n.text("영역 크기가 바뀌면 현재 확대 비율을 유지하여 미러창 크기를 맞춥니다. 설정값은 미러 모드에 적용됩니다."), control: mirrorFollowSize),
        ])
        let overlayDisplaySection = makeSection(title: L10n.text("오버레이"), rows: [
            makePreferenceRow(title: L10n.text("비활성 번역 표시 영역 불투명도"), description: L10n.text("Rearview가 비활성 상태일 때 캡처 이미지와 번역 결과가 표시되는 영역 전체의 불투명도입니다."), control: makeNumberControl(field: overlayOpacityField, stepper: overlayOpacityStepper, unit: "%")),
            makePreferenceRow(title: L10n.text("활성 번역 표시 영역 불투명도"), description: L10n.text("Rearview가 활성 상태일 때 캡처 이미지와 번역 결과가 표시되는 영역 전체의 불투명도입니다."), control: makeNumberControl(field: activeOverlayOpacityField, stepper: activeOverlayOpacityStepper, unit: "%")),
            makePreferenceRow(title: L10n.text("비활성 컨트롤 바 불투명도"), description: L10n.text("Rearview가 비활성이고 마우스가 컨트롤 바 밖에 있을 때의 불투명도입니다."), control: makeNumberControl(field: overlayControlBarOpacityField, stepper: overlayControlBarOpacityStepper, unit: "%")),
            makePreferenceRow(title: L10n.text("활성 컨트롤 바 불투명도"), description: L10n.text("Rearview가 활성 상태이거나 비활성 컨트롤 바에 마우스를 올렸을 때의 불투명도입니다."), control: makeNumberControl(field: activeOverlayControlBarOpacityField, stepper: activeOverlayControlBarOpacityStepper, unit: "%")),
            makePreferenceRow(title: L10n.text("선택 영역 마우스 이벤트 무시"), description: L10n.text("마우스 입력을 가로채지 않고 아래 앱으로 전달합니다. 설정값은 오버레이 모드에 적용됩니다."), control: overlayIgnoresMouseEvents),
        ])
        let selectionDisplaySection = makeSection(title: L10n.text("선택 영역"), rows: [
            makePreferenceRow(title: L10n.text("영역 테두리 불투명도"), description: L10n.text("선택 영역 테두리와 이동 탭의 투명도를 조절합니다."), control: makeNumberControl(field: regionBorderOpacityField, stepper: regionBorderOpacityStepper, unit: "%")),
        ])

        let captureSection = makeSection(title: L10n.text("캡처"), rows: [
            makePreferenceRow(title: L10n.text("화면 캡처 속도"), description: L10n.text("화면 변화를 확인할 초당 프레임 수입니다. 설정 범위는 1–30fps입니다."), control: makeNumberControl(field: captureFPSField, stepper: captureFPSStepper, unit: "fps")),
            makePreferenceRow(title: L10n.text("타겟 앱 이동 추적"), description: L10n.text("캡처 대상 앱 창이 이동하면 번역 영역도 함께 이동합니다."), control: targetApplicationTracking),
            makePreferenceRow(title: L10n.text("이미지 저장 폴더"), description: L10n.text("이미지 저장 시 사용할 폴더입니다."), control: makeImageSaveDirectoryControl()),
            makePreferenceRow(title: L10n.text("이미지 파일명 규칙"), description: L10n.text("{yyyy}, {MM}, {dd}, {HH}, {mm}, {ss}, {counter} 토큰을 사용할 수 있습니다."), control: imageSaveFilenameField),
        ])
        let updateSection = makeSection(title: L10n.text("갱신"), rows: [
            makePreferenceRow(title: L10n.text("OCR 최소 간격"), description: L10n.text("화면이 변해도 이 시간이 지난 뒤 다음 OCR을 시작합니다. 설정 범위는 100–2000ms입니다."), control: makeNumberControl(field: ocrIntervalField, stepper: ocrIntervalStepper, unit: "ms")),
            makePreferenceRow(title: L10n.text("미러 갱신 방식"), description: L10n.text("번역을 한 번에 표시하거나, 완료되는 줄부터 점진적으로 표시합니다."), control: mirrorUpdateStylePopup),
        ])
        let ocrExecutionSection = makeSection(title: L10n.text("OCR 실행 방식"), rows: [
            makePreferenceRow(title: L10n.text("자동 모드"), description: L10n.text("자동 갱신에서 사용할 OCR 실행 흐름을 선택합니다."), control: automaticStrategyPopup),
            makePreferenceRow(title: L10n.text("수동 모드"), description: L10n.text("수동 실행에서 사용할 OCR 실행 흐름을 선택합니다."), control: manualStrategyPopup),
        ])
        let refinementConditionSection = makeSection(title: L10n.text("Refinement 실행 조건"), rows: [
            makePreferenceRow(title: L10n.text("항상 실행"), description: L10n.text("일본어 줄의 신뢰도와 관계없이 보정 OCR을 실행합니다."), control: refinementAlwaysRunSwitch),
            makePreferenceRow(title: L10n.text("일본어 줄 신뢰도 <"), description: L10n.text("일본어 줄이 이 값보다 낮은 경우 보정 OCR을 실행합니다."), control: refinementConfidenceField),
            makePreferenceRow(title: L10n.text("대기 시간"), description: L10n.text("화면 움직임이 멈춘 뒤 보정 OCR을 시작하기 전 대기 시간입니다."), control: makeNumberControl(field: refinementDelayField, stepper: refinementDelayStepper, unit: "ms")),
        ])
        let languageSection = makeSection(title: L10n.text("OCR 언어 및 필터"), rows: [
            makePreferenceRow(title: L10n.text("인식 언어"), description: L10n.text("Vision OCR에 전달할 지원 언어 순서를 선택합니다."), control: recognitionLanguagesPopup),
            makePreferenceRow(title: L10n.text("저신뢰도 라인 필터"), description: L10n.text("일본어가 포함되지 않은 OCR 라인을 버릴 최소 confidence입니다. 0.00–1.00 범위이며 일본어 라인은 보호됩니다."), control: makeDecimalControl(field: ocrFilterConfidenceField, stepper: ocrFilterConfidenceStepper)),
        ])
        let advancedOCRSection = makeSection(title: L10n.text("고급 OCR"), rows: makeAdvancedOCRRows())

        var generalSections: [NSView] = [startupSection, languageAndTranslationSection]
#if LST_EXCLUDE_DEBUG_FEATURES
        generalSections.append(updateSettingsSection)
#endif
        generalSections.append(settingsManagementSection)

        var definitions: [(String, String, String, [NSView])] = [
            ("general", L10n.text("일반"), "gearshape", generalSections),
            ("shortcuts", L10n.text("단축키"), "keyboard", shortcutSections),
            ("display", L10n.text("화면 표시"), "rectangle.on.rectangle", [displayModeSection, mirrorDisplaySection, overlayDisplaySection, selectionDisplaySection]),
            ("captureOCR", L10n.text("캡처 및 OCR"), "viewfinder", [captureSection, updateSection, ocrExecutionSection, refinementConditionSection, languageSection, advancedOCRSection]),
        ]
#if !LST_EXCLUDE_DEBUG_FEATURES
        definitions.append((
            "developer", L10n.text("개발자"), "hammer",
            [makeSection(title: L10n.text("진단 기능"), rows: [
                makePreferenceRow(
                    title: L10n.text("디버그 기능"),
                    description: L10n.text("프로파일링·벤치마크 메뉴와 OCR Debug Overlay 버튼을 표시합니다."),
                    control: debugFeatures
                ),
            ])]
        ))
#endif
        settingsPages = definitions.map { definition in
            makeSettingsPage(
                identifier: definition.0, title: definition.1,
                sections: definition.3, scrollView: scrollView
            )
        }

        let sidebar = NSView()
        sidebar.wantsLayer = true
        sidebar.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        let sidebarTitle = NSTextField(labelWithString: L10n.text("설정"))
        sidebarTitle.font = .systemFont(ofSize: 12, weight: .semibold)
        sidebarTitle.textColor = .secondaryLabelColor
        let sidebarStack = NSStackView()
        sidebarStack.orientation = .vertical
        sidebarStack.alignment = .leading
        sidebarStack.spacing = 4
        sidebarStack.translatesAutoresizingMaskIntoConstraints = false
        sidebarStack.addArrangedSubview(sidebarTitle)
        sidebarStack.setCustomSpacing(10, after: sidebarTitle)
        sidebarButtons = definitions.enumerated().map { index, definition in
            let button = SettingsSidebarButton(
                title: definition.1, target: self,
                action: #selector(settingsCategoryChanged(_:))
            )
            button.tag = index
            button.image = NSImage(
                systemSymbolName: definition.2,
                accessibilityDescription: definition.1
            )
            button.imagePosition = .imageLeading
            button.alignment = .left
            button.font = .systemFont(ofSize: 13, weight: .medium)
            button.bezelStyle = .regularSquare
            button.isBordered = false
            button.focusRingType = .none
            button.wantsLayer = true
            button.heightAnchor.constraint(equalToConstant: 36).isActive = true
            sidebarStack.addArrangedSubview(button)
            button.widthAnchor.constraint(equalTo: sidebarStack.widthAnchor).isActive = true
            return button
        }
        sidebar.addSubview(sidebarStack)

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        let rootView = SettingsRootView(
            frame: CGRect(origin: .zero, size: SettingsLayoutMetrics.initialWindowSize)
        )
        rootView.autoresizingMask = [.width, .height]
        rootView.addSubview(sidebar)
        rootView.addSubview(divider)
        rootView.addSubview(scrollView)
        window?.contentView = rootView
        window?.setContentSize(SettingsLayoutMetrics.initialWindowSize)
        window?.contentMinSize = CGSize(
            width: SettingsLayoutMetrics.minimumWindowSize.width,
            height: SettingsLayoutMetrics.minimumContentHeight
        )
        rootView.frame = CGRect(origin: .zero, size: SettingsLayoutMetrics.initialWindowSize)
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: rootView.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: SettingsLayoutMetrics.sidebarWidth),
            sidebarStack.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 12),
            sidebarStack.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -12),
            sidebarStack.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 18),
            divider.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            divider.topAnchor.constraint(equalTo: rootView.topAnchor),
            divider.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: SettingsLayoutMetrics.sidebarDividerWidth),
            scrollView.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: rootView.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: SettingsLayoutMetrics.minimumContentHeight),
        ])
        showSettingsCategory(at: 0)
        refresh()
    }

    private func makeSettingsPage(
        identifier: String, title: String, sections: [NSView], scrollView: NSScrollView
    ) -> SettingsPage {
        let pageTitle = NSTextField(labelWithString: title)
        pageTitle.font = .systemFont(ofSize: 22, weight: .bold)
        let contentStack = NSStackView(views: [pageTitle] + sections)
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 24
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.setCustomSpacing(18, after: pageTitle)

        let documentView = SettingsDocumentView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: SettingsLayoutMetrics.contentHorizontalInset),
            contentStack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -SettingsLayoutMetrics.contentHorizontalInset),
            contentStack.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 26),
            contentStack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -28),
        ] + sections.map { $0.widthAnchor.constraint(equalTo: contentStack.widthAnchor) })
        return SettingsPage(identifier: identifier, title: title, documentView: documentView)
    }

    @objc private func settingsCategoryChanged(_ sender: NSButton) {
        showSettingsCategory(at: sender.tag)
    }

    private func showSettingsCategory(at index: Int) {
        guard settingsPages.indices.contains(index), let scrollView = settingsScrollView else { return }
        activeDocumentWidthConstraint?.isActive = false
        scrollView.documentView = settingsPages[index].documentView
        let widthConstraint = settingsPages[index].documentView.widthAnchor.constraint(
            equalTo: scrollView.contentView.widthAnchor
        )
        widthConstraint.isActive = true
        activeDocumentWidthConstraint = widthConstraint
        sidebarButtons.enumerated().forEach { buttonIndex, button in
            button.isCategorySelected = buttonIndex == index
        }
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func configureControls() {
        selectionHotKeyButton.bezelStyle = .rounded
        selectionHotKeyButton.target = self
        selectionHotKeyButton.action = #selector(recordSelectionHotKey)
        selectionHotKeyButton.toolTip = L10n.text("누른 뒤 새 키 조합을 입력합니다. Esc를 누르면 취소합니다.")
        immediateTranslationHotKeyButton.bezelStyle = .rounded
        immediateTranslationHotKeyButton.target = self
        immediateTranslationHotKeyButton.action = #selector(recordImmediateTranslationHotKey)
        immediateTranslationHotKeyButton.toolTip = selectionHotKeyButton.toolTip
        mirrorActivationHotKeyButton.bezelStyle = .rounded
        mirrorActivationHotKeyButton.target = self
        mirrorActivationHotKeyButton.action = #selector(recordMirrorActivationHotKey)
        configureHotKeyRemoveButton(selectionHotKeyRemoveButton)
        configureHotKeyRemoveButton(immediateTranslationHotKeyRemoveButton)
        configureHotKeyRemoveButton(mirrorActivationHotKeyRemoveButton)
        selectionHotKeyRemoveButton.target = self; selectionHotKeyRemoveButton.action = #selector(removeSelectionHotKey)
        immediateTranslationHotKeyRemoveButton.target = self; immediateTranslationHotKeyRemoveButton.action = #selector(removeImmediateTranslationHotKey)
        mirrorActivationHotKeyRemoveButton.target = self; mirrorActivationHotKeyRemoveButton.action = #selector(removeMirrorActivationHotKey)
        resetButton.title = L10n.text("기본값으로 초기화…")
        resetButton.bezelStyle = .rounded
        resetButton.target = self
        resetButton.action = #selector(resetSettings)
#if LST_EXCLUDE_DEBUG_FEATURES
        automaticChecks.target = self
        automaticChecks.action = #selector(automaticChecksChanged)
        automaticDownloads.target = self
        automaticDownloads.action = #selector(automaticDownloadsChanged)
#endif

        imageSaveDirectoryField.font = .systemFont(ofSize: 12)
        imageSaveDirectoryField.lineBreakMode = .byTruncatingMiddle
        imageSaveDirectoryField.isEditable = false
        imageSaveDirectoryField.isSelectable = true
        imageSaveDirectoryButton.title = L10n.text("선택…")
        imageSaveDirectoryButton.bezelStyle = .rounded
        imageSaveDirectoryButton.target = self
        imageSaveDirectoryButton.action = #selector(selectImageSaveDirectory)
        imageSaveFilenameField.delegate = self
        imageSaveFilenameField.placeholderString = AppDefaults.imageSaveFilenameTemplate


        displayModeControl.segmentCount = 2
        displayModeControl.setLabel(L10n.text("미러"), forSegment: 0)
        displayModeControl.setLabel(L10n.text("오버레이"), forSegment: 1)
        displayModeControl.trackingMode = .selectOne
        displayModeControl.target = self
        displayModeControl.action = #selector(displayModeChanged)
        displayModeControl.widthAnchor.constraint(equalToConstant: 180).isActive = true

        translationDirectionControl.segmentCount = 2
        AppDisplayLanguage.allCases.forEach {
            displayLanguagePopup.addItem(withTitle: $0.nativeTitle)
        }
        displayLanguagePopup.target = self
        displayLanguagePopup.action = #selector(displayLanguageChanged)

        translationDirectionControl.setLabel(L10n.text("일→한"), forSegment: 0)
        translationDirectionControl.setLabel(L10n.text("한→일"), forSegment: 1)
        translationDirectionControl.trackingMode = .selectOne
        translationDirectionControl.target = self
        translationDirectionControl.action = #selector(translationDirectionChanged)
        translationDirectionControl.widthAnchor.constraint(equalToConstant: 180).isActive = true
        protectNonSourceText.target = self
        protectNonSourceText.action = #selector(nonSourceTextProtectionChanged)

        MirrorUpdateStyle.allCases.forEach { mirrorUpdateStylePopup.addItem(withTitle: $0.title) }
        mirrorUpdateStylePopup.target = self
        mirrorUpdateStylePopup.action = #selector(mirrorUpdateStyleChanged)

        mirrorFollowSize.target = self
        mirrorFollowSize.action = #selector(mirrorFollowSizeChanged)
        targetApplicationTracking.target = self
        targetApplicationTracking.action = #selector(targetApplicationTrackingChanged)
        launchAtLogin.target = self
        launchAtLogin.action = #selector(launchAtLoginChanged)
        debugFeatures.target = self
        debugFeatures.action = #selector(debugFeaturesChanged)
        mirrorAlwaysOnTop.target = self
        mirrorAlwaysOnTop.action = #selector(mirrorAlwaysOnTopChanged)
        overlayIgnoresMouseEvents.target = self
        overlayIgnoresMouseEvents.action = #selector(overlayIgnoresMouseEventsChanged)
        configureNumberControl(field: mirrorBackgroundOpacityField, stepper: mirrorBackgroundOpacityStepper,
                               range: 0...100, increment: 5, action: #selector(mirrorBackgroundOpacityChanged(_:)))
        configureNumberControl(
            field: overlayOpacityField, stepper: overlayOpacityStepper,
            range: 10...100, increment: 5, action: #selector(overlayOpacityChanged(_:))
        )
        configureNumberControl(
            field: activeOverlayOpacityField, stepper: activeOverlayOpacityStepper,
            range: 10...100, increment: 5, action: #selector(activeOverlayOpacityChanged(_:))
        )
        configureNumberControl(
            field: overlayControlBarOpacityField,
            stepper: overlayControlBarOpacityStepper,
            range: 20...100,
            increment: 5, action: #selector(overlayControlBarOpacityChanged(_:))
        )
        configureNumberControl(
            field: activeOverlayControlBarOpacityField,
            stepper: activeOverlayControlBarOpacityStepper,
            range: 0...100, increment: 5,
            action: #selector(activeOverlayControlBarOpacityChanged(_:))
        )
        configureNumberControl(field: regionBorderOpacityField, stepper: regionBorderOpacityStepper,
                               range: 0...100, increment: 5, action: #selector(regionBorderOpacityChanged(_:)))

        configureNumberControl(
            field: captureFPSField, stepper: captureFPSStepper,
            range: CapturePolicy.targetFPSRange, increment: 1,
            action: #selector(capturePolicyChanged)
        )
        configureNumberControl(
            field: ocrIntervalField, stepper: ocrIntervalStepper,
            range: CapturePolicy.realtimeOCRIntervalMillisecondsRange, increment: 50,
            action: #selector(capturePolicyChanged)
        )
        configureDecimalControl(
            field: ocrFilterConfidenceField, stepper: ocrFilterConfidenceStepper,
            range: OCRRecognitionPolicy.minimumConfidenceRange, increment: 0.05,
            action: #selector(ocrFilterConfidenceChanged(_:))
        )
        for mode in [OCRMode.realtime, .refinement] {
            [ocrHeightFields[mode],
             ocrCorrectionSwitches[mode], ocrAutoLanguageSwitches[mode]].compactMap { $0 }.forEach {
                $0.target = self; $0.action = #selector(ocrDebugSettingChanged(_:))
            }
            ocrHeightFields[mode]?.alignment = .right
            ocrHeightFields[mode]?.delegate = self
            ocrHeightFields[mode]?.widthAnchor.constraint(equalToConstant: 64).isActive = true
            ocrScaleFields[mode]?.target = self; ocrScaleFields[mode]?.action = #selector(ocrDebugSettingChanged(_:))
            ocrScaleFields[mode]?.alignment = .right
            ocrScaleFields[mode]?.delegate = self
            ocrScaleFields[mode]?.placeholderString = L10n.text("배율 1.0–3.0")
            ocrScaleFields[mode]?.toolTip = L10n.text("OCR 입력 이미지 확대 배율 (1.0–3.0배)")
            ocrScaleFields[mode]?.widthAnchor.constraint(equalToConstant: 64).isActive = true
        }
        automaticStrategyPopup.addItems(withTitles: OCRExecutionStrategy.allCases.map(\.title))
        manualStrategyPopup.addItems(withTitles: OCRExecutionStrategy.allCases.map(\.title))
        [automaticStrategyPopup, manualStrategyPopup, refinementAlwaysRunSwitch].forEach { $0.target = self; $0.action = #selector(refinementOCRPolicyChanged(_:)) }
        refinementConfidenceField.target = self
        refinementConfidenceField.action = #selector(refinementOCRPolicyChanged(_:))
        refinementConfidenceField.delegate = self
        refinementConfidenceField.widthAnchor.constraint(equalToConstant: 64).isActive = true
        recognitionLanguagesPopup.addItems(withTitles: OCRRecognitionLanguageChoice.allCases.map(\.title))
        recognitionLanguagesPopup.target = self
        recognitionLanguagesPopup.action = #selector(recognitionLanguagesChanged)
        configureNumberControl(
            field: refinementDelayField, stepper: refinementDelayStepper,
            range: RefinementOCRPolicy.delayMillisecondsRange, increment: 50,
            action: #selector(refinementOCRPolicyChanged(_:))
        )
        refinementDelayField.toolTip = L10n.text("화면 움직임이 멈춘 뒤 refinement OCR을 시작할 때까지의 시간")
    }

    private func makeImageSaveDirectoryControl() -> NSView {
        let stack = NSStackView(views: [imageSaveDirectoryField, imageSaveDirectoryButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        imageSaveDirectoryField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        imageSaveDirectoryField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        imageSaveDirectoryButton.setContentHuggingPriority(.required, for: .horizontal)
        return stack
    }

    private func makeAdvancedOCRRows() -> [NSView] {
        [OCRMode.realtime, .refinement].map { mode in
            makePreferenceRow(title: "\(mode.rawValue) OCR",
                description: mode == .realtime
                    ? L10n.text("Text OCR · Accurate · Current. 실시간 입력 배율과 언어 보정 설정입니다.")
                    : L10n.text("Text OCR · Accurate · Current. 보정 입력 배율과 언어 보정 설정입니다."),
                control: ocrDebugControl(for: mode),
                verticalInset: SettingsLayoutMetrics.compoundRowVerticalInset)
        }
    }

    private func makeToolbarShortcutRows(for actions: [ToolbarShortcutAction]) -> [NSView] {
        let configurableActions = ToolbarShortcutAction.configurableActions
        return actions.map { action in
            let button = NSButton()
            button.bezelStyle = .rounded
            button.target = self
            button.action = #selector(recordToolbarHotKey(_:))
            button.tag = configurableActions.firstIndex(of: action) ?? 0
            let remove = NSButton()
            configureHotKeyRemoveButton(remove)
            remove.target = self
            remove.action = #selector(removeToolbarHotKey(_:))
            remove.tag = button.tag
            toolbarHotKeyButtons[action] = button
            toolbarHotKeyRemoveButtons[action] = remove
            return makePreferenceRow(
                title: action.title,
                description: action.settingsDescription,
                control: makeHotKeyControl(button, remove: remove)
            )
        }
    }

    private func makeSelectionShortcutRows() -> [NSView] {
        let actions = SelectionShortcutAction.allCases
        return actions.map { action in
            let button = NSButton()
            button.bezelStyle = .rounded
            button.target = self
            button.action = #selector(recordSelectionShortcut(_:))
            button.tag = actions.firstIndex(of: action) ?? 0
            let remove = NSButton()
            configureHotKeyRemoveButton(remove)
            remove.target = self
            remove.action = #selector(removeSelectionShortcut(_:))
            remove.tag = button.tag
            selectionShortcutButtons[action] = button
            selectionShortcutRemoveButtons[action] = remove
            return makePreferenceRow(
                title: action.title,
                description: action.settingsDescription,
                control: makeSingleKeyControl(button, remove: remove)
            )
        }
    }

    private func ocrDebugControl(for mode: OCRMode) -> NSView {
        let rows = [
            makeOCRControlRow(title: L10n.text("최소 높이"), control: ocrHeightFields[mode]!),
            makeOCRControlRow(title: L10n.text("배율"), control: ocrScaleFields[mode]!),
            makeOCRControlRow(title: L10n.text("언어 보정"), control: ocrCorrectionSwitches[mode]!),
            makeOCRControlRow(title: L10n.text("언어 자동 판별"), control: ocrAutoLanguageSwitches[mode]!),
        ]
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = SettingsLayoutMetrics.compoundControlSpacing
        stack.widthAnchor.constraint(
            equalToConstant: SettingsLayoutMetrics.trailingControlColumnWidth
        ).isActive = true
        return stack
    }

    private func makeOCRControlRow(title: String, control: NSView) -> NSView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.alignment = .right

        let row = NSStackView(views: [spacer, label, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.widthAnchor.constraint(equalToConstant: SettingsLayoutMetrics.trailingControlColumnWidth).isActive = true
        return row
    }

    @objc private func refinementOCRPolicyChanged(_ sender: Any?) {
        if sender as AnyObject === refinementDelayStepper {
            refinementDelayField.integerValue = refinementDelayStepper.integerValue
        }
        let automaticIndex = automaticStrategyPopup.indexOfSelectedItem
        let manualIndex = manualStrategyPopup.indexOfSelectedItem
        let policy = RefinementOCRPolicy(
            automaticStrategy: OCRExecutionStrategy.allCases.indices.contains(automaticIndex)
                ? OCRExecutionStrategy.allCases[automaticIndex]
                : RefinementOCRPolicy.defaultAutomaticStrategy,
            manualStrategy: OCRExecutionStrategy.allCases.indices.contains(manualIndex)
                ? OCRExecutionStrategy.allCases[manualIndex]
                : RefinementOCRPolicy.defaultManualStrategy,
            alwaysRun: refinementAlwaysRunSwitch.state == .on,
            confidenceThreshold: Float(refinementConfidenceField.stringValue) ?? RefinementOCRPolicy.defaultConfidenceThreshold,
            delayMilliseconds: refinementDelayField.integerValue)
        refinementConfidenceField.stringValue = String(format: "%.2f", policy.confidenceThreshold)
        refinementDelayField.integerValue = policy.delayMilliseconds
        refinementDelayStepper.integerValue = policy.delayMilliseconds
        policy.save()
        onRefinementOCRPolicyChange?(policy)
    }

    @objc private func ocrDebugSettingChanged(_ sender: Any?) {
        for mode in [OCRMode.realtime, .refinement] {
            let previousSettings = OCRSettings.load(mode: mode)
            let height = Float(ocrHeightFields[mode]!.stringValue) ?? previousSettings.minimumTextHeight
            let scale = Float(ocrScaleFields[mode]!.stringValue) ?? previousSettings.imageScale
            let finalSettings = OCRSettings(
                minimumTextHeight: height,
                usesLanguageCorrection: ocrCorrectionSwitches[mode]!.state == .on,
                automaticallyDetectsLanguage: ocrAutoLanguageSwitches[mode]!.state == .on, imageScale: scale)
            finalSettings.save(mode: mode)
            ocrHeightFields[mode]?.stringValue = String(format: "%.3f", finalSettings.minimumTextHeight)
            ocrScaleFields[mode]?.stringValue = String(format: "%.1f", finalSettings.imageScale)
            onOCRSettingsChange?(mode, finalSettings)
        }
    }

    private func makeSection(title: String, rows: [NSView]) -> NSView {
        let sectionTitle = NSTextField(labelWithString: title)
        sectionTitle.font = .systemFont(ofSize: 15, weight: .semibold)

        var arrangedViews: [NSView] = []
        for (index, row) in rows.enumerated() {
            if index > 0 { arrangedViews.append(makeSeparator()) }
            arrangedViews.append(row)
        }
        let rowsStack = NSStackView(views: arrangedViews)
        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 0
        rowsStack.translatesAutoresizingMaskIntoConstraints = false

        let card = NSBox()
        card.boxType = .custom
        card.cornerRadius = 12
        card.borderWidth = 1
        card.borderColor = .separatorColor
        card.fillColor = .controlBackgroundColor
        card.contentView?.addSubview(rowsStack)
        NSLayoutConstraint.activate([
            rowsStack.leadingAnchor.constraint(equalTo: card.contentView!.leadingAnchor, constant: SettingsLayoutMetrics.cardHorizontalInset),
            rowsStack.trailingAnchor.constraint(equalTo: card.contentView!.trailingAnchor, constant: -SettingsLayoutMetrics.cardHorizontalInset),
            rowsStack.topAnchor.constraint(equalTo: card.contentView!.topAnchor, constant: 4),
            rowsStack.bottomAnchor.constraint(equalTo: card.contentView!.bottomAnchor, constant: -4)
        ] + arrangedViews.map { $0.widthAnchor.constraint(equalTo: rowsStack.widthAnchor) })

        let section = NSStackView(views: [sectionTitle, card])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 10
        section.translatesAutoresizingMaskIntoConstraints = false
        card.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        return section
    }

    private func makePreferenceRow(
        title: String, description: String, control: NSView,
        verticalInset: CGFloat = SettingsLayoutMetrics.rowVerticalInset
    ) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        let descriptionLabel = NSTextField(wrappingLabelWithString: description)
        descriptionLabel.font = .systemFont(ofSize: 12)
        descriptionLabel.textColor = .secondaryLabelColor

        let labels = NSStackView(views: [titleLabel, descriptionLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 3
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let controlColumn = makeTrailingControlColumn(control)
        let row = NSStackView(views: [labels, controlColumn])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = SettingsLayoutMetrics.rowControlGap
        row.edgeInsets = NSEdgeInsets(
            top: verticalInset,
            left: 0,
            bottom: verticalInset,
            right: 0
        )
        row.translatesAutoresizingMaskIntoConstraints = false
        preferenceRowLayoutRecords.append(
            (title: title, row: row, controlColumn: controlColumn, control: control)
        )
        return row
    }

    private func makeTrailingControlColumn(_ control: NSView) -> NSView {
        let column = NSView()
        column.translatesAutoresizingMaskIntoConstraints = false
        control.translatesAutoresizingMaskIntoConstraints = false
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)
        column.addSubview(control)
        NSLayoutConstraint.activate([
            column.widthAnchor.constraint(equalToConstant: SettingsLayoutMetrics.trailingControlColumnWidth),
            control.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            control.topAnchor.constraint(equalTo: column.topAnchor),
            control.bottomAnchor.constraint(equalTo: column.bottomAnchor),
            control.leadingAnchor.constraint(greaterThanOrEqualTo: column.leadingAnchor)
        ])
        return column
    }

    private func makeHotKeyControl(_ hotKey: NSButton, remove: NSButton) -> NSView {
        hotKey.widthAnchor.constraint(equalToConstant: 100).isActive = true
        let stack = NSStackView(views: [hotKey, remove])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.alignment = .centerY
        return stack
    }

    /// Single-key control: a "단일키" caption in front of the record button so
    /// the modifier-less nature of the selection-screen shortcuts is obvious.
    private func makeSingleKeyControl(_ hotKey: NSButton, remove: NSButton) -> NSView {
        hotKey.widthAnchor.constraint(equalToConstant: 100).isActive = true
        let caption = NSTextField(labelWithString: L10n.text("단일키"))
        caption.font = .systemFont(ofSize: 11)
        caption.textColor = .secondaryLabelColor
        caption.alignment = .right
        caption.translatesAutoresizingMaskIntoConstraints = false
        caption.setContentHuggingPriority(.required, for: .horizontal)
        let stack = NSStackView(views: [caption, hotKey, remove])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.alignment = .centerY
        return stack
    }

    private func configureHotKeyRemoveButton(_ button: NSButton) {
        let description = L10n.text("단축키 제거")
        button.bezelStyle = .rounded
        button.image = NSImage(
            systemSymbolName: "trash",
            accessibilityDescription: description
        )
        button.imagePosition = .imageOnly
        button.toolTip = description
        button.setAccessibilityLabel(description)
        button.widthAnchor.constraint(equalToConstant: 32).isActive = true
    }

    private func makeSeparator() -> NSBox {
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return separator
    }

    private func configureNumberControl(
        field: NSTextField, stepper: NSStepper, range: ClosedRange<Int>,
        increment: Double, action: Selector
    ) {
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.allowsFloats = false
        formatter.minimum = NSNumber(value: range.lowerBound)
        formatter.maximum = NSNumber(value: range.upperBound)
        field.formatter = formatter
        field.alignment = .right
        field.target = self
        field.action = action
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 64).isActive = true
        stepper.minValue = Double(range.lowerBound)
        stepper.maxValue = Double(range.upperBound)
        stepper.increment = increment
        stepper.target = self
        stepper.action = action
    }

    private func makeNumberControl(field: NSTextField, stepper: NSStepper, unit: String) -> NSView {
        let unitLabel = NSTextField(labelWithString: unit)
        unitLabel.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [field, stepper, unitLabel])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = SettingsLayoutMetrics.compoundControlSpacing - 2
        return stack
    }

    private func configureDecimalControl(
        field: NSTextField, stepper: NSStepper, range: ClosedRange<Float>,
        increment: Double, action: Selector
    ) {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimum = NSNumber(value: range.lowerBound)
        formatter.maximum = NSNumber(value: range.upperBound)
        formatter.maximumFractionDigits = 2
        formatter.allowsFloats = true
        field.formatter = formatter
        field.alignment = .right
        field.target = self
        field.action = action
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 64).isActive = true
        stepper.minValue = Double(range.lowerBound)
        stepper.maxValue = Double(range.upperBound)
        stepper.increment = increment
        stepper.target = self
        stepper.action = action
    }

    private func makeDecimalControl(field: NSTextField, stepper: NSStepper) -> NSView {
        let stack = NSStackView(views: [field, stepper])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = SettingsLayoutMetrics.compoundControlSpacing - 2
        return stack
    }

    @objc private func capturePolicyChanged(_ sender: Any?) {
        if sender as AnyObject === captureFPSStepper {
            captureFPSField.integerValue = captureFPSStepper.integerValue
        } else if sender as AnyObject === ocrIntervalStepper {
            ocrIntervalField.integerValue = ocrIntervalStepper.integerValue
        }
        let policy = CapturePolicy(
            targetFPS: captureFPSField.integerValue,
            realtimeOCRIntervalMilliseconds: ocrIntervalField.integerValue
        )
        captureFPSField.integerValue = policy.targetFPS
        captureFPSStepper.integerValue = policy.targetFPS
        ocrIntervalField.integerValue = policy.realtimeOCRIntervalMilliseconds
        ocrIntervalStepper.integerValue = policy.realtimeOCRIntervalMilliseconds
        policy.save()
        onCapturePolicyChange?(policy)
    }

    @objc private func ocrFilterConfidenceChanged(_ sender: Any?) {
        if sender as AnyObject === ocrFilterConfidenceStepper {
            ocrFilterConfidenceField.doubleValue = ocrFilterConfidenceStepper.doubleValue
        }
        let confidence = OCRRecognitionPolicy.clamp(Float(ocrFilterConfidenceField.doubleValue))
        ocrFilterConfidenceField.stringValue = String(format: "%.2f", confidence)
        ocrFilterConfidenceStepper.doubleValue = Double(confidence)
        OCRRecognitionPolicy.save(confidence)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        if field === captureFPSField || field === ocrIntervalField {
            capturePolicyChanged(field)
        }
        if field === ocrFilterConfidenceField {
            ocrFilterConfidenceChanged(field)
        }
        if field === mirrorBackgroundOpacityField {
            mirrorBackgroundOpacityChanged(field)
        }
        if field === overlayOpacityField {
            overlayOpacityChanged(field)
        }
        if field === activeOverlayOpacityField {
            activeOverlayOpacityChanged(field)
        }
        if field === overlayControlBarOpacityField {
            overlayControlBarOpacityChanged(field)
        }
        if field === activeOverlayControlBarOpacityField {
            activeOverlayControlBarOpacityChanged(field)
        }
        if field === regionBorderOpacityField {
            regionBorderOpacityChanged(field)
        }
        if field === refinementDelayField || field === refinementConfidenceField {
            refinementOCRPolicyChanged(field)
        }
        if field === imageSaveFilenameField {
            let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty {
                field.stringValue = ImageSaveSettings.filenameTemplate()
            } else {
                ImageSaveSettings.save(filenameTemplate: value)
            }
        }
        if ocrHeightFields.values.contains(where: { $0 === field }) || ocrScaleFields.values.contains(where: { $0 === field }) {
            ocrDebugSettingChanged(field)
        }
    }


    @objc private func debugFeaturesChanged() { let enabled = debugFeatures.state == .on; DebugFeatures.save(enabled); onDebugFeaturesChange?(enabled) }
#if LST_EXCLUDE_DEBUG_FEATURES
    @objc private func automaticChecksChanged() {
        onAutomaticChecksChange?(automaticChecks.state == .on)
        refresh()
    }

    @objc private func automaticDownloadsChanged() {
        onAutomaticDownloadsChange?(automaticDownloads.state == .on)
        refresh()
    }
#endif
    @objc private func displayModeChanged() {
        let mode: TranslationDisplayMode = displayModeControl.selectedSegment == 0 ? .mirror : .overlay
        mode.save()
        onDisplayModeChange?(mode)
    }

    @objc private func displayLanguageChanged() {
        guard AppDisplayLanguage.allCases.indices.contains(
            displayLanguagePopup.indexOfSelectedItem
        ) else { return }
        let language = AppDisplayLanguage.allCases[displayLanguagePopup.indexOfSelectedItem]
        language.save()
        onDisplayLanguageChange?(language)
    }

    @objc private func translationDirectionChanged() {
        let direction: TranslationDirection = translationDirectionControl.selectedSegment == 0
            ? .japaneseToKorean : .koreanToJapanese
        direction.save()
        onTranslationDirectionChange?(direction)
    }

    @objc private func nonSourceTextProtectionChanged() {
        onNonSourceTextProtectionChange?(protectNonSourceText.state == .on)
    }

    @objc private func mirrorAlwaysOnTopChanged() { let enabled = mirrorAlwaysOnTop.state == .on; MirrorAlwaysOnTop.save(enabled); onMirrorAlwaysOnTopChange?(enabled) }
    @objc private func selectImageSaveDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = ImageSaveSettings.directoryURL()
        panel.prompt = L10n.text("선택")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        ImageSaveSettings.save(directoryURL: url)
        imageSaveDirectoryField.stringValue = url.standardizedFileURL.path
    }

    @objc private func mirrorBackgroundOpacityChanged(_ sender: Any?) {
        if sender as AnyObject === mirrorBackgroundOpacityStepper { mirrorBackgroundOpacityField.integerValue = mirrorBackgroundOpacityStepper.integerValue }
        let opacity = MirrorBackgroundOpacity.clamp(CGFloat(mirrorBackgroundOpacityField.integerValue) / 100)
        mirrorBackgroundOpacityField.integerValue = Int((opacity * 100).rounded()); mirrorBackgroundOpacityStepper.integerValue = mirrorBackgroundOpacityField.integerValue
        MirrorBackgroundOpacity.save(opacity); onMirrorBackgroundOpacityChange?(opacity)
    }
    @objc private func overlayOpacityChanged(_ sender: Any?) {
        if sender as AnyObject === overlayOpacityStepper {
            overlayOpacityField.integerValue = overlayOpacityStepper.integerValue
        }
        let opacity = OverlayOpacity.clamp(CGFloat(overlayOpacityField.integerValue) / 100)
        overlayOpacityField.integerValue = Int((opacity * 100).rounded())
        overlayOpacityStepper.integerValue = overlayOpacityField.integerValue
        onOverlayOpacityChange?(opacity)
    }
    @objc private func activeOverlayOpacityChanged(_ sender: Any?) {
        if sender as AnyObject === activeOverlayOpacityStepper {
            activeOverlayOpacityField.integerValue = activeOverlayOpacityStepper.integerValue
        }
        let opacity = OverlayActiveOpacity.clamp(
            CGFloat(activeOverlayOpacityField.integerValue) / 100
        )
        activeOverlayOpacityField.integerValue = Int((opacity * 100).rounded())
        activeOverlayOpacityStepper.integerValue = activeOverlayOpacityField.integerValue
        onActiveOverlayOpacityChange?(opacity)
    }
    @objc private func overlayControlBarOpacityChanged(_ sender: Any?) {
        if sender as AnyObject === overlayControlBarOpacityStepper {
            overlayControlBarOpacityField.integerValue = overlayControlBarOpacityStepper.integerValue
        }
        let opacity = OverlayControlBarOpacity.clamp(
            CGFloat(overlayControlBarOpacityField.integerValue) / 100
        )
        overlayControlBarOpacityField.integerValue = Int((opacity * 100).rounded())
        overlayControlBarOpacityStepper.integerValue = overlayControlBarOpacityField.integerValue
        onOverlayControlBarOpacityChange?(opacity)
    }
    @objc private func activeOverlayControlBarOpacityChanged(_ sender: Any?) {
        if sender as AnyObject === activeOverlayControlBarOpacityStepper {
            activeOverlayControlBarOpacityField.integerValue = activeOverlayControlBarOpacityStepper.integerValue
        }
        let opacity = OverlayControlBarActiveOpacity.clamp(
            CGFloat(activeOverlayControlBarOpacityField.integerValue) / 100
        )
        activeOverlayControlBarOpacityField.integerValue = Int((opacity * 100).rounded())
        activeOverlayControlBarOpacityStepper.integerValue = activeOverlayControlBarOpacityField.integerValue
        onActiveOverlayControlBarOpacityChange?(opacity)
    }
    @objc private func overlayIgnoresMouseEventsChanged() {
        let enabled = overlayIgnoresMouseEvents.state == .on
        onOverlayMouseEventIgnoringChange?(enabled)
    }
    @objc private func regionBorderOpacityChanged(_ sender: Any?) {
        if sender as AnyObject === regionBorderOpacityStepper {
            regionBorderOpacityField.integerValue = regionBorderOpacityStepper.integerValue
        }
        let opacity = RegionBorderOpacity.clamp(CGFloat(regionBorderOpacityField.integerValue) / 100)
        regionBorderOpacityField.integerValue = Int((opacity * 100).rounded())
        regionBorderOpacityStepper.integerValue = regionBorderOpacityField.integerValue
        onRegionBorderOpacityChange?(opacity)
    }
    @objc private func recognitionLanguagesChanged() {
        guard OCRRecognitionLanguageChoice.allCases.indices.contains(
            recognitionLanguagesPopup.indexOfSelectedItem
        ) else { return }
        let choice = OCRRecognitionLanguageChoice.allCases[
            recognitionLanguagesPopup.indexOfSelectedItem
        ]
        choice.save()
    }

    @objc private func mirrorFollowSizeChanged() {
        let enabled = mirrorFollowSize.state == .on
        MirrorFollowsSelectionSize.save(enabled)
        onMirrorFollowSelectionSizeChange?(enabled)
    }

    @objc private func targetApplicationTrackingChanged() {
        let enabled = targetApplicationTracking.state == .on
        TargetApplicationTracking.save(enabled)
        onTargetApplicationTrackingChange?(enabled)
    }

    @objc private func launchAtLoginChanged() {
        let enabled = launchAtLogin.state == .on
        guard onLaunchAtLoginChange?(enabled) != false else {
            launchAtLogin.state = enabled ? .off : .on
            return
        }
        LaunchAtLogin.save(enabled)
    }

    @objc private func mirrorUpdateStyleChanged() {
        let style = MirrorUpdateStyle.allCases[mirrorUpdateStylePopup.indexOfSelectedItem]
        style.save()
        onMirrorUpdateStyleChange?(style)
    }

    @objc private func recordSelectionHotKey() {
        stopRecordingHotKey()
        onHotKeyRecordingChange?(true)
        selectionHotKeyButton.title = L10n.text("새 단축키 입력…")
        hotKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == UInt16(kVK_Delete) || event.keyCode == UInt16(kVK_ForwardDelete) {
                _ = self.onSelectionHotKeyRemove?(); self.stopRecordingHotKey(); self.refresh(); return nil
            }
            if event.keyCode == UInt16(kVK_Escape) {
                self.stopRecordingHotKey()
                self.selectionHotKeyButton.title = SelectionHotKey.load().title
                return nil
            }
            guard let hotKey = SelectionHotKey.make(from: event) else {
                NSSound.beep()
                return nil
            }
            guard self.onSelectionHotKeyChange?(hotKey) == true else {
                NSSound.beep()
                self.selectionHotKeyButton.title = L10n.text("사용 중 — 다시 입력")
                return nil
            }
            self.stopRecordingHotKey()
            self.refresh()
            return nil
        }
    }

    @objc private func recordImmediateTranslationHotKey() {
        stopRecordingHotKey()
        onHotKeyRecordingChange?(true)
        immediateTranslationHotKeyButton.title = L10n.text("새 단축키 입력…")
        hotKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == UInt16(kVK_Delete) || event.keyCode == UInt16(kVK_ForwardDelete) {
                _ = self.onImmediateTranslationHotKeyRemove?(); self.stopRecordingHotKey(); self.refresh(); return nil
            }
            if event.keyCode == UInt16(kVK_Escape) {
                self.stopRecordingHotKey()
                self.immediateTranslationHotKeyButton.title = ImmediateTranslationHotKey.load().title
                return nil
            }
            guard let hotKey = ImmediateTranslationHotKey.make(from: event) else {
                NSSound.beep()
                return nil
            }
            guard self.onImmediateTranslationHotKeyChange?(hotKey) == true else {
                NSSound.beep()
                self.immediateTranslationHotKeyButton.title = L10n.text("사용 중 — 다시 입력")
                return nil
            }
            self.stopRecordingHotKey()
            self.refresh()
            return nil
        }
    }

    @objc private func recordMirrorActivationHotKey() {
        stopRecordingHotKey(); onHotKeyRecordingChange?(true); mirrorActivationHotKeyButton.title = L10n.text("새 단축키 입력…")
        hotKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == UInt16(kVK_Delete) || event.keyCode == UInt16(kVK_ForwardDelete) {
                _ = self.onMirrorActivationHotKeyRemove?(); self.stopRecordingHotKey(); self.refresh(); return nil
            }
            if event.keyCode == UInt16(kVK_Escape) { self.stopRecordingHotKey(); self.mirrorActivationHotKeyButton.title = MirrorActivationHotKey.load().title; return nil }
            guard let hotKey = MirrorActivationHotKey.make(from: event), self.onMirrorActivationHotKeyChange?(hotKey) == true else { NSSound.beep(); return nil }
            self.stopRecordingHotKey(); self.refresh(); return nil
        }
    }

    @objc private func recordToolbarHotKey(_ sender: NSButton) {
        let actions = ToolbarShortcutAction.configurableActions
        guard actions.indices.contains(sender.tag) else { return }
        let action = actions[sender.tag]
        stopRecordingHotKey()
        onHotKeyRecordingChange?(true)
        sender.title = L10n.text("새 단축키 입력…")
        hotKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == UInt16(kVK_Delete) || event.keyCode == UInt16(kVK_ForwardDelete) {
                _ = self.onToolbarHotKeyRemove?(action)
                self.stopRecordingHotKey()
                self.refresh()
                return nil
            }
            if event.keyCode == UInt16(kVK_Escape) {
                self.stopRecordingHotKey()
                sender.title = ToolbarHotKey.load(action: action).settingsTitle
                return nil
            }
            guard let hotKey = action == .sessionControlSingleKey
                ? ToolbarHotKey.makeSingleKey(from: event)
                : ToolbarHotKey.make(from: event) else {
                NSSound.beep()
                return nil
            }
            guard self.onToolbarHotKeyChange?(action, hotKey) == true else {
                NSSound.beep()
                sender.title = L10n.text("사용 중 — 다시 입력")
                return nil
            }
            self.stopRecordingHotKey()
            self.refresh()
            return nil
        }
    }

    @objc private func removeToolbarHotKey(_ sender: NSButton) {
        let actions = ToolbarShortcutAction.configurableActions
        guard actions.indices.contains(sender.tag) else { return }
        let action = actions[sender.tag]
        if onToolbarHotKeyRemove?(action) == true { refresh() }
    }

    @objc private func recordSelectionShortcut(_ sender: NSButton) {
        let actions = SelectionShortcutAction.allCases
        guard actions.indices.contains(sender.tag) else { return }
        let action = actions[sender.tag]
        stopRecordingHotKey()
        onHotKeyRecordingChange?(true)
        sender.title = L10n.text("새 단축키 입력…")
        hotKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == UInt16(kVK_Delete) || event.keyCode == UInt16(kVK_ForwardDelete) {
                _ = self.onSelectionShortcutRemove?(action)
                self.stopRecordingHotKey()
                self.refresh()
                return nil
            }
            if event.keyCode == UInt16(kVK_Escape) {
                self.stopRecordingHotKey()
                sender.title = ToolbarHotKey.load(selectionAction: action).settingsTitle
                return nil
            }
            // Selection-screen shortcuts are single keys only: reject any
            // key pressed together with a modifier.
            let relevant: NSEvent.ModifierFlags = [.control, .option, .shift, .command]
            guard event.modifierFlags.intersection(relevant).isEmpty,
                  let hotKey = ToolbarHotKey.makeSingleKey(from: event) else {
                NSSound.beep()
                return nil
            }
            guard self.onSelectionShortcutChange?(action, hotKey) == true else {
                NSSound.beep()
                sender.title = L10n.text("사용 중 — 다시 입력")
                return nil
            }
            self.stopRecordingHotKey()
            self.refresh()
            return nil
        }
    }

    @objc private func removeSelectionShortcut(_ sender: NSButton) {
        let actions = SelectionShortcutAction.allCases
        guard actions.indices.contains(sender.tag) else { return }
        let action = actions[sender.tag]
        if onSelectionShortcutRemove?(action) == true { refresh() }
    }

    @objc private func removeSelectionHotKey() { if onSelectionHotKeyRemove?() == true { refresh() } }
    @objc private func removeImmediateTranslationHotKey() { if onImmediateTranslationHotKeyRemove?() == true { refresh() } }
    @objc private func removeMirrorActivationHotKey() { if onMirrorActivationHotKeyRemove?() == true { refresh() } }

    private func stopRecordingHotKey() {
        if let hotKeyMonitor {
            NSEvent.removeMonitor(hotKeyMonitor)
            self.hotKeyMonitor = nil
            onHotKeyRecordingChange?(false)
        }
    }

    @objc private func resetSettings() {
        let alert = NSAlert()
        alert.messageText = L10n.text("설정을 초기화할까요?")
        alert.informativeText = L10n.text("단축키, 표시 방식, 캡처, OCR 및 업데이트 설정이 모두 기본값으로 돌아갑니다.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.text("초기화"))
        alert.addButton(withTitle: L10n.text("취소"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        stopRecordingHotKey()
        AppSettings.reset()
        onSettingsReset?()
        refresh()
    }

    func windowWillClose(_ notification: Notification) {
        window?.makeFirstResponder(nil)
        stopRecordingHotKey()
    }
}
