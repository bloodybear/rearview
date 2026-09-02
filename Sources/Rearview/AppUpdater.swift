#if LST_EXCLUDE_DEBUG_FEATURES
import AppKit
@preconcurrency import Sparkle
@preconcurrency import UserNotifications

@MainActor
final class AppUpdater: NSObject, SPUUpdaterDelegate,
    @preconcurrency SPUStandardUserDriverDelegate, @preconcurrency UNUserNotificationCenterDelegate {
    private(set) lazy var controller: SPUStandardUpdaterController = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: self,
        userDriverDelegate: self
    )

    var onStateChange: ((UpdateLifecycleState) -> Void)?
    var onSettingsChange: ((UpdateSettingsSnapshot) -> Void)?

    private(set) var state: UpdateLifecycleState = .idle
    private var notificationRecord: UpdateNotificationRecord?
    private var updateMenuItem: NSMenuItem?
    private var manualCheckInProgress = false
    private var started = false
    private var reminderTimer: Timer?
    private var settingsObservations: [NSKeyValueObservation] = []
    private let notificationCenter: UNUserNotificationCenter
    private let defaults: UserDefaults

    init(
        defaults: UserDefaults = .standard,
        notificationCenter: UNUserNotificationCenter = .current()
    ) {
        self.defaults = defaults
        self.notificationCenter = notificationCenter
        super.init()
        notificationCenter.delegate = self
        restoreNotificationState()
    }

    func startIfConfigured() {
        guard !started, hasRequiredConfiguration else { return }
        started = true
        controller.startUpdater()
        observeUpdaterSettings()
        publishSettings()
        scheduleReminderTimer()
        sendLaunchReminderIfNeeded()
    }

    var settingsSnapshot: UpdateSettingsSnapshot {
        UpdateSettingsSnapshot(
            automaticallyChecksForUpdates: controller.updater.automaticallyChecksForUpdates,
            automaticallyDownloadsUpdates: storedAutomaticDownloadsPreference,
            allowsAutomaticUpdates: controller.updater.allowsAutomaticUpdates
        )
    }

    @discardableResult
    func addCheckForUpdatesItem(to menu: NSMenu) -> NSMenuItem {
        let item = menu.addItem(
            withTitle: menuTitle,
            action: #selector(checkForUpdates(_:)),
            keyEquivalent: ""
        )
        item.target = self
        updateMenuItem = item
        return item
    }

    @objc func checkForUpdates(_ sender: Any?) {
        guard controller.updater.canCheckForUpdates else { return }
        manualCheckInProgress = true
        controller.checkForUpdates(sender)
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        guard controller.updater.automaticallyChecksForUpdates != enabled else {
            publishSettings()
            return
        }
        controller.updater.automaticallyChecksForUpdates = enabled
        publishSettings()
        if enabled, started {
            controller.updater.checkForUpdatesInBackground()
        }
    }

    func setAutomaticallyDownloadsUpdates(_ enabled: Bool) {
        guard controller.updater.allowsAutomaticUpdates else {
            publishSettings()
            return
        }
        controller.updater.automaticallyDownloadsUpdates = enabled
        publishSettings()
        if enabled, started, case .available = state {
            controller.updater.checkForUpdatesInBackground()
        }
    }

    func resetSettings() {
        controller.updater.updateCheckInterval = 24 * 60 * 60
        controller.updater.automaticallyChecksForUpdates = true
        controller.updater.automaticallyDownloadsUpdates = false
        publishSettings()
    }

    // MARK: Sparkle updater delegate

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let wasManual = manualCheckInProgress
        let version = item.versionString
        if let existing = notificationRecord, existing.version == version {
            state = existing.stage
        } else {
            state = .available(version: version)
            notificationRecord = UpdateNotificationRecord(
                version: version,
                displayVersion: item.displayVersionString,
                stage: state
            )
        }
        persistState()
        publishState()

        if !wasManual {
            sendInitialNotificationIfNeeded(for: item)
        }
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        // Keep an already discovered update visible until Sparkle reports that
        // it was installed or the user explicitly skipped it.
    }

    func updater(
        _ updater: SPUUpdater,
        willDownloadUpdate item: SUAppcastItem,
        with request: NSMutableURLRequest
    ) {
        state = .downloading(version: item.versionString)
        persistState()
        publishState()
    }

    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        state = .installPending(version: item.versionString)
        persistState()
        publishState()
    }

    func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: Error) {
        state = .available(version: item.versionString)
        persistState()
        publishState()
    }

    func updater(
        _ updater: SPUUpdater,
        userDidMake choice: SPUUserUpdateChoice,
        forUpdate updateItem: SUAppcastItem,
        state updateState: SPUUserUpdateState
    ) {
        switch choice {
        case .skip:
            clearState()
        case .dismiss:
            if case .installPending = state {
                persistState()
                publishState()
            }
        case .install:
            break
        @unknown default:
            break
        }
    }

    func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        state = .installPending(version: item.versionString)
        persistState()
        publishState()

        // Returning NO leaves installation to Sparkle's normal application
        // termination path. Rearview never terminates or relaunches itself for
        // an automatic update.
        return false
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        manualCheckInProgress = false
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        manualCheckInProgress = false
        if case let .downloading(version) = state {
            state = .available(version: version)
            persistState()
            publishState()
        }
    }

    // MARK: Sparkle standard user driver delegate

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        false
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        // Scheduled updates are surfaced by the system notification and menu
        // state. User-initiated checks always remain Sparkle's standard UI.
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        // Attention alone does not resolve an update. Reminders continue until
        // the user installs or skips the version.
    }

    // MARK: Notifications

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if response.notification.request.content.categoryIdentifier == Self.notificationCategory {
            openUpdateWindow()
        }
        completionHandler()
    }

    private func openUpdateWindow() {
        NSApp.activate(ignoringOtherApps: true)
        manualCheckInProgress = true
        controller.checkForUpdates(nil)
    }

    private func sendInitialNotificationIfNeeded(for item: SUAppcastItem) {
        guard var record = notificationRecord, !record.initialNotificationSent else { return }
        record.initialNotificationSent = true
        record.lastNotificationAt = .now
        record.save(to: defaults)
        notificationRecord = record
        deliverNotification(
            title: L10n.text("Rearview 업데이트"),
            body: L10n.format("새 버전 %@을 사용할 수 있습니다.", item.displayVersionString),
            version: item.versionString
        )
    }

    private func sendLaunchReminderIfNeeded() {
        guard var record = notificationRecord,
              !record.nextLaunchReminderSent,
              record.initialNotificationSent
        else { return }
        record.nextLaunchReminderSent = true
        record.lastNotificationAt = .now
        record.save(to: defaults)
        notificationRecord = record
        deliverNotification(
            title: L10n.text("Rearview 업데이트"),
            body: L10n.format("업데이트가 설치되지 않았습니다. 버전 %@을 확인하세요.", record.displayVersion),
            version: record.version
        )
    }

    private func sendWeeklyReminderIfNeeded() {
        guard var record = notificationRecord,
              record.initialNotificationSent,
              record.nextLaunchReminderSent,
              record.weeklyReminderCount < 2,
              let lastNotificationAt = record.lastNotificationAt,
              Date.now.timeIntervalSince(lastNotificationAt) >= 7 * 24 * 60 * 60
        else { return }
        record.weeklyReminderCount += 1
        record.lastNotificationAt = .now
        record.save(to: defaults)
        notificationRecord = record
        deliverNotification(
            title: L10n.text("Rearview 업데이트"),
            body: L10n.format("업데이트가 설치되지 않았습니다. 버전 %@을 확인하세요.", record.displayVersion),
            version: record.version
        )
    }

    private func deliverNotification(title: String, body: String, version: String) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let settings = await self.notificationCenter.notificationSettings()
            switch settings.authorizationStatus {
            case .authorized, .provisional:
                self.addNotification(title: title, body: body, version: version)
            case .notDetermined:
                guard (try? await self.notificationCenter.requestAuthorization(options: [.alert])) == true else {
                    return
                }
                self.addNotification(title: title, body: body, version: version)
            default:
                break
            }
        }
    }

    private func addNotification(title: String, body: String, version: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = Self.notificationCategory
        content.userInfo = ["updateVersion": version]
        let request = UNNotificationRequest(
            identifier: "rearview.update.\(version).\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        notificationCenter.add(request)
    }

    private func scheduleReminderTimer() {
        guard reminderTimer == nil else { return }
        reminderTimer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) {
            [weak self] _ in
            Task { @MainActor [weak self] in
                self?.sendWeeklyReminderIfNeeded()
            }
        }
    }

    // MARK: State and settings

    private static let notificationCategory = "rearview.update"

    private var menuTitle: String {
        switch state {
        case .idle: L10n.text("업데이트 확인…")
        case .available: L10n.text("새 업데이트 있음…")
        case .downloading: L10n.text("업데이트 다운로드 중…")
        case .installPending: L10n.text("업데이트 설치 대기 중…")
        }
    }

    private var storedAutomaticDownloadsPreference: Bool {
        if defaults.object(forKey: UpdateSettingsDefaults.automaticDownloads) != nil {
            return defaults.bool(forKey: UpdateSettingsDefaults.automaticDownloads)
        }
        return controller.updater.automaticallyDownloadsUpdates
    }

    private var hasRequiredConfiguration: Bool {
        guard let info = Bundle.main.infoDictionary else { return false }
        let feedURL = (info["SUFeedURL"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let publicKey = (info["SUPublicEDKey"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return feedURL?.isEmpty == false && publicKey?.isEmpty == false
    }

    private func restoreNotificationState() {
        guard let record = UpdateNotificationRecord(from: defaults),
              let currentBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              !UpdateVersionComparator.isVersion(currentBuild, atLeast: record.version)
        else {
            UpdateNotificationRecord.clear(from: defaults)
            return
        }
        notificationRecord = record
        state = record.stage
    }

    private func persistState() {
        guard var record = notificationRecord, let version = state.version else { return }
        if record.version != version {
            record = UpdateNotificationRecord(version: version, stage: state)
        } else {
            record.stage = state
        }
        record.save(to: defaults)
        notificationRecord = record
    }

    private func clearState() {
        notificationRecord = nil
        state = .idle
        UpdateNotificationRecord.clear(from: defaults)
        publishState()
    }

    private func publishState() {
        updateMenuItem?.title = menuTitle
        onStateChange?(state)
    }

    private func publishSettings() {
        onSettingsChange?(settingsSnapshot)
    }

    private func observeUpdaterSettings() {
        guard settingsObservations.isEmpty else { return }
        settingsObservations = [
            controller.updater.observe(\SPUUpdater.automaticallyChecksForUpdates, options: [.new]) {
                [weak self] _, _ in
                Task { @MainActor [weak self] in self?.publishSettings() }
            },
            controller.updater.observe(\SPUUpdater.automaticallyDownloadsUpdates, options: [.new]) {
                [weak self] _, _ in
                Task { @MainActor [weak self] in self?.publishSettings() }
            },
        ]
    }
}
#endif
