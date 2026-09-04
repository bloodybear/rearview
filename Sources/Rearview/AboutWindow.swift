import AppKit

struct AboutAppInfo: Equatable {
    static let missingValue = "—"

    let version: String
    let copyright: String

    init(bundle: Bundle = .main) {
        self.init(
            version: Self.bundleValue("CFBundleShortVersionString", from: bundle),
            copyright: Self.bundleValue("NSHumanReadableCopyright", from: bundle)
        )
    }

    init(version: String?, copyright: String?) {
        self.version = Self.displayValue(version)
        self.copyright = Self.displayValue(copyright)
    }

    private static func bundleValue(_ key: String, from bundle: Bundle) -> String? {
        bundle.object(forInfoDictionaryKey: key) as? String
    }

    private static func displayValue(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return missingValue }
        return value
    }
}

@MainActor
final class AboutWindowController: NSWindowController {
    static let githubURL = URL(string: "https://github.com/bloodybear/rearview")!

    private let appInfo: AboutAppInfo
    private var language: AppDisplayLanguage
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let versionLabel = NSTextField(labelWithString: "")
    private let copyrightLabel = NSTextField(labelWithString: "")
    private let githubButton = NSButton()

    var onOpenURL: ((URL) -> Void)?

    init(
        appInfo: AboutAppInfo = AboutAppInfo(),
        language: AppDisplayLanguage = .load()
    ) {
        self.appInfo = appInfo
        self.language = language

        let rootView = NSView(frame: CGRect(x: 0, y: 0, width: 360, height: 300))
        let viewController = NSViewController()
        viewController.view = rootView

        let window = NSWindow(contentViewController: viewController)
        window.title = "Rearview"
        window.styleMask = [.titled, .closable]
        window.setContentSize(CGSize(width: 360, height: 300))
        window.isReleasedWhenClosed = false

        super.init(window: window)

        configureView(in: rootView)
        refreshContent()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func refreshLocalization(language: AppDisplayLanguage = .load()) {
        self.language = language
        refreshContent()
    }

    @objc private func openGitHub() {
        if let onOpenURL {
            onOpenURL(Self.githubURL)
        } else {
            _ = NSWorkspace.shared.open(Self.githubURL)
        }
    }

    private func configureView(in rootView: NSView) {
        iconView.image = NSApp.applicationIconImage
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.setAccessibilityIdentifier("about-app-icon")

        nameLabel.font = .systemFont(ofSize: 24, weight: .semibold)
        nameLabel.alignment = .center
        nameLabel.setAccessibilityIdentifier("about-app-name")

        versionLabel.font = .systemFont(ofSize: 13)
        versionLabel.alignment = .center
        versionLabel.setAccessibilityIdentifier("about-version")

        copyrightLabel.font = .systemFont(ofSize: 11)
        copyrightLabel.textColor = .secondaryLabelColor
        copyrightLabel.alignment = .center
        copyrightLabel.setAccessibilityIdentifier("about-copyright")

        githubButton.bezelStyle = .rounded
        githubButton.target = self
        githubButton.action = #selector(openGitHub)
        githubButton.setAccessibilityIdentifier("about-github")

        [iconView, nameLabel, versionLabel, copyrightLabel, githubButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        [iconView, nameLabel, versionLabel, copyrightLabel, githubButton].forEach {
            rootView.addSubview($0)
        }

        NSLayoutConstraint.activate([
            nameLabel.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 24),
            nameLabel.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -24),
            nameLabel.heightAnchor.constraint(equalToConstant: 30),
            nameLabel.centerYAnchor.constraint(equalTo: rootView.centerYAnchor, constant: -14),
            iconView.widthAnchor.constraint(equalToConstant: 96),
            iconView.heightAnchor.constraint(equalToConstant: 96),
            iconView.centerXAnchor.constraint(equalTo: rootView.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: rootView.centerYAnchor, constant: -85),
            versionLabel.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 24),
            versionLabel.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -24),
            versionLabel.heightAnchor.constraint(equalToConstant: 18),
            versionLabel.centerYAnchor.constraint(equalTo: rootView.centerYAnchor, constant: 20),
            copyrightLabel.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 24),
            copyrightLabel.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -24),
            copyrightLabel.heightAnchor.constraint(equalToConstant: 18),
            copyrightLabel.centerYAnchor.constraint(equalTo: rootView.centerYAnchor, constant: 46),
            githubButton.widthAnchor.constraint(equalToConstant: 150),
            githubButton.heightAnchor.constraint(equalToConstant: 28),
            githubButton.centerXAnchor.constraint(equalTo: rootView.centerXAnchor),
            githubButton.centerYAnchor.constraint(equalTo: rootView.centerYAnchor, constant: 100)
        ])
    }

    private func refreshContent() {
        nameLabel.stringValue = "Rearview"
        versionLabel.stringValue = L10n.format("버전 %@", appInfo.version, language: language)
        copyrightLabel.stringValue = appInfo.copyright
        githubButton.title = L10n.text("GitHub에서 보기", language: language)
    }
}
