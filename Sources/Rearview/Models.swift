import AppKit
import Carbon
import CoreGraphics

/// Canonical defaults for every persisted user preference.
///
/// Preference models keep their existing `defaultValue` APIs, but those APIs
/// delegate here so changing the initial app configuration has one source of truth.
enum AppDefaults {
    // MARK: General

    // Startup and Launch > Launch at macOS Login
    static let launchAtLogin = true

    // Language and Translation
    // Used only when neither a saved app language nor a supported macOS
    // preferred language is available.
    static let displayLanguage: AppDisplayLanguage = .english
    static let translationDirection: TranslationDirection = .japaneseToKorean
    static let protectNonSourceText = false

    // MARK: Shortcuts

    // Global Shortcuts
    static let selectionHotKey = SelectionHotKey(
        keyCode: UInt32(kVK_ANSI_1), modifiers: UInt32(cmdKey | shiftKey), keyLabel: "1"
    )
    static let immediateTranslationHotKey = ImmediateTranslationHotKey(
        keyCode: UInt32(kVK_ANSI_2), modifiers: UInt32(cmdKey | optionKey), keyLabel: "2"
    )
    static let mirrorActivationHotKey = MirrorActivationHotKey(
        keyCode: UInt32(kVK_ANSI_3), modifiers: UInt32(cmdKey | optionKey), keyLabel: "3"
    )

    // Region-selection single-key docking shortcuts
    static func selectionShortcut(for action: SelectionShortcutAction) -> ToolbarHotKey {
        switch action {
        case .displayMode:
            ToolbarHotKey(keyCode: UInt32(kVK_ANSI_2), modifiers: 0, keyLabel: "2", isEnabled: true)
        case .dockTop:
            ToolbarHotKey(keyCode: UInt32(kVK_ANSI_W), modifiers: 0, keyLabel: "W", isEnabled: true)
        case .dockBottom:
            ToolbarHotKey(keyCode: UInt32(kVK_ANSI_S), modifiers: 0, keyLabel: "S", isEnabled: true)
        case .dockLeft:
            ToolbarHotKey(keyCode: UInt32(kVK_ANSI_A), modifiers: 0, keyLabel: "A", isEnabled: true)
        case .dockRight:
            ToolbarHotKey(keyCode: UInt32(kVK_ANSI_D), modifiers: 0, keyLabel: "D", isEnabled: true)
        }
    }

    // General, Translation Session Control, Text and Selection, Mirror Size, Developer Tools
    static func toolbarHotKey(for action: ToolbarShortcutAction) -> ToolbarHotKey {
        let command = UInt32(cmdKey)
        return switch action {
        case .openSettings:
            ToolbarHotKey(keyCode: UInt32(kVK_ANSI_Comma), modifiers: command, keyLabel: ",", isEnabled: true)
        case .stopTranslation:
            ToolbarHotKey(keyCode: UInt32(kVK_ANSI_W), modifiers: command, keyLabel: "W", isEnabled: true)
        case .selectAll:
            ToolbarHotKey(keyCode: UInt32(kVK_ANSI_A), modifiers: command, keyLabel: "A", isEnabled: true)
        case .copySelection:
            ToolbarHotKey(keyCode: UInt32(kVK_ANSI_C), modifiers: command, keyLabel: "C", isEnabled: true)
        case .copyAndClearSelection:
            ToolbarHotKey(keyCode: UInt32(kVK_ANSI_X), modifiers: command, keyLabel: "X", isEnabled: true)
        case .search:
            ToolbarHotKey(keyCode: UInt32(kVK_ANSI_F), modifiers: command, keyLabel: "F", isEnabled: true)
        case .applicationCapture:
            ToolbarHotKey(keyCode: UInt32(kVK_ANSI_1), modifiers: command, keyLabel: "1", isEnabled: true)
        case .displayMode:
            ToolbarHotKey(keyCode: UInt32(kVK_ANSI_2), modifiers: command, keyLabel: "2", isEnabled: true)
        case .protectNonSourceText:
            ToolbarHotKey(keyCode: UInt32(kVK_ANSI_4), modifiers: command, keyLabel: "4", isEnabled: true)
        case .modeSpecificDisplayControl:
            ToolbarHotKey(keyCode: UInt32(kVK_ANSI_6), modifiers: command, keyLabel: "6", isEnabled: true)
        case .followSelectionSize:
            ToolbarHotKey(keyCode: UInt32(kVK_ANSI_8), modifiers: command, keyLabel: "8", isEnabled: true)
        case .dockTop:
            ToolbarHotKey(keyCode: UInt32(kVK_UpArrow), modifiers: command, keyLabel: "↑", isEnabled: true)
        case .dockBottom:
            ToolbarHotKey(keyCode: UInt32(kVK_DownArrow), modifiers: command, keyLabel: "↓", isEnabled: true)
        case .dockLeft:
            ToolbarHotKey(keyCode: UInt32(kVK_LeftArrow), modifiers: command, keyLabel: "←", isEnabled: true)
        case .dockRight:
            ToolbarHotKey(keyCode: UInt32(kVK_RightArrow), modifiers: command, keyLabel: "→", isEnabled: true)
        case .fitWindowToContent:
            ToolbarHotKey(keyCode: UInt32(kVK_ANSI_9), modifiers: command, keyLabel: "9", isEnabled: true)
        case .zoomActual:
            ToolbarHotKey(keyCode: UInt32(kVK_ANSI_0), modifiers: command, keyLabel: "0", isEnabled: true)
        case .zoomOut:
            ToolbarHotKey(keyCode: UInt32(kVK_ANSI_Minus), modifiers: command, keyLabel: "-", isEnabled: true)
        case .zoomIn:
            ToolbarHotKey(keyCode: UInt32(kVK_ANSI_Equal), modifiers: command, keyLabel: "=", isEnabled: true)
        case .translationDirection:
            ToolbarHotKey(keyCode: UInt32(kVK_ANSI_3), modifiers: command, keyLabel: "3", isEnabled: true)
        case .refreshMode:
            ToolbarHotKey(keyCode: UInt32(kVK_ANSI_5), modifiers: command, keyLabel: "5", isEnabled: true)
        case .sessionControlSingleKey:
            ToolbarHotKey(keyCode: UInt32(kVK_Space), modifiers: 0, keyLabel: "Space", isEnabled: true)
        case .selectionMode:
            ToolbarHotKey(keyCode: UInt32(kVK_ANSI_D), modifiers: command, keyLabel: "D", isEnabled: true)
        case .copyAll:
            ToolbarHotKey(keyCode: UInt32(kVK_ANSI_C), modifiers: UInt32(cmdKey | shiftKey), keyLabel: "C", isEnabled: true)
        case .copyImage:
            ToolbarHotKey(keyCode: UInt32(kVK_ANSI_C), modifiers: UInt32(controlKey | cmdKey), keyLabel: "C", isEnabled: true)
        case .saveImage:
            ToolbarHotKey(keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(cmdKey), keyLabel: "S", isEnabled: true)
        default:
            ToolbarHotKey(keyCode: 0, modifiers: 0, keyLabel: "", isEnabled: false)
        }
    }

    // MARK: Display

    // Display Mode > Translation Display Mode
    static let translationDisplayMode: TranslationDisplayMode = .mirror

    // Mirror Window
    static let mirrorAlwaysOnTop = true
    static let mirrorBackgroundOpacity: CGFloat = 0.96
    static let mirrorFollowsSelectionSize = true

    // Image saving
    static let imageSaveFilenameTemplate = "Rearview_{yyyy-MM-dd_HH-mm-ss}_{counter}"

    // Overlay
    static let inactiveOverlayOpacity: CGFloat = 0.85
    static let activeOverlayOpacity: CGFloat = 0.96
    static let inactiveControlBarOpacity: CGFloat = 0.20
    static let activeControlBarOpacity: CGFloat = 0.75
    static let overlayIgnoresMouseEvents = true

    // Selection Area > Area Border Opacity
    static let regionBorderOpacity: CGFloat = 0.96

    // MARK: Capture and OCR

    // Capture
    static let captureTargetFPS = 12
    static let targetApplicationTracking = true

    // Refresh
    static let refreshMode: RefreshMode = .automatic
    static let realtimeOCRIntervalMilliseconds = 500
    static let mirrorUpdateStyle: MirrorUpdateStyle = .atomic

    // OCR Execution
    static let automaticOCRStrategy: OCRExecutionStrategy = .realtimeImmediately
    static let manualOCRStrategy: OCRExecutionStrategy = .refinementImmediately

    // Refinement Conditions
    static let refinementAlwaysRuns = false
    static let refinementConfidenceThreshold: Float = 0.80
    static let refinementDelayMilliseconds = 400

    // OCR Languages and Filters
    static let recognitionLanguageChoice: OCRRecognitionLanguageChoice = .unset
    static let ocrMinimumConfidence: Float = 0.10

    // Advanced OCR > realtime OCR / refinement OCR
    static let ocrMinimumTextHeight: Float = 0.008
    static let realtimeOCRImageScale: Float = 1.0
    static let refinementOCRImageScale: Float = 1.5
    static let ocrUsesLanguageCorrection = false
    static let ocrAutomaticallyDetectsLanguage = true

