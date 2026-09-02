import Foundation
import Testing
@testable import Rearview

@Suite
struct UpdateLifecycleTests {
    @Test func updateSettingsHaveExpectedDefaults() {
        #expect(UpdateSettingsSnapshot.defaults.automaticallyChecksForUpdates)
        #expect(!UpdateSettingsSnapshot.defaults.automaticallyDownloadsUpdates)
        #expect(UpdateSettingsSnapshot.defaults.allowsAutomaticUpdates)
    }

    @Test func updateNotificationRecordRoundTripsAndClampsReminderCount() {
        withTestDefaults { defaults in
            let firstSeenAt = Date(timeIntervalSince1970: 1_234)
            let record = UpdateNotificationRecord(
                version: "20260831.1",
                firstSeenAt: firstSeenAt,
                stage: .installPending(version: "20260831.1"),
                initialNotificationSent: true,
                nextLaunchReminderSent: true,
                weeklyReminderCount: 8,
                lastNotificationAt: Date(timeIntervalSince1970: 2_345)
            )
            record.save(to: defaults)

            let restored = UpdateNotificationRecord(from: defaults)
            #expect(restored?.version == "20260831.1")
            #expect(restored?.firstSeenAt == firstSeenAt)
            #expect(restored?.stage == .installPending(version: "20260831.1"))
            #expect(restored?.initialNotificationSent == true)
            #expect(restored?.nextLaunchReminderSent == true)
            #expect(restored?.weeklyReminderCount == 2)
            #expect(restored?.lastNotificationAt == Date(timeIntervalSince1970: 2_345))

            UpdateNotificationRecord.clear(from: defaults)
            #expect(UpdateNotificationRecord(from: defaults) == nil)
        }
    }

    @Test func lifecycleStatePersistenceUsesStableStages() {
        #expect(UpdateLifecycleState.available(version: "1").persistedStage == "available")
        #expect(UpdateLifecycleState.downloading(version: "1").persistedStage == "downloading")
        #expect(UpdateLifecycleState.installPending(version: "1").persistedStage == "installPending")
        #expect(UpdateLifecycleState(persistedStage: "available", version: "1") == .available(version: "1"))
        #expect(UpdateLifecycleState(persistedStage: "unknown", version: "1") == nil)
    }

    @Test func versionComparatorHandlesBuildVersions() {
        #expect(UpdateVersionComparator.isVersion("20260831.1", atLeast: "20260830.9"))
        #expect(UpdateVersionComparator.isVersion("26.8.0", atLeast: "26.8"))
        #expect(!UpdateVersionComparator.isVersion("26.7.9", atLeast: "26.8.0"))
        #expect(UpdateVersionComparator.isVersion("1.0", atLeast: "1.0"))
    }

    @Test func resetKeysIncludeSparklePreferences() {
        withTestDefaults { defaults in
            UpdateSettingsDefaults.keys.forEach { defaults.set(true, forKey: $0) }
            AppSettings.reset(to: defaults)
            UpdateSettingsDefaults.keys.forEach {
                #expect(defaults.object(forKey: $0) == nil)
            }
        }
    }
}
