import AppKit
import Carbon
import SwiftUI
import ServiceManagement
@preconcurrency import ScreenCaptureKit

@MainActor
struct ScreenCapturePermissionClient {
    let preflight: () -> Bool
    let probe: () async throws -> Void
    let openSystemSettings: () -> Bool

    static let live = ScreenCapturePermissionClient(
        preflight: { CGPreflightScreenCaptureAccess() },
        probe: {
            _ = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            )
        },
        openSystemSettings: {
            guard let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
            ) else { return false }
            return NSWorkspace.shared.open(url)
        }
    )
}

enum ScreenCapturePermissionConfirmation {
    static let defaultsKey = "screenCapturePermissionConfirmationShown"

    static func hasBeenShown(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: defaultsKey)
    }

    static func markShown(in defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: defaultsKey)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let permissionClient: ScreenCapturePermissionClient
    private let defaults: UserDefaults
    private let broker = TranslationBroker()
    private lazy var coordinator = SessionCoordinator(broker: broker)
    private let selector = ScreenSelectionController()
#if LST_EXCLUDE_DEBUG_FEATURES
    private let appUpdater: AppUpdater
#endif
    private var statusItem: NSStatusItem!
    private var selectionMenuItem: NSMenuItem?
    private var settingsMenuItem: NSMenuItem?
    private var debugMenuItems: [NSMenuItem] = []
    private var debugMenuSeparator: NSMenuItem?
    private var translationHost: NSPanel?
    private var hotKeyRef: EventHotKeyRef?
    private var immediateTranslationHotKeyRef: EventHotKeyRef?
    private var mirrorActivationHotKeyRef: EventHotKeyRef?
    private var benchmarkHotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var localShortcutMonitor: Any?
    private var summaryWindow: ProfileSummaryWindowController?
    private var settingsWindow: SettingsWindowController?
    private var benchmarkProcess: Process?
    private var mirrorUpdateStyle = MirrorUpdateStyle.load()
    private var selectionHotKey = SelectionHotKey.load()
    private var immediateTranslationHotKey = ImmediateTranslationHotKey.load()
    private var mirrorActivationHotKey = MirrorActivationHotKey.load()
    private var toolbarHotKeys: [ToolbarShortcutAction: ToolbarHotKey] = Dictionary(
        uniqueKeysWithValues: ToolbarShortcutAction.configurableActions.map {
            ($0, ToolbarHotKey.load(action: $0))
        }
    )
    private var hotKeyRecording = false
    private var permissionIntroductionWindow: ScreenCapturePermissionWindowController?
    private var permissionRecoveryWindow: ScreenCapturePermissionWindowController?
    private var permissionCheckTask: Task<Void, Never>?
    private var permissionCheckGeneration: UInt = 0
    private var hasInstalledApplicationServices = false
    private var screenCapturePermissionGranted = false

    init(
        permissionClient: ScreenCapturePermissionClient = .live,
        defaults: UserDefaults = .standard
    ) {
        self.permissionClient = permissionClient
        self.defaults = defaults
#if LST_EXCLUDE_DEBUG_FEATURES
        self.appUpdater = AppUpdater()
#endif
        super.init()
#if LST_EXCLUDE_DEBUG_FEATURES
        appUpdater.onStateChange = { [weak self] _ in
            self?.rebuildStatusMenu()
        }
        appUpdater.onSettingsChange = { [weak self] _ in
            self?.settingsWindow?.refresh()
        }
#endif
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if permissionClient.preflight() {
            startScreenCapturePermissionProbe()
        } else {
            showPermissionIntroductionWindow()
        }
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        guard !screenCapturePermissionGranted else { return true }
        presentCurrentPermissionGate()
        return true
    }

    private func installApplicationServices() {
        guard !hasInstalledApplicationServices else {
            screenCapturePermissionGranted = true
            return
        }
        hasInstalledApplicationServices = true
        screenCapturePermissionGranted = true
        installTranslationHost()
        installStatusItem()
        installHotKey()
        installLocalShortcutMonitor()
#if LST_EXCLUDE_DEBUG_FEATURES
        appUpdater.startIfConfigured()
#endif
#if !LST_EXCLUDE_DEBUG_FEATURES
        if CommandLine.arguments.contains("--benchmark") {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                await self?.runBenchmarkSession()
            }
        }
#endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let immediateTranslationHotKeyRef { UnregisterEventHotKey(immediateTranslationHotKeyRef) }
        if let mirrorActivationHotKeyRef { UnregisterEventHotKey(mirrorActivationHotKeyRef) }
        if let benchmarkHotKeyRef { UnregisterEventHotKey(benchmarkHotKeyRef) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
        if let localShortcutMonitor { NSEvent.removeMonitor(localShortcutMonitor) }
        permissionCheckGeneration &+= 1
        permissionCheckTask?.cancel()
        selector.cancel()
    }

    private func installTranslationHost() {
        let panel = NSPanel(
            contentRect: CGRect(x: -10_000, y: -10_000, width: 1, height: 1),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = NSHostingView(rootView: TranslationBridgeView(broker: broker))
        panel.alphaValue = 0.01
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
        panel.orderBack(nil)
        translationHost = panel
    }

    private func installStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        rebuildStatusMenu()
    }

    private func statusItemImage() -> NSImage {
        let fallback = NSImage(
            systemSymbolName: "character.bubble",
            accessibilityDescription: L10n.text("화면 번역")
        ) ?? NSImage()

        guard
            let url = Bundle.main.url(forResource: "Rearview", withExtension: "svg"),
            let image = NSImage(contentsOf: url)
        else {
            assertionFailure("Rearview.svg is missing from the application bundle")
            return fallback
        }

        image.isTemplate = true
        let height: CGFloat = 18
        image.size = NSSize(
            width: height * image.size.width / image.size.height,
            height: height
        )
        return image
    }

    private func rebuildStatusMenu() {
        statusItem.button?.image = statusItemImage()
        let menu = NSMenu()
        let selectionItem = menu.addItem(
            withTitle: L10n.text("영역 선택…"),
            action: #selector(beginSelection), keyEquivalent: ""
        )
        selectionMenuItem = selectionItem
        settingsMenuItem = menu.addItem(
            withTitle: L10n.text("설정…"), action: #selector(showSettings),
            keyEquivalent: ""
        )
#if LST_EXCLUDE_DEBUG_FEATURES
        appUpdater.addCheckForUpdatesItem(to: menu)
#endif
        updateStatusMenuShortcuts()
#if !LST_EXCLUDE_DEBUG_FEATURES
        let separator = NSMenuItem.separator()
        debugMenuSeparator = separator
        menu.addItem(separator)
        debugMenuItems = [
            menu.addItem(withTitle: L10n.text("프로파일링 시작"), action: #selector(startProfiling), keyEquivalent: ""),
            menu.addItem(withTitle: L10n.text("프로파일링 종료 및 결과 보기"), action: #selector(stopProfiling), keyEquivalent: ""),
            menu.addItem(withTitle: L10n.text("최근 프로파일 결과 보기"), action: #selector(showRecentProfile), keyEquivalent: ""),
            menu.addItem(withTitle: L10n.text("내장 벤치마크 실행 (30초)"), action: #selector(runBenchmark), keyEquivalent: "")
        ]
        setDebugMenuItemsVisible(DebugFeatures.load())
#endif
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.text("종료"), action: #selector(quit), keyEquivalent: "")
        menu.items.forEach { item in
            if item.target == nil { item.target = self }
        }
        statusItem.menu = menu
    }

    private func installHotKey() {
        let signature = OSType(0x4C535452) // LSTR
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: OSType(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return noErr }
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            Task { @MainActor in
                guard !delegate.selector.isSelecting else { return }
                guard delegate.screenCapturePermissionGranted else {
                    delegate.presentCurrentPermissionGate()
                    return
                }
                if hotKeyID.id == 1 { delegate.beginSelection() }
                if hotKeyID.id == 2, DebugFeatures.load() { delegate.runBenchmark() }
                if hotKeyID.id == 3 { delegate.coordinator.translateImmediately() }
                if hotKeyID.id == 4 { delegate.coordinator.activateMirrorWindow() }
            }
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        if selectionHotKey.isEnabled { _ = registerSelectionHotKey(selectionHotKey) }
        if immediateTranslationHotKey.isEnabled { _ = registerImmediateTranslationHotKey(immediateTranslationHotKey) }
        if mirrorActivationHotKey.isEnabled { _ = registerFixedHotKey(
            keyCode: mirrorActivationHotKey.keyCode, modifiers: mirrorActivationHotKey.modifiers, id: 4,
            reference: &mirrorActivationHotKeyRef
        ) }
        let benchmarkHotKeyID = EventHotKeyID(signature: signature, id: 2)
        RegisterEventHotKey(UInt32(kVK_ANSI_B), UInt32(controlKey | optionKey), benchmarkHotKeyID,
                            GetApplicationEventTarget(), 0, &benchmarkHotKeyRef)

    }

    private func installLocalShortcutMonitor() {
        localShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            guard let self, NSApp.isActive, !self.hotKeyRecording, !self.selector.isSelecting
            else { return event }
            if self.handleFixedShortcut(event) { return nil }
            if self.handleToolbarShortcut(event) { return nil }
            return event
        }
    }

    /// Keeps the standard close command for the settings window independent of
    /// the configurable translation-session commands.
    private func handleFixedShortcut(_ event: NSEvent) -> Bool {
        let relevant: NSEvent.ModifierFlags = [.control, .option, .shift, .command]
        guard event.modifierFlags.intersection(relevant) == [.command],
              let character = event.charactersIgnoringModifiers?.lowercased()
        else { return false }

        let keyWindow = NSApp.keyWindow
        if keyWindow === settingsWindow?.window {
            if character == "w" {
                settingsWindow?.close()
                return true
            }
            return false
        }
        return false
    }

    private func keyWindowHasEditableTextResponder(_ window: NSWindow?) -> Bool {
        guard let textView = window?.firstResponder as? NSTextView else { return false }
        return textView.isEditable
    }

    /// Blocks the single-key session control while any text view (including a
    /// non-editable selection or search result view) is the first responder, so
    /// Space keeps its standard scrolling and editing behavior there.
    private func keyWindowHasTextViewResponder(_ window: NSWindow?) -> Bool {
        window?.firstResponder is NSTextView
    }

    private func handleToolbarShortcut(_ event: NSEvent) -> Bool {
        guard let action = toolbarHotKeys.first(where: { entry in
            entry.value.isEnabled && matchesLocalShortcut(
                eventKeyCode: event.keyCode,
                eventModifiers: event.modifierFlags,
                shortcutKeyCode: entry.value.keyCode,
                shortcutModifiers: entry.value.modifiers
            )
        })?.key else { return false }
        guard screenCapturePermissionGranted else {
            presentCurrentPermissionGate()
            return true
        }
        switch action {
        case .openSettings:
            showSettings()
        case .stopTranslation:
            guard coordinator.isTranslationSessionKeyWindow(NSApp.keyWindow) else { return false }
            Task { @MainActor [weak self] in await self?.coordinator.stop() }
        case .applicationCapture:
            guard coordinator.isTranslationSessionKeyWindow(NSApp.keyWindow) else { return false }
            coordinator.showApplicationCapturePopup()
        case .translationDirection:
            coordinator.setTranslationDirection(coordinator.currentTranslationDirection.toggled)
        case .protectNonSourceText:
            coordinator.setProtectsNonSourceText(!coordinator.currentProtectsNonSourceText)
        case .displayMode:
            coordinator.setDisplayMode(
                TranslationDisplayMode.load() == .mirror ? .overlay : .mirror,
                focusBehavior: .transferIfDisplayIsKeyWindow
            )
        case .refreshMode:
            coordinator.setRefreshMode(
                coordinator.currentRefreshMode == .automatic ? .manual : .automatic
            )
        case .sessionControlSingleKey:
            // The bare single key must not fire while the user is typing or
            // holding the key, and only reacts when a session window is key.
            guard !event.isARepeat,
                  coordinator.isSessionActive,
                  coordinator.isTranslationSessionKeyWindow(NSApp.keyWindow),
                  !keyWindowHasTextViewResponder(NSApp.keyWindow) else { return false }
            if coordinator.currentRefreshMode == .automatic {
                coordinator.setPaused(!coordinator.isPaused)
            } else {
                coordinator.translateImmediately()
            }
        case .selectAll, .copySelection, .copyAndClearSelection:
            guard coordinator.isTranslationSessionKeyWindow(NSApp.keyWindow),
                  !keyWindowHasEditableTextResponder(NSApp.keyWindow) else { return false }
            let character: String
            switch action {
            case .selectAll: character = "a"
            case .copySelection: character = "c"
            case .copyAndClearSelection: character = "x"
            default: fatalError("Unexpected text shortcut action")
            }
            return coordinator.performTranslationTextShortcut(character)
        case .copyAll:
            coordinator.copyAllText()
        case .copyImage:
            coordinator.copyImage()
        case .saveImage:
            coordinator.saveImage()
        case .search:
            guard coordinator.isTranslationSessionKeyWindow(NSApp.keyWindow) else { return false }
            coordinator.showSearch()
        case .selectionMode:
            coordinator.toggleSelectionMode()
        case .modeSpecificDisplayControl:
            coordinator.toggleModeSpecificDisplayControl()
        case .zoomOut:
            coordinator.scaleMirrorContent(by: 1 / 1.1)
        case .zoomActual:
            coordinator.restoreMirrorContentSize()
        case .zoomIn:
            coordinator.scaleMirrorContent(by: 1.1)
        case .fitWindowToContent:
            coordinator.fitMirrorWindowToContent()
        case .followSelectionSize:
            let enabled = !coordinator.isMirrorFollowsSelectionSize
            coordinator.setMirrorFollowsSelectionSize(enabled)
            MirrorFollowsSelectionSize.save(enabled)
        case .dockTop:
            guard coordinator.isTranslationSessionKeyWindow(NSApp.keyWindow),
                  TranslationDisplayMode.load() == .mirror else { return false }
            coordinator.toggleMirrorDocking(.top)
        case .dockBottom:
            guard coordinator.isTranslationSessionKeyWindow(NSApp.keyWindow),
                  TranslationDisplayMode.load() == .mirror else { return false }
            coordinator.toggleMirrorDocking(.bottom)
        case .dockLeft:
            guard coordinator.isTranslationSessionKeyWindow(NSApp.keyWindow),
                  TranslationDisplayMode.load() == .mirror else { return false }
            coordinator.toggleMirrorDocking(.left)
        case .dockRight:
            guard coordinator.isTranslationSessionKeyWindow(NSApp.keyWindow),
                  TranslationDisplayMode.load() == .mirror else { return false }
            coordinator.toggleMirrorDocking(.right)
        case .debugOverlay:
            coordinator.toggleOCRDebugOverlay()
        }
        return true
    }

    private func registerFixedHotKey(
        keyCode: UInt32, modifiers: UInt32, id: UInt32,
        reference: inout EventHotKeyRef?
    ) -> Bool {
        var newReference: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4C535452), id: id)
        let status = RegisterEventHotKey(
            keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &newReference
        )
        guard status == noErr, let newReference else { return false }
        if let reference { UnregisterEventHotKey(reference) }
        reference = newReference
        return true
    }

    private func registerImmediateTranslationHotKey(_ hotKey: ImmediateTranslationHotKey) -> Bool {
        var newReference: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4C535452), id: 3)
        let status = RegisterEventHotKey(
            hotKey.keyCode, hotKey.modifiers, hotKeyID,
            GetApplicationEventTarget(), 0, &newReference
        )
        guard status == noErr, let newReference else { return false }
        if let immediateTranslationHotKeyRef { UnregisterEventHotKey(immediateTranslationHotKeyRef) }
        immediateTranslationHotKeyRef = newReference
        immediateTranslationHotKey = hotKey
        return true
    }

    private func registerSelectionHotKey(_ hotKey: SelectionHotKey) -> Bool {
        var newReference: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4C535452), id: 1)
        let status = RegisterEventHotKey(
            hotKey.keyCode, hotKey.modifiers, hotKeyID,
            GetApplicationEventTarget(), 0, &newReference
        )
        guard status == noErr, let newReference else { return false }
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = newReference
        selectionHotKey = hotKey
        updateSelectionMenuShortcut()
        return true
    }

    private func updateSelectionMenuShortcut() {
        guard let selectionMenuItem else { return }
        applyMenuShortcut(selectionHotKey, to: selectionMenuItem)
    }

    private func updateStatusMenuShortcuts() {
        updateSelectionMenuShortcut()
        if let settingsMenuItem {
            applyMenuShortcut(
                toolbarHotKeys[.openSettings]
                    ?? ToolbarHotKey.load(action: .openSettings),
                to: settingsMenuItem
            )
        }
    }

    private func setHotKeyRecording(_ recording: Bool) {
        guard hotKeyRecording != recording else { return }
        hotKeyRecording = recording
        if recording {
            [hotKeyRef, immediateTranslationHotKeyRef, mirrorActivationHotKeyRef,
             benchmarkHotKeyRef].compactMap { $0 }.forEach {
                UnregisterEventHotKey($0)
            }
            hotKeyRef = nil; immediateTranslationHotKeyRef = nil
            mirrorActivationHotKeyRef = nil; benchmarkHotKeyRef = nil
        } else {
            if selectionHotKey.isEnabled { _ = registerSelectionHotKey(selectionHotKey) }
            if immediateTranslationHotKey.isEnabled { _ = registerImmediateTranslationHotKey(immediateTranslationHotKey) }
            if mirrorActivationHotKey.isEnabled { _ = registerFixedHotKey(keyCode: mirrorActivationHotKey.keyCode, modifiers: mirrorActivationHotKey.modifiers, id: 4, reference: &mirrorActivationHotKeyRef) }
        }
    }

    private func shortcutRegistrationIsAvailable(
        keyCode: UInt32, modifiers: UInt32, excluding identifier: String
    ) -> Bool {
        let globalShortcuts = [
            ConfiguredShortcut(identifier: "selection", keyCode: selectionHotKey.keyCode,
                               modifiers: selectionHotKey.modifiers, isEnabled: selectionHotKey.isEnabled),
            ConfiguredShortcut(identifier: "immediateTranslation", keyCode: immediateTranslationHotKey.keyCode,
                               modifiers: immediateTranslationHotKey.modifiers, isEnabled: immediateTranslationHotKey.isEnabled),
            ConfiguredShortcut(identifier: "mirrorActivation", keyCode: mirrorActivationHotKey.keyCode,
                               modifiers: mirrorActivationHotKey.modifiers, isEnabled: mirrorActivationHotKey.isEnabled),
        ]
        let toolbarShortcuts = toolbarHotKeys.map { action, hotKey in
            ConfiguredShortcut(identifier: "toolbar.\(action.rawValue)", keyCode: hotKey.keyCode,
                               modifiers: hotKey.modifiers, isEnabled: hotKey.isEnabled)
        }
        return isShortcutRegistrationAvailable(
            keyCode: keyCode, modifiers: modifiers, identifier: identifier,
            existing: globalShortcuts + toolbarShortcuts
        )
    }

    private func changeToolbarHotKey(
        _ action: ToolbarShortcutAction, _ hotKey: ToolbarHotKey
    ) -> Bool {
        guard shortcutRegistrationIsAvailable(
            keyCode: hotKey.keyCode, modifiers: hotKey.modifiers,
            excluding: "toolbar.\(action.rawValue)"
        ) else {
            return false
        }
        toolbarHotKeys[action] = hotKey
        hotKey.save(action: action)
        updateStatusMenuShortcuts()
        coordinator.refreshShortcutToolTips()
        return true
    }

    private func removeToolbarHotKey(_ action: ToolbarShortcutAction) -> Bool {
        let disabled = ToolbarHotKey(
            keyCode: toolbarHotKeys[action]?.keyCode ?? 0,
            modifiers: toolbarHotKeys[action]?.modifiers ?? 0,
            keyLabel: toolbarHotKeys[action]?.keyLabel ?? "",
            isEnabled: false
        )
        toolbarHotKeys[action] = disabled
        disabled.save(action: action)
        updateStatusMenuShortcuts()
        coordinator.refreshShortcutToolTips()
        return true
    }

    /// Records a selection-screen single key. Rejects `Esc` (reserved for
    /// cancel) and duplicates of the other selection keys.
    private func changeSelectionShortcut(
        _ action: SelectionShortcutAction, _ hotKey: ToolbarHotKey
    ) -> Bool {
        if hotKey.keyCode == UInt32(kVK_Escape) { return false }
        for other in SelectionShortcutAction.allCases where other != action {
            let existing = ToolbarHotKey.load(selectionAction: other)
            if existing.isEnabled && existing.keyCode == hotKey.keyCode { return false }
        }
        hotKey.save(selectionAction: action)
        return true
    }

    private func removeSelectionShortcut(_ action: SelectionShortcutAction) -> Bool {
        let current = ToolbarHotKey.load(selectionAction: action)
        let disabled = ToolbarHotKey(
            keyCode: current.keyCode, modifiers: 0,
            keyLabel: current.keyLabel, isEnabled: false
        )
        disabled.save(selectionAction: action)
        return true
    }

    private func removeSelectionHotKey() -> Bool {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref); hotKeyRef = nil }
        selectionHotKey = SelectionHotKey(keyCode: selectionHotKey.keyCode, modifiers: selectionHotKey.modifiers, keyLabel: selectionHotKey.keyLabel, isEnabled: false)
        selectionHotKey.save(); updateSelectionMenuShortcut(); return true
    }

    private func removeImmediateTranslationHotKey() -> Bool {
        if let ref = immediateTranslationHotKeyRef { UnregisterEventHotKey(ref); immediateTranslationHotKeyRef = nil }
        immediateTranslationHotKey = ImmediateTranslationHotKey(keyCode: immediateTranslationHotKey.keyCode, modifiers: immediateTranslationHotKey.modifiers, keyLabel: immediateTranslationHotKey.keyLabel, isEnabled: false)
        immediateTranslationHotKey.save(); return true
    }

    private func removeMirrorActivationHotKey() -> Bool {
        if let ref = mirrorActivationHotKeyRef { UnregisterEventHotKey(ref); mirrorActivationHotKeyRef = nil }
        mirrorActivationHotKey = MirrorActivationHotKey(keyCode: mirrorActivationHotKey.keyCode, modifiers: mirrorActivationHotKey.modifiers, keyLabel: mirrorActivationHotKey.keyLabel, isEnabled: false)
        mirrorActivationHotKey.save(); return true
    }

    private func changeSelectionHotKey(_ hotKey: SelectionHotKey) -> Bool {
        guard hotKey != selectionHotKey else { return true }
        guard shortcutRegistrationIsAvailable(
            keyCode: hotKey.keyCode, modifiers: hotKey.modifiers, excluding: "selection"
        ) else { return false }
        guard registerSelectionHotKey(hotKey) else { return false }
        hotKey.save()
        return true
    }

    private func changeImmediateTranslationHotKey(_ hotKey: ImmediateTranslationHotKey) -> Bool {
        guard hotKey != immediateTranslationHotKey else { return true }
        guard shortcutRegistrationIsAvailable(
            keyCode: hotKey.keyCode, modifiers: hotKey.modifiers,
            excluding: "immediateTranslation"
        ) else { return false }
        guard registerImmediateTranslationHotKey(hotKey) else { return false }
        hotKey.save()
        return true
    }

    private func changeMirrorActivationHotKey(_ hotKey: MirrorActivationHotKey) -> Bool {
        guard hotKey != mirrorActivationHotKey else { return true }
        guard shortcutRegistrationIsAvailable(
            keyCode: hotKey.keyCode, modifiers: hotKey.modifiers,
            excluding: "mirrorActivation"
        ) else { return false }
        guard registerFixedHotKey(keyCode: hotKey.keyCode, modifiers: hotKey.modifiers, id: 4, reference: &mirrorActivationHotKeyRef) else { return false }
        mirrorActivationHotKey = hotKey
        hotKey.save()
        return true
    }

    @objc func beginSelection() {
        guard screenCapturePermissionGranted else {
            presentCurrentPermissionGate()
            return
        }

        // During selection the mode toggle and docking directions use their
        // own single-key shortcuts (no modifier), configured in the settings.
        let dockingShortcuts = Dictionary(uniqueKeysWithValues: MirrorDockingState.allCases.compactMap {
            state in state.selectionShortcutAction.map { (state, ToolbarHotKey.load(selectionAction: $0)) }
        })
        let displayModeShortcut = ToolbarHotKey.load(selectionAction: .displayMode)
        // No session exists yet, so the selection border can only reflect the
        // persisted refresh mode (manual = purple, otherwise automatic) and
        // the region border opacity setting.
        let presentationState: RegionBorderController.PresentationState =
            RefreshMode.load() == .manual ? .manual : .automatic
        self.selector.select(
            displayMode: TranslationDisplayMode.load(),
            dockingShortcuts: dockingShortcuts,
            displayModeShortcut: displayModeShortcut,
            presentationState: presentationState,
            regionBorderOpacity: RegionBorderOpacity.load()
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let selectionResult):
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.coordinator.stop()
                    // Start in the display mode the user settled on during
                    // selection (also persists it for the next session).
                    self.coordinator.setDisplayMode(
                        selectionResult.displayMode,
                        focusBehavior: .preserveKeyWindow
                    )
                    do {
                        try await self.coordinator.start(
                            screen: selectionResult.screen,
                            selection: selectionResult.selection,
                            initialDockingState: selectionResult.initialDockingState,
                            mirrorUpdateStyle: self.mirrorUpdateStyle
                        )
                    }
                    catch {
                        if !(error is CancellationError) { self.show(error: error) }
                    }
                }
            case .failure(let error):
                if !(error is CancellationError) { self.show(error: error) }
            }
        }
    }

    private func selectMirrorUpdateStyle(_ style: MirrorUpdateStyle) {
        guard mirrorUpdateStyle != style else { return }
        mirrorUpdateStyle = style
        style.save()
        Task { await coordinator.setMirrorUpdateStyle(style) }
    }

    @objc private func showSettings() {
        let controller: SettingsWindowController
        if let settingsWindow {
            controller = settingsWindow
        } else {
            controller = SettingsWindowController()
            controller.onSettingsReset = { [weak self] in self?.applyResetSettings() }
#if LST_EXCLUDE_DEBUG_FEATURES
            controller.updateSettingsProvider = { [weak self] in
                self?.appUpdater.settingsSnapshot ?? .defaults
            }
            controller.onAutomaticChecksChange = { [weak self] enabled in
                self?.appUpdater.setAutomaticallyChecksForUpdates(enabled)
            }
            controller.onAutomaticDownloadsChange = { [weak self] enabled in
                self?.appUpdater.setAutomaticallyDownloadsUpdates(enabled)
            }
#endif
            controller.onDebugFeaturesChange = { [weak self] enabled in self?.setDebugFeaturesEnabled(enabled) }
            controller.onMirrorBackgroundOpacityChange = { [weak self] opacity in self?.coordinator.setMirrorBackgroundOpacity(opacity) }
            controller.onDisplayModeChange = { [weak self] mode in
                self?.coordinator.setDisplayMode(mode)
            }
            controller.onDisplayLanguageChange = { [weak self] language in
                Task { @MainActor [weak self] in self?.applyDisplayLanguage(language) }
            }
            controller.onTranslationDirectionChange = { [weak self] direction in
                self?.coordinator.setTranslationDirection(direction)
            }
            controller.onNonSourceTextProtectionChange = { [weak self] enabled in
                self?.coordinator.setProtectsNonSourceText(enabled)
            }
            controller.onOverlayOpacityChange = { [weak self] opacity in
                self?.coordinator.setOverlayOpacity(opacity)
            }
            controller.onActiveOverlayOpacityChange = { [weak self] opacity in
                self?.coordinator.setActiveOverlayOpacity(opacity)
            }
            controller.onOverlayControlBarOpacityChange = { [weak self] opacity in
                self?.coordinator.setOverlayControlBarOpacity(opacity)
            }
            controller.onActiveOverlayControlBarOpacityChange = { [weak self] opacity in
                self?.coordinator.setActiveOverlayControlBarOpacity(opacity)
            }
            controller.onOverlayMouseEventIgnoringChange = { [weak self] enabled in
                self?.coordinator.setOverlayIgnoresMouseEvents(enabled)
            }
            controller.onRegionBorderOpacityChange = { [weak self] opacity in self?.coordinator.setRegionBorderOpacity(opacity) }
            controller.onMirrorAlwaysOnTopChange = { [weak self] enabled in self?.coordinator.setMirrorAlwaysOnTop(enabled) }
            controller.onMirrorFollowSelectionSizeChange = { [weak self] enabled in
                self?.coordinator.setMirrorFollowsSelectionSize(enabled)
            }
            controller.onTargetApplicationTrackingChange = { [weak self] enabled in
                self?.coordinator.setTargetApplicationTracking(enabled)
            }
            controller.onLaunchAtLoginChange = { [weak self] enabled in
                self?.setLaunchAtLogin(enabled) ?? false
            }
            controller.onMirrorUpdateStyleChange = { [weak self] style in
                self?.selectMirrorUpdateStyle(style)
            }
            controller.onSelectionHotKeyChange = { [weak self] hotKey in
                self?.changeSelectionHotKey(hotKey) ?? false
            }
            controller.onImmediateTranslationHotKeyChange = { [weak self] hotKey in
                self?.changeImmediateTranslationHotKey(hotKey) ?? false
            }
            controller.onMirrorActivationHotKeyChange = { [weak self] hotKey in
                self?.changeMirrorActivationHotKey(hotKey) ?? false
            }
            controller.onHotKeyRecordingChange = { [weak self] recording in
                self?.setHotKeyRecording(recording)
            }
            controller.onSelectionHotKeyRemove = { [weak self] in self?.removeSelectionHotKey() ?? false }
            controller.onImmediateTranslationHotKeyRemove = { [weak self] in self?.removeImmediateTranslationHotKey() ?? false }
            controller.onMirrorActivationHotKeyRemove = { [weak self] in self?.removeMirrorActivationHotKey() ?? false }
            controller.onToolbarHotKeyChange = { [weak self] action, hotKey in
                self?.changeToolbarHotKey(action, hotKey) ?? false
            }
            controller.onToolbarHotKeyRemove = { [weak self] action in
                self?.removeToolbarHotKey(action) ?? false
            }
            controller.onSelectionShortcutChange = { [weak self] action, hotKey in
                self?.changeSelectionShortcut(action, hotKey) ?? false
            }
            controller.onSelectionShortcutRemove = { [weak self] action in
                self?.removeSelectionShortcut(action) ?? false
            }
            controller.onCapturePolicyChange = { [weak self] policy in
                Task { await self?.coordinator.setCapturePolicy(policy) }
            }
            controller.onOCRSettingsChange = { [weak self] mode, settings in
                self?.coordinator.setOCRSettings(settings, mode: mode)
            }
            controller.onRefinementOCRPolicyChange = { [weak self] policy in
                self?.coordinator.setRefinementOCRPolicy(policy)
            }
            coordinator.onDisplayModeChange = { [weak controller] _ in controller?.refresh() }
            coordinator.onTranslationDirectionChange = { [weak controller] _ in controller?.refresh() }
            coordinator.onNonSourceTextProtectionChange = { [weak controller] _ in controller?.refresh() }
            coordinator.onOverlayPresentationChange = { [weak controller] in
                controller?.refresh()
            }
            settingsWindow = controller
            coordinator.onOpenSettings = { [weak self] in self?.showSettings() }
        }
        controller.refresh()
        controller.showWindow(nil)
        controller.window?.center()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func setDebugMenuItemsVisible(_ visible: Bool) {
        debugMenuSeparator?.isHidden = !visible
        debugMenuItems.forEach { $0.isHidden = !visible }
    }

    private func applyDisplayLanguage(
        _ language: AppDisplayLanguage,
        persistSelection: Bool = true
    ) {
        if persistSelection { language.save() }
        rebuildStatusMenu()
        coordinator.refreshLocalization()
        summaryWindow?.refreshLocalization()
        permissionIntroductionWindow?.refreshLocalization()
        permissionRecoveryWindow?.refreshLocalization()

        let shouldReopenSettings = settingsWindow?.window?.isVisible == true
        settingsWindow?.close()
        settingsWindow = nil
        if shouldReopenSettings { showSettings() }
    }

    private func setDebugFeaturesEnabled(_ enabled: Bool) {
        setDebugMenuItemsVisible(enabled)
        coordinator.setDebugFeaturesEnabled(enabled)
    }

    private func applyResetSettings() {
        selectionHotKey = SelectionHotKey.load()
        immediateTranslationHotKey = ImmediateTranslationHotKey.load()
        mirrorActivationHotKey = MirrorActivationHotKey.load()
        toolbarHotKeys = Dictionary(
            uniqueKeysWithValues: ToolbarShortcutAction.configurableActions.map {
                ($0, ToolbarHotKey.load(action: $0))
            }
        )
        if selectionHotKey.isEnabled { _ = registerSelectionHotKey(selectionHotKey) }
        if immediateTranslationHotKey.isEnabled { _ = registerImmediateTranslationHotKey(immediateTranslationHotKey) }
        if mirrorActivationHotKey.isEnabled { _ = registerFixedHotKey(keyCode: mirrorActivationHotKey.keyCode, modifiers: mirrorActivationHotKey.modifiers, id: 4, reference: &mirrorActivationHotKeyRef) }
        mirrorUpdateStyle = MirrorUpdateStyle.load()
        updateStatusMenuShortcuts()
        setDebugFeaturesEnabled(DebugFeatures.load())
        let mode = TranslationDisplayMode.load()
        coordinator.setDebugFeaturesEnabled(DebugFeatures.load())
        coordinator.setMirrorAlwaysOnTop(MirrorAlwaysOnTop.load())
        coordinator.setMirrorBackgroundOpacity(MirrorBackgroundOpacity.load())
        coordinator.setDisplayMode(mode)
        coordinator.setTranslationDirection(TranslationDirection.load())
        coordinator.setProtectsNonSourceText(TranslationTextProtection.load())
        coordinator.setMirrorFollowsSelectionSize(MirrorFollowsSelectionSize.load())
        coordinator.setTargetApplicationTracking(TargetApplicationTracking.load())
        _ = setLaunchAtLogin(LaunchAtLogin.load())
#if LST_EXCLUDE_DEBUG_FEATURES
        appUpdater.resetSettings()
#endif
        Task { await coordinator.setMirrorUpdateStyle(mirrorUpdateStyle) }
        Task { await coordinator.setCapturePolicy(CapturePolicy.load()) }
        coordinator.setRefinementOCRPolicy(RefinementOCRPolicy.load())
        for mode in [OCRMode.realtime, .refinement] {
            coordinator.setOCRSettings(OCRSettings.load(mode: mode), mode: mode)
        }
        applyDisplayLanguage(.load(), persistSelection: false)
    }

    private func setLaunchAtLogin(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            LaunchAtLogin.save(enabled)
            return true
        } catch {
            let alert = NSAlert()
            alert.messageText = L10n.text("자동 실행 설정 실패")
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.addButton(withTitle: L10n.text("확인"))
            alert.runModal()
            return false
        }
    }
    @objc private func startProfiling() {
        PerformanceProfiler.shared.start()
        showNotification(
            title: L10n.text("프로파일링 시작"),
            body: L10n.text("번역 영역을 사용한 뒤 메뉴에서 프로파일링을 종료하세요.")
        )
    }

    @objc private func stopProfiling() {
        guard let report = PerformanceProfiler.shared.stop() else {
            show(error: NSError(domain: "Profiler", code: 1, userInfo: [
                NSLocalizedDescriptionKey: L10n.text("활성 프로파일링 세션이 없습니다.")
            ]))
            return
        }
        present(report)
    }

    @objc private func showRecentProfile() {
        guard let report = PerformanceProfiler.shared.mostRecentReport else {
            show(error: NSError(domain: "Profiler", code: 2, userInfo: [
                NSLocalizedDescriptionKey: L10n.text("아직 생성된 프로파일 결과가 없습니다.")
            ]))
            return
        }
        present(report)
    }

    @objc private func runBenchmark() {
        Task { await runBenchmarkSession() }
    }

    private func runBenchmarkSession() async {
        await coordinator.stop()
        benchmarkProcess?.terminate()
        guard let helperURL = benchmarkExecutableURL(), let screen = NSScreen.main else {
            show(error: NSError(domain: "Benchmark", code: 1, userInfo: [
                NSLocalizedDescriptionKey: L10n.text(
                    "BenchmarkFixture 실행 파일을 찾을 수 없습니다. 앱 번들을 다시 패키징하세요."
                )
            ]))
            return
        }
        let process = Process()
        process.executableURL = helperURL
        do { try process.run() } catch { show(error: error); return }
        benchmarkProcess = process
        try? await Task.sleep(for: .seconds(1))
        let rect = benchmarkFrame(in: screen.visibleFrame)
        PerformanceProfiler.shared.start(benchmark: true)
        do {
            let captureTarget = CaptureTarget.application(CaptureApplication(
                processID: process.processIdentifier,
                bundleIdentifier: "io.github.bloodybear.rearview.benchmark",
                name: "BenchmarkFixture"
            ))
            try await coordinator.start(
                screen: screen, selection: rect,
                mirrorUpdateStyle: mirrorUpdateStyle,
                captureTarget: captureTarget,
                benchmarkDiagnostics: true
            )
            showNotification(
                title: L10n.text("벤치마크 실행 중"),
                body: L10n.text("정적 화면, 스크롤, 장면 전환을 30초 동안 측정합니다.")
            )
            try? await Task.sleep(for: .seconds(30))
            await coordinator.stop()
            process.terminate()
            benchmarkProcess = nil
            if let report = PerformanceProfiler.shared.stop() { present(report) }
            if CommandLine.arguments.contains("--benchmark-exit") { NSApp.terminate(nil) }
        } catch {
            process.terminate()
            _ = PerformanceProfiler.shared.stop()
            show(error: error)
            if CommandLine.arguments.contains("--benchmark-exit") { NSApp.terminate(nil) }
        }
    }

    private func benchmarkExecutableURL() -> URL? {
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/BenchmarkFixture.app/Contents/MacOS/BenchmarkFixture")
        if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        let sibling = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("BenchmarkFixture")
        if let sibling, FileManager.default.isExecutableFile(atPath: sibling.path) { return sibling }
        return nil
    }

    private func benchmarkFrame(in visibleFrame: CGRect) -> CGRect {
        let size = CGSize(width: min(1000, visibleFrame.width - 40), height: min(700, visibleFrame.height - 60))
        return CGRect(x: visibleFrame.midX - size.width / 2, y: visibleFrame.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    private func present(_ report: SessionReport) {
        let files = try? ProfileReportWriter.save(report)
        let controller = ProfileSummaryWindowController(report: report, files: files)
        summaryWindow = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showNotification(title: String, body: String) {
        statusItem.button?.toolTip = "\(title): \(body)"
        statusItem.button?.contentTintColor = .systemOrange
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            self?.statusItem.button?.contentTintColor = nil
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func presentCurrentPermissionGate() {
        guard !screenCapturePermissionGranted else { return }
        if permissionRecoveryWindow != nil {
            showPermissionRecoveryWindow()
        } else if permissionIntroductionWindow != nil {
            showPermissionIntroductionWindow()
        } else if permissionCheckTask == nil {
            showPermissionIntroductionWindow()
        }
    }

    private func showPermissionIntroductionWindow() {
        let controller = makePermissionIntroductionWindowIfNeeded()
        presentPermissionWindow(controller)
    }

    private func makePermissionIntroductionWindowIfNeeded()
        -> ScreenCapturePermissionWindowController
    {
        if let permissionIntroductionWindow { return permissionIntroductionWindow }
        let controller = ScreenCapturePermissionWindowController(kind: .introduction)
        controller.onContinue = { [weak self] in
            self?.continueScreenCapturePermissionRequest()
        }
        controller.onQuit = { [weak self] in self?.quit() }
        permissionIntroductionWindow = controller
        return controller
    }

    private func continueScreenCapturePermissionRequest() {
        permissionIntroductionWindow?.window?.orderOut(nil)
        showPermissionRequiredWindow()
        startScreenCapturePermissionProbe()
    }

    private func showPermissionRequiredWindow() {
        let controller = makePermissionRecoveryWindowIfNeeded()
        controller.showPermissionRequired()
        presentPermissionWindow(controller)
    }

    private func showPermissionRecoveryWindow() {
        let controller = makePermissionRecoveryWindowIfNeeded()
        presentPermissionWindow(controller)
    }

    private func makePermissionRecoveryWindowIfNeeded()
        -> ScreenCapturePermissionWindowController
    {
        if let permissionRecoveryWindow { return permissionRecoveryWindow }
        let controller = ScreenCapturePermissionWindowController(kind: .recovery)
        controller.onOpenSystemSettings = { [weak self] in
            self?.openScreenCaptureSettings()
        }
        controller.onRetryPermission = { [weak self] in
            self?.startScreenCapturePermissionProbe()
        }
        controller.onConfirmPermission = { [weak self] in
            self?.confirmScreenCapturePermission()
        }
        controller.onRecoveryWindowBecameKey = { [weak self] in
            self?.startScreenCapturePermissionProbe()
        }
        controller.onQuit = { [weak self] in self?.quit() }
        permissionRecoveryWindow = controller
        return controller
    }

    private func presentPermissionWindow(
        _ controller: ScreenCapturePermissionWindowController
    ) {
        let wasVisible = controller.window?.isVisible == true
        if !wasVisible {
            controller.showWindow(nil)
            controller.window?.center()
        }
        NSApp.activate(ignoringOtherApps: true)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.window?.orderFrontRegardless()
    }

    private func hidePermissionWindows() {
        permissionIntroductionWindow?.window?.orderOut(nil)
        permissionRecoveryWindow?.window?.orderOut(nil)
    }

    private func startScreenCapturePermissionProbe() {
        guard permissionCheckTask == nil else { return }
        permissionRecoveryWindow?.setChecking(true)
        permissionCheckGeneration &+= 1
        let generation = permissionCheckGeneration
        permissionCheckTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.permissionClient.probe()
                try Task.checkCancellation()
                guard generation == self.permissionCheckGeneration else { return }
                self.permissionCheckTask = nil
                let recoveryIsVisible = self.permissionRecoveryWindow?.window?.isVisible == true
                let shouldShowConfirmation = recoveryIsVisible
                    || !ScreenCapturePermissionConfirmation.hasBeenShown(in: self.defaults)
                self.screenCapturePermissionGranted = true
                self.installApplicationServices()
                if shouldShowConfirmation {
                    let controller = self.makePermissionRecoveryWindowIfNeeded()
                    let shortcutTitle = self.selectionHotKey.isEnabled
                        ? self.selectionHotKey.title : nil
                    controller.showPermissionConfirmed(
                        selectionShortcutTitle: shortcutTitle
                    )
                    ScreenCapturePermissionConfirmation.markShown(in: self.defaults)
                    if controller.window?.isVisible != true {
                        self.presentPermissionWindow(controller)
                    }
                } else {
                    self.hidePermissionWindows()
                }
            } catch is CancellationError {
                return
            } catch {
                guard generation == self.permissionCheckGeneration else { return }
                self.screenCapturePermissionGranted = false
                let controller = self.makePermissionRecoveryWindowIfNeeded()
                controller.setChecking(true)
                if controller.window?.isVisible != true {
                    self.presentPermissionWindow(controller)
                }
                self.permissionCheckTask = nil
                controller.showPermissionRequired()
            }
        }
    }

    private func confirmScreenCapturePermission() {
        permissionRecoveryWindow?.window?.orderOut(nil)
    }

    private func openScreenCaptureSettings() {
        if !permissionClient.openSystemSettings() { NSSound.beep() }
    }

    private func show(error: Error) {
        if isScreenCapturePermissionError(error) {
            screenCapturePermissionGranted = false
            showPermissionRequiredWindow()
            return
        }
        let alert = NSAlert()
        alert.messageText = L10n.text("실시간 번역을 시작할 수 없습니다")
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    private func isScreenCapturePermissionError(_ error: Error) -> Bool {
        if let translatorError = error as? TranslatorError,
           case .screenPermission = translatorError { return true }
        let nsError = error as NSError
        return nsError.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain" && nsError.code == -3801
    }

}