    // Fixed OCR profile not exposed in Advanced OCR
    static let ocrEngine: OCREngine = .text
    static let ocrRecognitionLevel: OCRRecognitionLevel = .accurate
    static let ocrRevision: OCRSettings.Revision = .current

    // MARK: Developer

    // Diagnostics > Debug Features
    static let debugFeaturesEnabled = false

}

enum ImageSaveSettings {
    static let directoryDefaultsKey = "imageSave.directoryPath"
    static let filenameTemplateDefaultsKey = "imageSave.filenameTemplate"

    static func directoryURL(from defaults: UserDefaults = .standard) -> URL {
        if let path = defaults.string(forKey: directoryDefaultsKey), !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents")
        return documents.appendingPathComponent("Rearview", isDirectory: true)
    }

    static func save(directoryURL: URL, to defaults: UserDefaults = .standard) {
        defaults.set(directoryURL.standardizedFileURL.path, forKey: directoryDefaultsKey)
    }

    static func filenameTemplate(from defaults: UserDefaults = .standard) -> String {
        let value = defaults.string(forKey: filenameTemplateDefaultsKey) ?? ""
        return value.isEmpty ? AppDefaults.imageSaveFilenameTemplate : value
    }

    static func save(filenameTemplate: String, to defaults: UserDefaults = .standard) {
        defaults.set(filenameTemplate, forKey: filenameTemplateDefaultsKey)
    }
}

enum AppSettings {
    static let defaultsKeys: [String] = [
        SelectionHotKey.keyCodeDefaultsKey, SelectionHotKey.modifiersDefaultsKey, SelectionHotKey.keyLabelDefaultsKey,
        "selectionHotKeyEnabled",
        ImmediateTranslationHotKey.keyCodeDefaultsKey, ImmediateTranslationHotKey.modifiersDefaultsKey, ImmediateTranslationHotKey.keyLabelDefaultsKey,
        "immediateTranslationHotKeyEnabled",
        "mirrorActivationHotKeyKeyCode", "mirrorActivationHotKeyModifiers", "mirrorActivationHotKeyLabel", "mirrorActivationHotKeyEnabled",
        MirrorUpdateStyle.defaultsKey, TranslationDisplayMode.defaultsKey, RefreshMode.defaultsKey,
        OverlayOpacity.defaultsKey,
        OverlayActiveOpacity.defaultsKey, OverlayControlBarOpacity.defaultsKey,
        OverlayControlBarActiveOpacity.defaultsKey,
        OverlayIgnoresMouseEvents.defaultsKey,
        "overlayInteractionModifier", MirrorBackgroundOpacity.defaultsKey, RegionBorderOpacity.defaultsKey,
        MirrorAlwaysOnTop.defaultsKey, DebugFeatures.defaultsKey, MirrorFollowsSelectionSize.defaultsKey,
        MirrorDockingState.defaultsKey, MirrorDockingState.undockedFrameKey,
        LaunchAtLogin.defaultsKey, TargetApplicationTracking.defaultsKey,
        // Legacy overlay toolbar size, retained only so Reset Settings removes it.
        "overlayToolbarSize",
        TranslationDirection.defaultsKey,
        TranslationTextProtection.defaultsKey,
        AppDisplayLanguage.defaultsKey,
    ] + ToolbarShortcutAction.allCases.flatMap { action in
            let key = "toolbarShortcut.\(action.rawValue)"
            return ["\(key).keyCode", "\(key).modifiers", "\(key).label", "\(key).enabled"]
        } + SelectionShortcutAction.allCases.flatMap { action in
            let key = "selectionShortcut.\(action.rawValue)"
            return ["\(key).keyCode", "\(key).label", "\(key).enabled"]
        } + [
        // Remove obsolete toolbar shortcuts from older versions as well.
        "toolbarShortcut.translateImmediately.keyCode", "toolbarShortcut.translateImmediately.modifiers",
        "toolbarShortcut.translateImmediately.label", "toolbarShortcut.translateImmediately.enabled",
        "toolbarShortcut.mouseEvents.keyCode", "toolbarShortcut.mouseEvents.modifiers",
        "toolbarShortcut.mouseEvents.label", "toolbarShortcut.mouseEvents.enabled",
        "toolbarShortcut.alwaysOnTop.keyCode", "toolbarShortcut.alwaysOnTop.modifiers",
        "toolbarShortcut.alwaysOnTop.label", "toolbarShortcut.alwaysOnTop.enabled",
        "toolbarShortcut.pause.keyCode", "toolbarShortcut.pause.modifiers",
        "toolbarShortcut.pause.label", "toolbarShortcut.pause.enabled",
        CapturePolicy.targetFPSKey, CapturePolicy.realtimeOCRIntervalMillisecondsKey,
        OCRRecognitionPolicy.minimumConfidenceKey, RefinementOCRPolicy.automaticStrategyKey,
        RefinementOCRPolicy.manualStrategyKey, RefinementOCRPolicy.alwaysRunKey,
        RefinementOCRPolicy.confidenceThresholdKey, RefinementOCRPolicy.delayMillisecondsKey,
        OCRRecognitionLanguageChoice.defaultsKey,
        ImageSaveSettings.directoryDefaultsKey, ImageSaveSettings.filenameTemplateDefaultsKey
    ] + UpdateSettingsDefaults.keys + [OCRMode.realtime, .refinement].flatMap { mode in
        let key = "ocr.\(mode.rawValue)."
        return [
            "\(key)engine", "\(key)level", "\(key)minimumTextHeight",
            "\(key)revision", "\(key)languageCorrection", "\(key)autoLanguage",
            "\(key)imageScale"
        ]
    }

    static func reset(to defaults: UserDefaults = .standard) {
        defaultsKeys.forEach { defaults.removeObject(forKey: $0) }
    }
}

enum TranslationTextProtection {
    static let defaultsKey = "translation.protectNonSourceText"
    static let defaultValue = AppDefaults.protectNonSourceText

    static func load(from defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: defaultsKey) == nil
            ? defaultValue : defaults.bool(forKey: defaultsKey)
    }

    static func save(_ enabled: Bool, to defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: defaultsKey)
    }
}

struct SelectionHotKey: Equatable, Sendable {
    static let keyCodeDefaultsKey = "selectionHotKeyKeyCode"
    static let modifiersDefaultsKey = "selectionHotKeyModifiers"
    static let keyLabelDefaultsKey = "selectionHotKeyLabel"
    static let defaultValue = AppDefaults.selectionHotKey

    let keyCode: UInt32
    let modifiers: UInt32
    let keyLabel: String
    let isEnabled: Bool
    init(keyCode: UInt32, modifiers: UInt32, keyLabel: String, isEnabled: Bool = true) { self.keyCode = keyCode; self.modifiers = modifiers; self.keyLabel = keyLabel; self.isEnabled = isEnabled }

    /// Compact title used in tooltips and control bar hints: Space renders as "␣".
    var title: String {
        guard isEnabled else { return L10n.text("사용 안 함") }
        let keyTitle = keyCode == UInt32(kVK_Space) ? "␣" : keyLabel.uppercased()
        return modifierPrefix + keyTitle
    }

    /// Title for the settings assignment button: keeps the raw key name
    /// (for example "SPACE") instead of the compact glyph.
    var settingsTitle: String {
        guard isEnabled else { return L10n.text("사용 안 함") }
        return modifierPrefix + keyLabel.uppercased()
    }

    private var modifierPrefix: String {
        var result = ""
        if modifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        return result
    }

    var menuModifierFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if modifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if modifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if modifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        return flags
    }

    static func load(from defaults: UserDefaults = .standard) -> SelectionHotKey {
        guard defaults.object(forKey: keyCodeDefaultsKey) != nil,
              defaults.object(forKey: modifiersDefaultsKey) != nil,
              let label = defaults.string(forKey: keyLabelDefaultsKey), !label.isEmpty else {
            return defaultValue
        }
        return SelectionHotKey(
            keyCode: UInt32(defaults.integer(forKey: keyCodeDefaultsKey)),
            modifiers: UInt32(defaults.integer(forKey: modifiersDefaultsKey)),
            keyLabel: label,
            isEnabled: defaults.object(forKey: "selectionHotKeyEnabled") == nil
                ? defaultValue.isEnabled : defaults.bool(forKey: "selectionHotKeyEnabled")
        )
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(Int(keyCode), forKey: Self.keyCodeDefaultsKey)
        defaults.set(Int(modifiers), forKey: Self.modifiersDefaultsKey)
        defaults.set(keyLabel, forKey: Self.keyLabelDefaultsKey)
        defaults.set(isEnabled, forKey: "selectionHotKeyEnabled")
    }

    static func make(from event: NSEvent) -> SelectionHotKey? {
        guard event.keyCode != UInt16(kVK_Escape),
              let characters = event.charactersIgnoringModifiers, !characters.isEmpty else { return nil }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.intersection([.command, .option, .control]).isEmpty else { return nil }
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        return SelectionHotKey(
            keyCode: UInt32(event.keyCode), modifiers: modifiers,
            keyLabel: HotKeyKeyLabel.resolve(keyCode: event.keyCode, fallback: characters), isEnabled: true
        )
    }
}

