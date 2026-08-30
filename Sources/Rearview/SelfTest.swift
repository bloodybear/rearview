import Foundation
import AppKit

enum SelfTest {
    @MainActor
    static func run() async {
        let failedCapture = ScreenCaptureEngine()
        do {
            try await failedCapture.start(
                displayID: CGDirectDisplayID.max,
                screenFrame: .zero,
                backingScale: 1,
                selection: .zero,
                policy: CapturePolicy(),
                onFrame: { _, _, _ in }
            )
            preconditionFailure("capture start unexpectedly succeeded for an invalid display")
        } catch {
            precondition(failedCapture.isCleanForSelfTest)
        }

        _ = NSApplication.shared
        let settingsController = SettingsWindowController()
        requireNoViolations(
            overlayControlBarContractViolationsForSelfTest(),
            message: "overlay control bar contract failed"
        )
        requireNoViolations(
            mirrorControlBarContractViolationsForSelfTest(),
            message: "mirror control bar contract failed"
        )
        requireNoViolations(
            regionPanelContractViolationsForSelfTest(),
            message: "region panel interaction contract failed"
        )
        requireNoViolations(
            selectionPanelContractViolationsForSelfTest(),
            message: "selection panel interaction contract failed"
        )
        requireNoViolations(
            mirrorPlacementProbeContractViolationsForSelfTest(),
            message: "mirror placement probe contract failed"
        )
        requireNoViolations(
            mirrorToolbarContractViolationsForSelfTest(),
            message: "mirror toolbar contract failed"
        )
        requireNoViolations(
            settingsController.layoutContractViolationsForSelfTest(),
            message: "settings layout contract failed"
        )
        print("Self-test passed")
    }

    private static func requireNoViolations(_ violations: [String], message: String) {
        guard violations.isEmpty else {
            fputs(violations.joined(separator: "\n") + "\n", stderr)
            preconditionFailure(message)
        }
    }
}
