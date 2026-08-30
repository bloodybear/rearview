#if LST_EXCLUDE_DEBUG_FEATURES
import AppKit
import Sparkle

@MainActor
final class AppUpdater: NSObject {
    let controller: SPUStandardUpdaterController

    override init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        super.init()
    }

    func startIfConfigured() {
        guard hasRequiredConfiguration else { return }
        controller.startUpdater()
    }

    @discardableResult
    func addCheckForUpdatesItem(to menu: NSMenu) -> NSMenuItem {
        let item = menu.addItem(
            withTitle: L10n.text("업데이트 확인…"),
            action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        item.target = controller
        return item
    }

    private var hasRequiredConfiguration: Bool {
        guard let info = Bundle.main.infoDictionary else { return false }
        let feedURL = (info["SUFeedURL"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let publicKey = (info["SUPublicEDKey"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return feedURL?.isEmpty == false && publicKey?.isEmpty == false
    }
}
#endif