enum HotKeyKeyLabel {
    static func resolve(keyCode: UInt16, fallback: String) -> String {
        let labels: [UInt16: String] = [
            UInt16(kVK_ANSI_0): "0", UInt16(kVK_ANSI_1): "1", UInt16(kVK_ANSI_2): "2",
            UInt16(kVK_ANSI_3): "3", UInt16(kVK_ANSI_4): "4", UInt16(kVK_ANSI_5): "5",
            UInt16(kVK_ANSI_6): "6", UInt16(kVK_ANSI_7): "7", UInt16(kVK_ANSI_8): "8",
            UInt16(kVK_ANSI_9): "9", UInt16(kVK_ANSI_A): "A", UInt16(kVK_ANSI_B): "B",
            UInt16(kVK_ANSI_C): "C", UInt16(kVK_ANSI_D): "D", UInt16(kVK_ANSI_E): "E",
            UInt16(kVK_ANSI_F): "F", UInt16(kVK_ANSI_G): "G", UInt16(kVK_ANSI_H): "H",
            UInt16(kVK_ANSI_I): "I", UInt16(kVK_ANSI_J): "J", UInt16(kVK_ANSI_K): "K",
            UInt16(kVK_ANSI_L): "L", UInt16(kVK_ANSI_M): "M", UInt16(kVK_ANSI_N): "N",
            UInt16(kVK_ANSI_O): "O", UInt16(kVK_ANSI_P): "P", UInt16(kVK_ANSI_Q): "Q",
            UInt16(kVK_ANSI_R): "R", UInt16(kVK_ANSI_S): "S", UInt16(kVK_ANSI_T): "T",
            UInt16(kVK_ANSI_U): "U", UInt16(kVK_ANSI_V): "V", UInt16(kVK_ANSI_W): "W",
            UInt16(kVK_ANSI_X): "X", UInt16(kVK_ANSI_Y): "Y", UInt16(kVK_ANSI_Z): "Z",
            UInt16(kVK_ANSI_Minus): "-", UInt16(kVK_ANSI_Equal): "=",
            UInt16(kVK_ANSI_LeftBracket): "[", UInt16(kVK_ANSI_RightBracket): "]",
            UInt16(kVK_ANSI_Semicolon): ";", UInt16(kVK_ANSI_Quote): "'",
            UInt16(kVK_ANSI_Comma): ",", UInt16(kVK_ANSI_Period): ".",
            UInt16(kVK_ANSI_Slash): "/", UInt16(kVK_ANSI_Backslash): "\\",
            UInt16(kVK_Space): "Space", UInt16(kVK_Return): "Return", UInt16(kVK_Tab): "Tab",
            UInt16(kVK_Delete): "Delete", UInt16(kVK_ForwardDelete): "Forward Delete",
            UInt16(kVK_LeftArrow): "←", UInt16(kVK_RightArrow): "→",
            UInt16(kVK_UpArrow): "↑", UInt16(kVK_DownArrow): "↓"
        ]
        return labels[keyCode] ?? fallback.uppercased()
    }
}

struct ImmediateTranslationHotKey: Equatable, Sendable {
    static let keyCodeDefaultsKey = "immediateTranslationHotKeyKeyCode"
    static let modifiersDefaultsKey = "immediateTranslationHotKeyModifiers"
    static let keyLabelDefaultsKey = "immediateTranslationHotKeyLabel"
    static let defaultValue = AppDefaults.immediateTranslationHotKey

    let keyCode: UInt32
    let modifiers: UInt32
    let keyLabel: String
    let isEnabled: Bool
    init(keyCode: UInt32, modifiers: UInt32, keyLabel: String, isEnabled: Bool = true) { self.keyCode = keyCode; self.modifiers = modifiers; self.keyLabel = keyLabel; self.isEnabled = isEnabled }

    var title: String {
        SelectionHotKey(
            keyCode: keyCode, modifiers: modifiers, keyLabel: keyLabel,
            isEnabled: isEnabled
        ).title
    }

    static func load(from defaults: UserDefaults = .standard) -> ImmediateTranslationHotKey {
        guard defaults.object(forKey: keyCodeDefaultsKey) != nil,
              defaults.object(forKey: modifiersDefaultsKey) != nil,
              let label = defaults.string(forKey: keyLabelDefaultsKey), !label.isEmpty else {
            return defaultValue
        }
        return ImmediateTranslationHotKey(
            keyCode: UInt32(defaults.integer(forKey: keyCodeDefaultsKey)),
            modifiers: UInt32(defaults.integer(forKey: modifiersDefaultsKey)), keyLabel: label,
            isEnabled: defaults.object(forKey: "immediateTranslationHotKeyEnabled") == nil
                ? defaultValue.isEnabled
                : defaults.bool(forKey: "immediateTranslationHotKeyEnabled")
        )
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(Int(keyCode), forKey: Self.keyCodeDefaultsKey)
        defaults.set(Int(modifiers), forKey: Self.modifiersDefaultsKey)
        defaults.set(keyLabel, forKey: Self.keyLabelDefaultsKey)
        defaults.set(isEnabled, forKey: "immediateTranslationHotKeyEnabled")
    }

    static func make(from event: NSEvent) -> ImmediateTranslationHotKey? {
        guard let value = SelectionHotKey.make(from: event) else { return nil }
        return ImmediateTranslationHotKey(
            keyCode: value.keyCode, modifiers: value.modifiers, keyLabel: value.keyLabel
        )
    }
}

struct MirrorActivationHotKey: Equatable, Sendable {
    private static let codeKey = "mirrorActivationHotKeyKeyCode", modifiersKey = "mirrorActivationHotKeyModifiers", labelKey = "mirrorActivationHotKeyLabel"
    static let defaultValue = AppDefaults.mirrorActivationHotKey
    let keyCode: UInt32
    let modifiers: UInt32
    let keyLabel: String
    let isEnabled: Bool
    init(keyCode: UInt32, modifiers: UInt32, keyLabel: String, isEnabled: Bool = true) { self.keyCode = keyCode; self.modifiers = modifiers; self.keyLabel = keyLabel; self.isEnabled = isEnabled }
    var title: String {
        SelectionHotKey(
            keyCode: keyCode, modifiers: modifiers, keyLabel: keyLabel,
            isEnabled: isEnabled
        ).title
    }
    static func load(from d: UserDefaults = .standard) -> Self {
        guard d.object(forKey: codeKey) != nil, let label = d.string(forKey: labelKey) else { return defaultValue }
        return Self(
            keyCode: UInt32(d.integer(forKey: codeKey)),
            modifiers: UInt32(d.integer(forKey: modifiersKey)), keyLabel: label,
            isEnabled: d.object(forKey: "mirrorActivationHotKeyEnabled") == nil
                ? defaultValue.isEnabled : d.bool(forKey: "mirrorActivationHotKeyEnabled")
        )
    }
    func save(to d: UserDefaults = .standard) { d.set(Int(keyCode), forKey: Self.codeKey); d.set(Int(modifiers), forKey: Self.modifiersKey); d.set(keyLabel, forKey: Self.labelKey); d.set(isEnabled, forKey: "mirrorActivationHotKeyEnabled") }
    static func make(from event: NSEvent) -> Self? {
        guard let value = SelectionHotKey.make(from: event) else { return nil }
        return Self(keyCode: value.keyCode, modifiers: value.modifiers, keyLabel: value.keyLabel)
    }
}

enum ToolbarShortcutAction: String, CaseIterable, Sendable {
    case openSettings
    case stopTranslation
    case applicationCapture
    case translationDirection
    case protectNonSourceText
    case displayMode
    case refreshMode
    case sessionControlSingleKey
    case modeSpecificDisplayControl
    case selectAll
    case copySelection
    case copyAndClearSelection
    case copyAll
    case copyImage
    case saveImage
    case search
    case selectionMode
    case zoomOut
    case zoomActual
    case zoomIn
    case fitWindowToContent
    case followSelectionSize
    case dockTop
    case dockBottom
    case dockLeft
    case dockRight
    case debugOverlay

    static var configurableActions: [Self] {
#if LST_EXCLUDE_DEBUG_FEATURES
        allCases.filter { $0 != .debugOverlay }
#else
        allCases
#endif
    }

    var title: String {
        switch self {
        case .openSettings: L10n.text("설정 열기")
        case .stopTranslation: L10n.text("번역 종료")
        case .applicationCapture: L10n.text("캡처 대상 선택")
        case .translationDirection: L10n.text("번역 방향 전환")
        case .protectNonSourceText: L10n.text("원문 외 텍스트 보호 전환")
        case .displayMode: L10n.text("미러/오버레이 모드 전환")
        case .refreshMode: L10n.text("자동/수동 갱신 전환")
        case .sessionControlSingleKey: L10n.text("일시정지/재생/즉시 번역")
        case .modeSpecificDisplayControl: L10n.text("모드별 화면 동작 전환")
        case .selectAll: L10n.text("전체 선택")
        case .copySelection: L10n.text("선택 복사")
        case .copyAndClearSelection: L10n.text("복사 후 선택 해제")
        case .copyAll: L10n.text("전체 복사")
        case .copyImage: L10n.text("이미지 복사")
        case .saveImage: L10n.text("이미지 저장")
        case .search: L10n.text("텍스트 검색")
        case .selectionMode: L10n.text("선택 모드 전환")
        case .zoomOut: L10n.text("축소")
        case .zoomActual: L10n.text("실제 크기")
        case .zoomIn: L10n.text("확대")
        case .fitWindowToContent: L10n.text("여백 제거")
        case .followSelectionSize: L10n.text("선택 영역 크기 연동")
        case .dockTop: L10n.text("위쪽에 도킹")
        case .dockBottom: L10n.text("아래쪽에 도킹")
        case .dockLeft: L10n.text("왼쪽에 도킹")
        case .dockRight: L10n.text("오른쪽에 도킹")
        case .debugOverlay: L10n.text("OCR 디버그 오버레이")
        }
    }

