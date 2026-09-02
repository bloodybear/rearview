import Foundation

/// User-default keys owned by Sparkle but reset by Rearview's "reset all
/// settings" action. The values themselves are read and written through
/// SPUUpdater; this list only gives the reset operation a stable key set.
enum UpdateSettingsDefaults {
    static let automaticChecks = "SUEnableAutomaticChecks"
    static let automaticDownloads = "SUAutomaticallyUpdate"
    static let scheduledCheckInterval = "SUScheduledCheckInterval"

    static let keys = [automaticChecks, automaticDownloads, scheduledCheckInterval]
}

struct UpdateSettingsSnapshot: Equatable, Sendable {
    let automaticallyChecksForUpdates: Bool
    let automaticallyDownloadsUpdates: Bool
    let allowsAutomaticUpdates: Bool

    static let defaults = UpdateSettingsSnapshot(
        automaticallyChecksForUpdates: true,
        automaticallyDownloadsUpdates: false,
        allowsAutomaticUpdates: true
    )
}

enum UpdateLifecycleState: Equatable, Sendable {
    case idle
    case available(version: String)
    case downloading(version: String)
    case installPending(version: String)

    var version: String? {
        switch self {
        case .idle: nil
        case let .available(version), let .downloading(version), let .installPending(version): version
        }
    }

    var persistedStage: String? {
        switch self {
        case .idle: nil
        case .available: "available"
        case .downloading: "downloading"
        case .installPending: "installPending"
        }
    }

    init?(persistedStage: String, version: String) {
        switch persistedStage {
        case "available": self = .available(version: version)
        case "downloading": self = .downloading(version: version)
        case "installPending": self = .installPending(version: version)
        default: return nil
        }
    }
}

/// Only update reminder metadata is persisted by Rearview. Sparkle remains
/// the source of truth for updater preferences and downloaded update files.
struct UpdateNotificationRecord: Equatable, Sendable {
    static let versionKey = "updateNotification.version"
    static let displayVersionKey = "updateNotification.displayVersion"
    static let firstSeenAtKey = "updateNotification.firstSeenAt"
    static let stageKey = "updateNotification.stage"
    static let initialNotificationSentKey = "updateNotification.initialNotificationSent"
    static let nextLaunchReminderSentKey = "updateNotification.nextLaunchReminderSent"
    static let weeklyReminderCountKey = "updateNotification.weeklyReminderCount"
    static let lastNotificationAtKey = "updateNotification.lastNotificationAt"

    let version: String
    let displayVersion: String
    let firstSeenAt: Date
    var stage: UpdateLifecycleState
    var initialNotificationSent: Bool
    var nextLaunchReminderSent: Bool
    var weeklyReminderCount: Int
    var lastNotificationAt: Date?

    init(
        version: String,
        displayVersion: String = "",
        firstSeenAt: Date = .now,
        stage: UpdateLifecycleState = .available(version: ""),
        initialNotificationSent: Bool = false,
        nextLaunchReminderSent: Bool = false,
        weeklyReminderCount: Int = 0,
        lastNotificationAt: Date? = nil
    ) {
        self.version = version
        self.displayVersion = displayVersion.isEmpty ? version : displayVersion
        self.firstSeenAt = firstSeenAt
        self.stage = switch stage {
        case .idle: .available(version: version)
        case .available: .available(version: version)
        case .downloading: .downloading(version: version)
        case .installPending: .installPending(version: version)
        }
        self.initialNotificationSent = initialNotificationSent
        self.nextLaunchReminderSent = nextLaunchReminderSent
        self.weeklyReminderCount = weeklyReminderCount
        self.lastNotificationAt = lastNotificationAt
    }

    init?(from defaults: UserDefaults = .standard) {
        guard
            let version = defaults.string(forKey: Self.versionKey),
            let firstSeenAt = defaults.object(forKey: Self.firstSeenAtKey) as? Date,
            let persistedStage = defaults.string(forKey: Self.stageKey),
            let stage = UpdateLifecycleState(persistedStage: persistedStage, version: version)
        else { return nil }

        self.version = version
        self.displayVersion = defaults.string(forKey: Self.displayVersionKey) ?? version
        self.firstSeenAt = firstSeenAt
        self.stage = stage
        self.initialNotificationSent = defaults.bool(forKey: Self.initialNotificationSentKey)
        self.nextLaunchReminderSent = defaults.bool(forKey: Self.nextLaunchReminderSentKey)
        self.weeklyReminderCount = min(max(defaults.integer(forKey: Self.weeklyReminderCountKey), 0), 2)
        self.lastNotificationAt = defaults.object(forKey: Self.lastNotificationAtKey) as? Date
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(version, forKey: Self.versionKey)
        defaults.set(displayVersion, forKey: Self.displayVersionKey)
        defaults.set(firstSeenAt, forKey: Self.firstSeenAtKey)
        defaults.set(stage.persistedStage, forKey: Self.stageKey)
        defaults.set(initialNotificationSent, forKey: Self.initialNotificationSentKey)
        defaults.set(nextLaunchReminderSent, forKey: Self.nextLaunchReminderSentKey)
        defaults.set(weeklyReminderCount, forKey: Self.weeklyReminderCountKey)
        if let lastNotificationAt {
            defaults.set(lastNotificationAt, forKey: Self.lastNotificationAtKey)
        } else {
            defaults.removeObject(forKey: Self.lastNotificationAtKey)
        }
    }

    static func clear(from defaults: UserDefaults = .standard) {
        [
            versionKey, displayVersionKey, firstSeenAtKey, stageKey, initialNotificationSentKey,
            nextLaunchReminderSentKey, weeklyReminderCountKey, lastNotificationAtKey
        ].forEach { defaults.removeObject(forKey: $0) }
    }
}

enum UpdateVersionComparator {
    static func isVersion(_ lhs: String, atLeast rhs: String) -> Bool {
        let left = components(of: lhs)
        let right = components(of: rhs)
        for index in 0..<max(left.count, right.count) {
            let leftValue = index < left.count ? left[index] : 0
            let rightValue = index < right.count ? right[index] : 0
            if leftValue != rightValue { return leftValue > rightValue }
        }
        return true
    }

    private static func components(of version: String) -> [Int] {
        version.split(separator: ".").map { Int($0) ?? 0 }
    }
}