    var settingsDescription: String {
        switch self {
        case .openSettings:
            L10n.text("앱 설정을 엽니다.")
        case .stopTranslation:
            L10n.text("현재 번역 세션과 화면 캡처를 종료합니다.")
        case .applicationCapture:
            L10n.text("현재 영역에서 캡처할 앱을 선택합니다.")
        case .translationDirection:
            L10n.text("일→한과 한→일 번역 방향을 전환합니다.")
        case .protectNonSourceText:
            L10n.text("영어·반대 언어·숫자를 번역에서 제외하거나 혼합 문맥을 유지하도록 전환합니다.")
        case .displayMode:
            L10n.text("번역 결과를 별도 미러 창에 표시하거나 원래 영역 위에 오버레이로 표시합니다.")
        case .refreshMode:
            L10n.text("화면 변화를 감지해 자동으로 갱신하거나, 사용자가 직접 번역을 실행하는 방식으로 전환합니다.")
        case .sessionControlSingleKey:
            L10n.text("자동 갱신 모드에서는 번역을 일시정지하거나 재생하고, 수동 갱신 모드에서는 현재 영역을 즉시 번역합니다. 보조 키 없이 단일 키로 동작합니다.")
        case .modeSpecificDisplayControl:
            L10n.text("미러 모드에서는 항상 위를, 오버레이 모드에서는 선택 영역의 마우스 입력 통과/무시를 전환합니다.")
        case .selectAll:
            L10n.text("현재 인식된 텍스트와 번역문을 모두 선택합니다.")
        case .copySelection:
            L10n.text("선택한 텍스트를 클립보드에 복사합니다.")
        case .copyAndClearSelection:
            L10n.text("선택한 텍스트를 복사한 뒤 선택을 해제합니다.")
        case .copyAll:
            L10n.text("현재 결과의 텍스트와 번역문을 읽기 순서대로 모두 복사합니다.")
        case .copyImage:
            L10n.text("현재 번역 영역의 이미지를 클립보드에 복사합니다.")
        case .saveImage:
            L10n.text("현재 번역 영역의 이미지를 PNG 파일로 저장합니다.")
        case .search:
            L10n.text("현재 인식된 텍스트와 번역문을 검색합니다.")
        case .selectionMode:
            L10n.text("번역 화면에서 인식된 텍스트를 선택할 수 있도록 선택 모드를 켜거나 끕니다.")
        case .zoomOut:
            L10n.text("미러 창의 표시 배율을 낮춥니다.")
        case .zoomActual:
            L10n.text("미러 창의 표시 배율을 원본 크기 100%로 되돌립니다.")
        case .zoomIn:
            L10n.text("미러 창의 표시 배율을 높입니다.")
        case .fitWindowToContent:
            L10n.text("이미지 표시 크기는 유지한 채 미러 창의 남는 여백을 제거합니다.")
        case .followSelectionSize:
            L10n.text("미러 창의 크기를 캡처 선택 영역의 크기에 맞춰 연동하거나 해제합니다.")
        case .dockTop:
            L10n.text("미러 창을 선택 영역의 위쪽 변에 도킹하거나 같은 방향에서 해제합니다.")
        case .dockBottom:
            L10n.text("미러 창을 선택 영역의 아래쪽 변에 도킹하거나 같은 방향에서 해제합니다.")
        case .dockLeft:
            L10n.text("미러 창을 선택 영역의 왼쪽 변에 도킹하거나 같은 방향에서 해제합니다.")
        case .dockRight:
            L10n.text("미러 창을 선택 영역의 오른쪽 변에 도킹하거나 같은 방향에서 해제합니다.")
        case .debugOverlay:
            L10n.text("OCR 인식 영역과 처리 상태를 화면에 표시하거나 숨깁니다.")
        }
    }
}

enum TranslationDirection: String, CaseIterable, Codable, Sendable {
    case japaneseToKorean
    case koreanToJapanese

    static let defaultsKey = "translation.direction"
    static let defaultValue = AppDefaults.translationDirection

    static func load(from defaults: UserDefaults = .standard) -> Self {
        Self(rawValue: defaults.string(forKey: defaultsKey) ?? "") ?? defaultValue
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }

    var title: String {
        switch self {
        case .japaneseToKorean: L10n.text("일→한")
        case .koreanToJapanese: L10n.text("한→일")
        }
    }

    var sourceLocale: Locale.Language {
        Locale.Language(identifier: self == .japaneseToKorean ? "ja" : "ko")
    }

    var targetLocale: Locale.Language {
        Locale.Language(identifier: self == .japaneseToKorean ? "ko" : "ja")
    }

    var sourceLanguageCode: String { self == .japaneseToKorean ? "ja" : "ko" }

    var toggled: Self { self == .japaneseToKorean ? .koreanToJapanese : .japaneseToKorean }
}

struct ToolbarHotKey: Equatable, Sendable {
    let keyCode: UInt32
    let modifiers: UInt32
    let keyLabel: String
    let isEnabled: Bool

    static func defaultValue(for action: ToolbarShortcutAction) -> ToolbarHotKey {
        AppDefaults.toolbarHotKey(for: action)
    }

    var title: String {
        guard isEnabled else { return L10n.text("사용 안 함") }
        return SelectionHotKey(
            keyCode: keyCode, modifiers: modifiers, keyLabel: keyLabel
        ).title
    }

    /// Settings button title: keeps the raw key name (for example "SPACE")
    /// instead of the compact glyph used in tooltips and hints.
    var settingsTitle: String {
        guard isEnabled else { return L10n.text("사용 안 함") }
        return SelectionHotKey(
            keyCode: keyCode, modifiers: modifiers, keyLabel: keyLabel
        ).settingsTitle
    }

    static func load(
        action: ToolbarShortcutAction, from defaults: UserDefaults = .standard
    ) -> ToolbarHotKey {
        let prefix = "toolbarShortcut.\(action.rawValue)"
        guard defaults.object(forKey: "\(prefix).keyCode") != nil,
              let label = defaults.string(forKey: "\(prefix).label"),
              !label.isEmpty else {
            return defaultValue(for: action)
        }
        return ToolbarHotKey(
            keyCode: UInt32(defaults.integer(forKey: "\(prefix).keyCode")),
            modifiers: UInt32(defaults.integer(forKey: "\(prefix).modifiers")),
            keyLabel: label,
            isEnabled: defaults.object(forKey: "\(prefix).enabled") == nil
                ? defaultValue(for: action).isEnabled
                : defaults.bool(forKey: "\(prefix).enabled")
        )
    }

    func save(
        action: ToolbarShortcutAction, to defaults: UserDefaults = .standard
    ) {
        let prefix = "toolbarShortcut.\(action.rawValue)"
        defaults.set(Int(keyCode), forKey: "\(prefix).keyCode")
        defaults.set(Int(modifiers), forKey: "\(prefix).modifiers")
        defaults.set(keyLabel, forKey: "\(prefix).label")
        defaults.set(isEnabled, forKey: "\(prefix).enabled")
    }

    static func make(from event: NSEvent) -> ToolbarHotKey? {
        guard let value = SelectionHotKey.make(from: event) else { return nil }
        return ToolbarHotKey(
            keyCode: value.keyCode, modifiers: value.modifiers,
            keyLabel: value.keyLabel, isEnabled: true
        )
    }

    /// Records a shortcut for the dedicated single-key session-control action.
    /// Unlike `make(from:)`, a modifier-less key (for example Space) is accepted,
    /// because the action is designed to work as a bare single key.
    static func makeSingleKey(from event: NSEvent) -> ToolbarHotKey? {
        guard event.keyCode != UInt16(kVK_Escape),
              let characters = event.charactersIgnoringModifiers, !characters.isEmpty else { return nil }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        return ToolbarHotKey(
            keyCode: UInt32(event.keyCode), modifiers: modifiers,
            keyLabel: HotKeyKeyLabel.resolve(keyCode: event.keyCode, fallback: characters),
            isEnabled: true
        )
    }
}

/// Converts a configured shortcut into the AppKit key-equivalent form used
/// by menu items. Printable keys keep the existing label-based behavior;
/// Space uses the same compact glyph shown in shortcut tooltips.
func menuKeyEquivalent(keyCode: UInt32, keyLabel: String) -> String {
    guard !keyLabel.isEmpty else { return "" }
    if keyCode == UInt32(kVK_Space) { return "␣" }
    return keyLabel.lowercased()
}

func clearMenuShortcut(_ item: NSMenuItem) {
    item.keyEquivalent = ""
    item.keyEquivalentModifierMask = []
}

private func applyMenuShortcut(
    keyCode: UInt32, modifiers: UInt32, keyLabel: String, isEnabled: Bool,
    to item: NSMenuItem
) {
    guard isEnabled else {
        clearMenuShortcut(item)
        return
    }
    item.keyEquivalent = menuKeyEquivalent(keyCode: keyCode, keyLabel: keyLabel)
    item.keyEquivalentModifierMask = SelectionHotKey(
        keyCode: keyCode, modifiers: modifiers, keyLabel: keyLabel
    ).menuModifierFlags
}

func applyMenuShortcut(_ hotKey: SelectionHotKey, to item: NSMenuItem) {
    applyMenuShortcut(
        keyCode: hotKey.keyCode, modifiers: hotKey.modifiers,
        keyLabel: hotKey.keyLabel, isEnabled: hotKey.isEnabled, to: item
    )
}

func applyMenuShortcut(_ hotKey: ToolbarHotKey, to item: NSMenuItem) {
    applyMenuShortcut(
        keyCode: hotKey.keyCode, modifiers: hotKey.modifiers,
        keyLabel: hotKey.keyLabel, isEnabled: hotKey.isEnabled, to: item
    )
}

func applyMenuShortcut(_ hotKey: ImmediateTranslationHotKey, to item: NSMenuItem) {
    applyMenuShortcut(
        keyCode: hotKey.keyCode, modifiers: hotKey.modifiers,
        keyLabel: hotKey.keyLabel, isEnabled: hotKey.isEnabled, to: item
    )
}

/// Single-key shortcuts usable on the region-selection screen. Separate from
/// the running-session toolbar shortcuts: while selecting, only the bare key
/// (no modifier) is matched, so these are configured independently.
enum SelectionShortcutAction: String, CaseIterable, Sendable {
    case displayMode
    case dockTop
    case dockBottom
    case dockLeft
    case dockRight

    var title: String {
        switch self {
        case .displayMode: L10n.text("미러/오버레이 모드 전환")
        case .dockTop: L10n.text("위쪽에 도킹")
        case .dockBottom: L10n.text("아래쪽에 도킹")
        case .dockLeft: L10n.text("왼쪽에 도킹")
        case .dockRight: L10n.text("오른쪽에 도킹")
        }
    }

    var settingsDescription: String {
        switch self {
        case .displayMode:
            L10n.text("영역 선택 화면에서 미러/오버레이 모드를 전환합니다.")
        case .dockTop, .dockBottom, .dockLeft, .dockRight:
            L10n.text("영역 선택 화면에서 미러 도킹 방향을 지정합니다.")
        }
    }
}

extension ToolbarHotKey {
    static func defaultValue(selectionAction: SelectionShortcutAction) -> ToolbarHotKey {
        AppDefaults.selectionShortcut(for: selectionAction)
    }

    static func load(
        selectionAction: SelectionShortcutAction, from defaults: UserDefaults = .standard
    ) -> ToolbarHotKey {
        let prefix = "selectionShortcut.\(selectionAction.rawValue)"
        guard defaults.object(forKey: "\(prefix).keyCode") != nil,
              let label = defaults.string(forKey: "\(prefix).label"),
              !label.isEmpty else {
            return defaultValue(selectionAction: selectionAction)
        }
        return ToolbarHotKey(
            keyCode: UInt32(defaults.integer(forKey: "\(prefix).keyCode")),
            modifiers: 0,
            keyLabel: label,
            isEnabled: defaults.object(forKey: "\(prefix).enabled") == nil
                ? defaultValue(selectionAction: selectionAction).isEnabled
                : defaults.bool(forKey: "\(prefix).enabled")
        )
    }

    func save(
        selectionAction: SelectionShortcutAction, to defaults: UserDefaults = .standard
    ) {
        let prefix = "selectionShortcut.\(selectionAction.rawValue)"
        defaults.set(Int(keyCode), forKey: "\(prefix).keyCode")
        defaults.set(keyLabel, forKey: "\(prefix).label")
        defaults.set(isEnabled, forKey: "\(prefix).enabled")
    }
}

struct ConfiguredShortcut: Equatable, Sendable {
    let identifier: String
    let keyCode: UInt32
    let modifiers: UInt32
    let isEnabled: Bool
}

/// Returns whether a user-configurable shortcut can be assigned without
/// shadowing another app command or a standard text-editing command.
func isShortcutRegistrationAvailable(
    keyCode: UInt32,
    modifiers: UInt32,
    identifier: String,
    existing: [ConfiguredShortcut]
) -> Bool {
    guard !isReservedShortcut(keyCode: keyCode, modifiers: modifiers) else { return false }
    // Modifier-less single keys are reserved for the dedicated session-control
    // action so a bare key cannot shadow typing in other commands.
    if modifiers == 0
        && identifier != "toolbar.\(ToolbarShortcutAction.sessionControlSingleKey.rawValue)" {
        return false
    }
    return !existing.contains {
        $0.identifier != identifier && $0.isEnabled
            && $0.keyCode == keyCode && $0.modifiers == modifiers
    }
}

/// Keep keyboard equivalents that users expect to work in text fields and in
/// this app's menu out of the configurable shortcut pool.
func isReservedShortcut(keyCode: UInt32, modifiers: UInt32) -> Bool {
    let command = UInt32(cmdKey)
    let commandShift = UInt32(cmdKey | shiftKey)
    switch (keyCode, modifiers) {
    // Standard text editing commands without Rearview command equivalents.
    case (UInt32(kVK_ANSI_V), command),
         (UInt32(kVK_ANSI_Z), command),
         (UInt32(kVK_ANSI_Z), commandShift):
        return true
    default:
        return false
    }
}

func toolbarShortcutToolTip(
    _ description: String,
    action: ToolbarShortcutAction,
    defaults: UserDefaults = .standard
) -> String {
    let hotKey = ToolbarHotKey.load(action: action, from: defaults)
    guard hotKey.isEnabled else { return description }
    return "\(description)\n\(hotKey.title)"
}

func immediateTranslationHotKeyToolTip(
    _ description: String,
    defaults: UserDefaults = .standard
) -> String {
    let hotKey = ImmediateTranslationHotKey.load(from: defaults)
    guard hotKey.isEnabled else { return description }
    return "\(description)\n\(hotKey.title)"
}

func matchesLocalShortcut(
    eventKeyCode: UInt16, eventModifiers: NSEvent.ModifierFlags,
    shortcutKeyCode: UInt32, shortcutModifiers: UInt32
) -> Bool {
    var expected: NSEvent.ModifierFlags = []
    if shortcutModifiers & UInt32(controlKey) != 0 { expected.insert(.control) }
    if shortcutModifiers & UInt32(optionKey) != 0 { expected.insert(.option) }
    if shortcutModifiers & UInt32(shiftKey) != 0 { expected.insert(.shift) }
    if shortcutModifiers & UInt32(cmdKey) != 0 { expected.insert(.command) }
    let relevant: NSEvent.ModifierFlags = [.control, .option, .shift, .command]
    return UInt32(eventKeyCode) == shortcutKeyCode
        && eventModifiers.intersection(relevant) == expected
}

enum RefreshMode: String, Sendable {
    case automatic
    case manual

    static let defaultsKey = "refreshMode"

    static func load(from defaults: UserDefaults = .standard) -> RefreshMode {
        resolve(defaults.string(forKey: defaultsKey))
    }

    static func resolve(_ rawValue: String?) -> RefreshMode {
        rawValue.flatMap(Self.init(rawValue:)) ?? AppDefaults.refreshMode
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }
}

struct CaptureApplication: Equatable, Sendable {
    let processID: pid_t
    let bundleIdentifier: String
    let name: String
    var anchorWindowID: CGWindowID? = nil
    var anchorWindowFrame: CGRect? = nil
}

enum CaptureTarget: Equatable, Sendable {
    case allContent
    case application(CaptureApplication)
}

extension CaptureTarget {
    var application: CaptureApplication? {
        if case .application(let application) = self { return application }
        return nil
    }
}

enum MirrorUpdateStyle: String, CaseIterable, Sendable {
    case atomic
    case progressive

    static let defaultsKey = "mirrorUpdateStyle"

    var title: String {
        switch self {
        case .atomic: L10n.text("한 번에")
        case .progressive: L10n.text("점진 표시")
        }
    }

    static func load(from defaults: UserDefaults = .standard) -> MirrorUpdateStyle {
        resolve(defaults.string(forKey: defaultsKey))
    }

    static func resolve(_ rawValue: String?) -> MirrorUpdateStyle {
        rawValue.flatMap(MirrorUpdateStyle.init(rawValue:)) ?? AppDefaults.mirrorUpdateStyle
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }
}

enum TranslationDisplayMode: String, CaseIterable, Sendable {
    case mirror
    case overlay

    static let defaultsKey = "translationDisplayMode"

    var title: String {
        switch self {
        case .mirror: L10n.text("미러")
        case .overlay: L10n.text("오버레이")
        }
    }

    static func load(from defaults: UserDefaults = .standard) -> TranslationDisplayMode {
        resolve(defaults.string(forKey: defaultsKey))
    }

    static func resolve(_ rawValue: String?) -> TranslationDisplayMode {
        rawValue.flatMap(Self.init(rawValue:)) ?? AppDefaults.translationDisplayMode
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }
}

enum DisplayModeFocusBehavior: Sendable {
    /// Update the display without changing the user's current input window.
    case preserveKeyWindow
    /// Move keyboard input to the replacement display only when the outgoing
    /// translation display was already receiving keyboard input.
    case transferIfDisplayIsKeyWindow

    func shouldTransferFocus(isDisplayKeyWindow: Bool) -> Bool {
        self == .transferIfDisplayIsKeyWindow && isDisplayKeyWindow
    }
}

enum OverlayOpacity {
    static let defaultsKey = "overlayOpacity"
    static let defaultValue = AppDefaults.inactiveOverlayOpacity
    static let range: ClosedRange<CGFloat> = 0.1...1

    static func load(from defaults: UserDefaults = .standard) -> CGFloat {
        guard defaults.object(forKey: defaultsKey) != nil else { return defaultValue }
        return clamp(CGFloat(defaults.double(forKey: defaultsKey)))
    }

    static func save(_ value: CGFloat, to defaults: UserDefaults = .standard) {
        defaults.set(Double(clamp(value)), forKey: defaultsKey)
    }

    static func clamp(_ value: CGFloat) -> CGFloat {
        min(range.upperBound, max(range.lowerBound, value))
    }
}

enum OverlayActiveOpacity {
    static let defaultsKey = "overlayActiveOpacity"
    static let defaultValue = AppDefaults.activeOverlayOpacity
    static let range = OverlayOpacity.range

    static func load(from defaults: UserDefaults = .standard) -> CGFloat {
        guard defaults.object(forKey: defaultsKey) != nil else { return defaultValue }
        return clamp(CGFloat(defaults.double(forKey: defaultsKey)))
    }

    static func save(_ value: CGFloat, to defaults: UserDefaults = .standard) {
        defaults.set(Double(clamp(value)), forKey: defaultsKey)
    }

    static func clamp(_ value: CGFloat) -> CGFloat { OverlayOpacity.clamp(value) }
}

enum OverlayControlBarOpacity {
    static let defaultsKey = "overlayControlBarOpacity"
    static let defaultValue = AppDefaults.inactiveControlBarOpacity
    static let range: ClosedRange<CGFloat> = 0...1.0

    static func load(from defaults: UserDefaults = .standard) -> CGFloat {
        guard defaults.object(forKey: defaultsKey) != nil else { return defaultValue }
        return clamp(CGFloat(defaults.double(forKey: defaultsKey)))
    }

    static func save(_ value: CGFloat, to defaults: UserDefaults = .standard) {
        defaults.set(Double(clamp(value)), forKey: defaultsKey)
    }

    static func clamp(_ value: CGFloat) -> CGFloat {
        min(range.upperBound, max(range.lowerBound, value))
    }
}

enum OverlayControlBarActiveOpacity {
    static let defaultsKey = "overlayControlBarActiveOpacity"
    static let defaultValue = AppDefaults.activeControlBarOpacity
    static let range = OverlayControlBarOpacity.range

    static func load(from defaults: UserDefaults = .standard) -> CGFloat {
        guard defaults.object(forKey: defaultsKey) != nil else { return defaultValue }
        return clamp(CGFloat(defaults.double(forKey: defaultsKey)))
    }

    static func save(_ value: CGFloat, to defaults: UserDefaults = .standard) {
        defaults.set(Double(clamp(value)), forKey: defaultsKey)
    }

    static func clamp(_ value: CGFloat) -> CGFloat { OverlayControlBarOpacity.clamp(value) }
}

enum OverlayIgnoresMouseEvents {
    static let defaultsKey = "overlayIgnoresMouseEvents"
    static let defaultValue = AppDefaults.overlayIgnoresMouseEvents

    static func load(from defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: defaultsKey) != nil else { return defaultValue }
        return defaults.bool(forKey: defaultsKey)
    }

    static func save(_ enabled: Bool, to defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: defaultsKey)
    }
}

struct OverlayPresentationSettings: Equatable, Sendable {
    var inactiveContentOpacity: CGFloat
    var activeContentOpacity: CGFloat
    var inactiveControlBarOpacity: CGFloat
    var activeControlBarOpacity: CGFloat
    var regionBorderOpacity: CGFloat
    var ignoresMouseEvents: Bool

    static func load(from defaults: UserDefaults = .standard) -> Self {
        Self(
            inactiveContentOpacity: OverlayOpacity.load(from: defaults),
            activeContentOpacity: OverlayActiveOpacity.load(from: defaults),
            inactiveControlBarOpacity: OverlayControlBarOpacity.load(from: defaults),
            activeControlBarOpacity: OverlayControlBarActiveOpacity.load(from: defaults),
            regionBorderOpacity: RegionBorderOpacity.load(from: defaults),
            ignoresMouseEvents: OverlayIgnoresMouseEvents.load(from: defaults)
        )
    }

    func normalized() -> Self {
        Self(
            inactiveContentOpacity: OverlayOpacity.clamp(inactiveContentOpacity),
            activeContentOpacity: OverlayActiveOpacity.clamp(activeContentOpacity),
            inactiveControlBarOpacity: OverlayControlBarOpacity.clamp(
                inactiveControlBarOpacity
            ),
            activeControlBarOpacity: OverlayControlBarActiveOpacity.clamp(
                activeControlBarOpacity
            ),
            regionBorderOpacity: RegionBorderOpacity.clamp(regionBorderOpacity),
            ignoresMouseEvents: ignoresMouseEvents
        )
    }

    func save(to defaults: UserDefaults = .standard) {
        let value = normalized()
        OverlayOpacity.save(value.inactiveContentOpacity, to: defaults)
        OverlayActiveOpacity.save(value.activeContentOpacity, to: defaults)
        OverlayControlBarOpacity.save(value.inactiveControlBarOpacity, to: defaults)
        OverlayControlBarActiveOpacity.save(value.activeControlBarOpacity, to: defaults)
        RegionBorderOpacity.save(value.regionBorderOpacity, to: defaults)
        OverlayIgnoresMouseEvents.save(value.ignoresMouseEvents, to: defaults)
    }
}

func overlayAcceptsMouseEvents(
    selectionModeEnabled: Bool, ignoresMouseEvents: Bool
) -> Bool {
    selectionModeEnabled || !ignoresMouseEvents
}

enum MirrorBackgroundOpacity {
    static let defaultsKey = "mirrorBackgroundOpacity"
    static let defaultValue = AppDefaults.mirrorBackgroundOpacity

    static func load(from defaults: UserDefaults = .standard) -> CGFloat {
        guard defaults.object(forKey: defaultsKey) != nil else { return defaultValue }
        return clamp(CGFloat(defaults.double(forKey: defaultsKey)))
    }

    static func save(_ value: CGFloat, to defaults: UserDefaults = .standard) {
        defaults.set(Double(clamp(value)), forKey: defaultsKey)
    }

    static func clamp(_ value: CGFloat) -> CGFloat {
        min(1, max(0, value))
    }
}

enum RegionBorderOpacity {
    static let defaultsKey = "regionBorderOpacity"
    static let defaultValue = AppDefaults.regionBorderOpacity

    static func load(from defaults: UserDefaults = .standard) -> CGFloat {
        guard defaults.object(forKey: defaultsKey) != nil else { return defaultValue }
        return clamp(CGFloat(defaults.double(forKey: defaultsKey)))
    }

    static func save(_ value: CGFloat, to defaults: UserDefaults = .standard) {
        defaults.set(Double(clamp(value)), forKey: defaultsKey)
    }

    static func clamp(_ value: CGFloat) -> CGFloat {
        min(1, max(0, value))
    }
}

enum MirrorAlwaysOnTop {
    static let defaultsKey = "mirrorAlwaysOnTop"
    static func load(from defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: defaultsKey) == nil
            ? AppDefaults.mirrorAlwaysOnTop : defaults.bool(forKey: defaultsKey)
    }
    static func save(_ enabled: Bool, to defaults: UserDefaults = .standard) { defaults.set(enabled, forKey: defaultsKey) }
}

enum DebugFeatures {
    static let defaultsKey = "debugFeaturesEnabled"

#if LST_EXCLUDE_DEBUG_FEATURES
    static func load(from _: UserDefaults = .standard) -> Bool { false }
    static func save(_: Bool, to _: UserDefaults = .standard) {}
#else
    static func load(from defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: defaultsKey) == nil
            ? AppDefaults.debugFeaturesEnabled : defaults.bool(forKey: defaultsKey)
    }

    static func save(_ enabled: Bool, to defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: defaultsKey)
    }
#endif
}

enum MirrorFollowsSelectionSize {
    static let defaultsKey = "mirrorFollowsSelectionSize"

    static func load(from defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: defaultsKey) != nil else {
            return AppDefaults.mirrorFollowsSelectionSize
        }
        return defaults.bool(forKey: defaultsKey)
    }

    static func save(_ enabled: Bool, to defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: defaultsKey)
    }
}

enum LaunchAtLogin {
    static let defaultsKey = "launchAtLogin"
    static func load(from defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: defaultsKey) == nil
            ? AppDefaults.launchAtLogin : defaults.bool(forKey: defaultsKey)
    }
    static func save(_ enabled: Bool, to defaults: UserDefaults = .standard) { defaults.set(enabled, forKey: defaultsKey) }
}

enum TargetApplicationTracking {
    static let defaultsKey = "targetApplicationTracking"
    static func load(from defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: defaultsKey) == nil
            ? AppDefaults.targetApplicationTracking : defaults.bool(forKey: defaultsKey)
    }
    static func save(_ enabled: Bool, to defaults: UserDefaults = .standard) { defaults.set(enabled, forKey: defaultsKey) }
}

struct CapturePolicy: Equatable, Sendable {
    static let targetFPSKey = "captureTargetFPS"
    static let realtimeOCRIntervalMillisecondsKey = "realtimeOCRIntervalMilliseconds"
    static let defaultTargetFPS = AppDefaults.captureTargetFPS
    static let defaultRealtimeOCRIntervalMilliseconds = AppDefaults.realtimeOCRIntervalMilliseconds
    static let targetFPSRange = 1...30
    static let realtimeOCRIntervalMillisecondsRange = 100...2_000

    let targetFPS: Int
    let realtimeOCRIntervalMilliseconds: Int

    init(
        targetFPS: Int = defaultTargetFPS,
        realtimeOCRIntervalMilliseconds: Int = defaultRealtimeOCRIntervalMilliseconds
    ) {
        self.targetFPS = Self.targetFPSRange.clamp(targetFPS)
        self.realtimeOCRIntervalMilliseconds =
            Self.realtimeOCRIntervalMillisecondsRange.clamp(realtimeOCRIntervalMilliseconds)
    }

    var realtimeOCRInterval: Duration {
        .milliseconds(Int64(realtimeOCRIntervalMilliseconds))
    }

    static func load(from defaults: UserDefaults = .standard) -> CapturePolicy {
        CapturePolicy(
            targetFPS: defaults.object(forKey: targetFPSKey) == nil
                ? defaultTargetFPS : defaults.integer(forKey: targetFPSKey),
            realtimeOCRIntervalMilliseconds:
                defaults.object(forKey: realtimeOCRIntervalMillisecondsKey) == nil
                ? defaultRealtimeOCRIntervalMilliseconds
                : defaults.integer(forKey: realtimeOCRIntervalMillisecondsKey)
        )
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(targetFPS, forKey: Self.targetFPSKey)
        defaults.set(
            realtimeOCRIntervalMilliseconds,
            forKey: Self.realtimeOCRIntervalMillisecondsKey
        )
    }

    var deliveryInterval: Duration {
        .milliseconds(Int64((1_000.0 / Double(targetFPS)).rounded(.down)))
    }
}

enum OCRExecutionStrategy: String, CaseIterable, Sendable {
    case realtimeThenRefinement
    case refinementImmediately
    case realtimeImmediately

    var title: String {
        switch self {
        case .realtimeThenRefinement: "Realtime → Refinement"
        case .refinementImmediately: L10n.text("즉시 Refinement OCR")
        case .realtimeImmediately: L10n.text("즉시 Realtime OCR")
        }
    }
}

struct RefinementOCRPolicy: Equatable, Sendable {
    static let automaticStrategyKey = "ocr.automatic.strategy"
    static let manualStrategyKey = "ocr.manual.strategy"
    static let alwaysRunKey = "ocr.refinement.alwaysRun"
    static let confidenceThresholdKey = "ocr.refinement.confidenceThreshold"
    static let delayMillisecondsKey = "ocr.refinement.delayMilliseconds"
    static let defaultDelayMilliseconds = AppDefaults.refinementDelayMilliseconds
    static let delayMillisecondsRange = 0...5_000
    static let defaultConfidenceThreshold = AppDefaults.refinementConfidenceThreshold
    static let confidenceThresholdRange: ClosedRange<Float> = 0...1
    static let defaultAutomaticStrategy = AppDefaults.automaticOCRStrategy
    static let defaultManualStrategy = AppDefaults.manualOCRStrategy

    let automaticStrategy: OCRExecutionStrategy
    let manualStrategy: OCRExecutionStrategy
    let alwaysRun: Bool
    let confidenceThreshold: Float
    let delayMilliseconds: Int

    init(
        automaticStrategy: OCRExecutionStrategy = Self.defaultAutomaticStrategy,
        manualStrategy: OCRExecutionStrategy = Self.defaultManualStrategy,
        alwaysRun: Bool = AppDefaults.refinementAlwaysRuns,
        confidenceThreshold: Float = defaultConfidenceThreshold,
        delayMilliseconds: Int = defaultDelayMilliseconds
    ) {
        self.automaticStrategy = automaticStrategy
        self.manualStrategy = manualStrategy
        self.alwaysRun = alwaysRun
        self.confidenceThreshold = Self.confidenceThresholdRange.clamp(confidenceThreshold)
        self.delayMilliseconds = Self.delayMillisecondsRange.clamp(delayMilliseconds)
    }

    var delay: Duration { .milliseconds(Int64(delayMilliseconds)) }

    static func load(from defaults: UserDefaults = .standard) -> RefinementOCRPolicy {
        RefinementOCRPolicy(
            automaticStrategy: OCRExecutionStrategy(
                rawValue: defaults.string(forKey: automaticStrategyKey) ?? ""
            ) ?? defaultAutomaticStrategy,
            manualStrategy: OCRExecutionStrategy(
                rawValue: defaults.string(forKey: manualStrategyKey) ?? ""
            ) ?? defaultManualStrategy,
            alwaysRun: defaults.object(forKey: alwaysRunKey) == nil
                ? AppDefaults.refinementAlwaysRuns : defaults.bool(forKey: alwaysRunKey),
            confidenceThreshold: defaults.object(forKey: confidenceThresholdKey) == nil
                ? defaultConfidenceThreshold : defaults.float(forKey: confidenceThresholdKey),
            delayMilliseconds: defaults.object(forKey: delayMillisecondsKey) == nil
                ? defaultDelayMilliseconds : defaults.integer(forKey: delayMillisecondsKey)
        )
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(automaticStrategy.rawValue, forKey: Self.automaticStrategyKey)
        defaults.set(manualStrategy.rawValue, forKey: Self.manualStrategyKey)
        defaults.set(alwaysRun, forKey: Self.alwaysRunKey)
        defaults.set(confidenceThreshold, forKey: Self.confidenceThresholdKey)
        defaults.set(delayMilliseconds, forKey: Self.delayMillisecondsKey)
    }
}

enum OCRRecognitionLanguageChoice: String, CaseIterable, Sendable {
    case japaneseFirst
    case koreanFirst
    case unset
    static let defaultsKey = "ocr.recognitionLanguages"
    static let defaultChoice = AppDefaults.recognitionLanguageChoice
    var title: String {
        switch self {
        case .japaneseFirst: L10n.text("일본어 → 한국어 → 영어")
        case .koreanFirst: L10n.text("한국어 → 일본어 → 영어")
        case .unset: L10n.text("설정 안 함")
        }
    }
    var languages: [String]? {
        switch self {
        case .japaneseFirst: ["ja-JP", "ko-KR", "en-US"]
        case .koreanFirst: ["ko-KR", "ja-JP", "en-US"]
        case .unset: nil
        }
    }
    static func load(from defaults: UserDefaults = .standard) -> Self {
        Self(rawValue: defaults.string(forKey: defaultsKey) ?? "") ?? defaultChoice
    }
    func save(to defaults: UserDefaults = .standard) { defaults.set(rawValue, forKey: Self.defaultsKey) }
}

enum OCRRecognitionLevel: String, CaseIterable, Sendable {
    case accurate
    case fast
}

enum OCREngine: String, CaseIterable, Sendable {
    case text
    case document

    var title: String {
        switch self {
        case .text: "Text OCR"
        case .document: "Document OCR"
        }
    }

    static var availableCases: [Self] {
        if #available(macOS 26.0, *) { return allCases }
        return [.text]
    }
}

struct OCRSettings: Sendable, Equatable {
    enum Revision: String, CaseIterable, Sendable { case current = "Current", revision3 = "Revision 3" }
    let engine: OCREngine
    let recognitionLevel: OCRRecognitionLevel
    let minimumTextHeight: Float
    let revision: Revision
    let usesLanguageCorrection: Bool
    let automaticallyDetectsLanguage: Bool
    static let minimumTextHeightRange: ClosedRange<Float> = 0.001...0.05
    static let imageScaleRange: ClosedRange<Float> = 1.0...3.0
    static let defaultEngine = AppDefaults.ocrEngine
    static let defaultRecognitionLevel = AppDefaults.ocrRecognitionLevel
    static let defaultMinimumTextHeight = AppDefaults.ocrMinimumTextHeight
    static let defaultRevision = AppDefaults.ocrRevision
    static let defaultUsesLanguageCorrection = AppDefaults.ocrUsesLanguageCorrection
    static let defaultAutomaticallyDetectsLanguage = AppDefaults.ocrAutomaticallyDetectsLanguage

    init(engine: OCREngine = Self.defaultEngine,
         recognitionLevel: OCRRecognitionLevel = Self.defaultRecognitionLevel,
         minimumTextHeight: Float = Self.defaultMinimumTextHeight,
         revision: Revision = Self.defaultRevision,
         usesLanguageCorrection: Bool = Self.defaultUsesLanguageCorrection,
         automaticallyDetectsLanguage: Bool = Self.defaultAutomaticallyDetectsLanguage,
         imageScale: Float? = nil) {
        self.engine = engine
        self.recognitionLevel = recognitionLevel
        self.minimumTextHeight = Self.minimumTextHeightRange.clamp(minimumTextHeight)
        self.revision = revision
        self.usesLanguageCorrection = usesLanguageCorrection
        self.automaticallyDetectsLanguage = automaticallyDetectsLanguage
        self.imageScale = Self.imageScaleRange.clamp(
            imageScale ?? AppDefaults.realtimeOCRImageScale
        )
    }

    let imageScale: Float

    static func defaultImageScale(for mode: OCRMode) -> Float {
        mode == .refinement
            ? AppDefaults.refinementOCRImageScale : AppDefaults.realtimeOCRImageScale
    }

    static func defaultProfile(for mode: OCRMode) -> OCRSettings {
        OCRSettings(imageScale: defaultImageScale(for: mode))
    }

    static func load(mode: OCRMode, from defaults: UserDefaults = .standard) -> OCRSettings {
        let key = "ocr.\(mode.rawValue)."
        return OCRSettings(
            engine: defaultEngine,
            recognitionLevel: defaultRecognitionLevel,
            minimumTextHeight: (
                defaults.object(forKey: key + "minimumTextHeight") as? NSNumber
            )?.floatValue ?? defaultMinimumTextHeight,
            revision: defaultRevision,
            usesLanguageCorrection: (
                defaults.object(forKey: key + "languageCorrection") as? Bool
            ) ?? defaultUsesLanguageCorrection,
            automaticallyDetectsLanguage: (
                defaults.object(forKey: key + "autoLanguage") as? Bool
            ) ?? defaultAutomaticallyDetectsLanguage,
            imageScale: (
                defaults.object(forKey: key + "imageScale") as? NSNumber
            )?.floatValue ?? defaultImageScale(for: mode)
        )
    }

    func save(mode: OCRMode, to defaults: UserDefaults = .standard) {
        let key = "ocr.\(mode.rawValue)."
        defaults.set(Self.defaultEngine.rawValue, forKey: key + "engine")
        defaults.set(Self.defaultRecognitionLevel.rawValue, forKey: key + "level")
        defaults.set(minimumTextHeight, forKey: key + "minimumTextHeight")
        defaults.set(Self.defaultRevision.rawValue, forKey: key + "revision")
        defaults.set(usesLanguageCorrection, forKey: key + "languageCorrection")
        defaults.set(automaticallyDetectsLanguage, forKey: key + "autoLanguage")
        defaults.set(imageScale, forKey: key + "imageScale")
    }
}

private extension ClosedRange where Bound == Int {
    func clamp(_ value: Int) -> Int {
        Swift.min(upperBound, Swift.max(lowerBound, value))
    }
}

private extension ClosedRange where Bound == Float {
    func clamp(_ value: Float) -> Float { Swift.min(upperBound, Swift.max(lowerBound, value)) }
}

struct RecognizedTextFragment: Sendable, Equatable {
    let text: String
    /// Vision normalized coordinates, with a bottom-left origin.
    let normalizedRect: CGRect
}

struct RecognizedLine: Sendable, Identifiable {
    let id: UUID
    let sourceText: String
    /// Vision normalized coordinates, with a bottom-left origin.
    let normalizedRect: CGRect
    let confidence: Float
    let background: RGBAColor
    let foreground: RGBAColor
    let selectionFragments: [RecognizedTextFragment]
    let selectionGeometrySource: OCRSelectionGeometrySource?

    init(
        id: UUID = UUID(), sourceText: String, normalizedRect: CGRect,
        confidence: Float, background: RGBAColor, foreground: RGBAColor,
        selectionFragments: [RecognizedTextFragment] = [],
        selectionGeometrySource: OCRSelectionGeometrySource? = nil
    ) {
        self.id = id
        self.sourceText = sourceText
        self.normalizedRect = normalizedRect
        self.confidence = confidence
        self.background = background
        self.foreground = foreground
        self.selectionFragments = selectionFragments
        self.selectionGeometrySource = selectionGeometrySource
    }
}

enum MirrorItemPresentation: Sendable {
    case translated
    case selectionOnly
}

struct MirrorItem: Sendable, Identifiable {
    let id: UUID
    let translatedText: String
    let presentation: MirrorItemPresentation
    let normalizedRect: CGRect
    let background: RGBAColor
    let foreground: RGBAColor
    let sourceSelectionFragments: [RecognizedTextFragment]
    let selectionGeometrySource: OCRSelectionGeometrySource?

    init(
        id: UUID, translatedText: String, presentation: MirrorItemPresentation,
        normalizedRect: CGRect, background: RGBAColor, foreground: RGBAColor,
        sourceSelectionFragments: [RecognizedTextFragment] = [],
        selectionGeometrySource: OCRSelectionGeometrySource? = nil
    ) {
        self.id = id
        self.translatedText = translatedText
        self.presentation = presentation
        self.normalizedRect = normalizedRect
        self.background = background
        self.foreground = foreground
        self.sourceSelectionFragments = sourceSelectionFragments
        self.selectionGeometrySource = selectionGeometrySource
    }

    var isTranslated: Bool { presentation == .translated }
}

struct MirrorTranslation: Sendable {
    let frameID: UInt64
    let line: RecognizedLine
    let translatedText: String
}

func makeMirrorItems(
    frameID: UInt64, recognizedLines: [RecognizedLine], translations: [MirrorTranslation]
) -> [MirrorItem] {
    let translatedTextByLineID = Dictionary(
        uniqueKeysWithValues: translations.compactMap { result in
            result.frameID == frameID ? (result.line.id, result.translatedText) : nil
        }
    )
    return recognizedLines.map { line in
        let translatedText = translatedTextByLineID[line.id]
        let presentation: MirrorItemPresentation = translatedText == nil ? .selectionOnly : .translated
        return MirrorItem(
            id: line.id,
            translatedText: translatedText ?? line.sourceText,
            presentation: presentation,
            normalizedRect: line.normalizedRect,
            background: line.background,
            foreground: line.foreground,
            sourceSelectionFragments: line.selectionFragments,
            selectionGeometrySource: line.selectionGeometrySource
        )
    }
}

struct MirrorFrame {
    let image: CGImage
    let translatedItems: [MirrorItem]
    let ocrDebugItems: [OCRDebugItem]
    let frameID: UInt64

    init(image: CGImage, translatedItems: [MirrorItem], ocrDebugItems: [OCRDebugItem] = [], frameID: UInt64) {
        self.image = image
        self.translatedItems = translatedItems
        self.ocrDebugItems = ocrDebugItems
        self.frameID = frameID
    }
}

enum OCRDebugStatus: String, Sendable {
    case noCandidate = "No Candidate"
    case lowConfidence = "Low Confidence"
    case nonJapanese = "Non-Japanese"
    case translationPending = "Translation Pending"
    case translationFailed = "Translation Failed"
    case success = "Success"

    var title: String {
        switch self {
        case .noCandidate: L10n.text("후보 없음")
        case .lowConfidence: L10n.text("낮은 신뢰도")
        case .nonJapanese: L10n.text("비일본어")
        case .translationPending: L10n.text("번역 대기 중")
        case .translationFailed: L10n.text("번역 실패")
        case .success: L10n.text("성공")
        }
    }
}

struct OCRDebugItem: Sendable, Identifiable {
    let id: UUID
    let status: OCRDebugStatus
    let rawText: String?
    let confidence: Float?
    let recognitionLanguages: [String]
    let translatedText: String?
    let normalizedRect: CGRect

    init(id: UUID, status: OCRDebugStatus, rawText: String?, confidence: Float?,
         recognitionLanguages: [String] = [], translatedText: String? = nil,
         normalizedRect: CGRect) {
        self.id = id
        self.status = status
        self.rawText = rawText
        self.confidence = confidence
        self.recognitionLanguages = recognitionLanguages
        self.translatedText = translatedText
        self.normalizedRect = normalizedRect
    }
}

struct RGBAColor: Sendable, Equatable {
    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat
    let alpha: CGFloat

    var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    static let lightBackground = RGBAColor(red: 0.96, green: 0.96, blue: 0.96, alpha: 0.96)
    static let darkText = RGBAColor(red: 0.08, green: 0.08, blue: 0.08, alpha: 1)
}

enum TranslatorError: LocalizedError {
    case screenPermission
    case noDisplay
    case languageModelUnavailable
    case translationSessionUnavailable
    case invalidSelection
    case captureApplicationUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .screenPermission: L10n.text("화면 기록 권한이 필요합니다.")
        case .noDisplay: L10n.text("캡처할 디스플레이를 찾을 수 없습니다.")
        case .languageModelUnavailable: L10n.text("일본어·한국어 번역 언어팩을 설치해야 합니다.")
        case .translationSessionUnavailable: L10n.text("로컬 번역 세션을 준비하는 중입니다. 잠시 후 다시 시도하세요.")
        case .invalidSelection: L10n.text("한 모니터 안에서 충분한 크기의 영역을 선택하세요.")
        case .captureApplicationUnavailable(let name):
            L10n.format("캡처할 앱 ‘%@’을 찾을 수 없습니다. 앱이 실행 중인지 확인하세요.", name)
        }
    }
}
