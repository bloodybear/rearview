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
    private let githubLink = NSTextField(labelWithString: "")

    init(
        appInfo: AboutAppInfo = AboutAppInfo(),
        language: AppDisplayLanguage = .load()
    ) {
        self.appInfo = appInfo
        self.language = language

        let rootView = NSView(frame: CGRect(x: 0, y: 0, width: 360, height: 240))
        let viewController = NSViewController()
        viewController.view = rootView

        let window = NSWindow(contentViewController: viewController)
        window.title = "Rearview"
        window.styleMask = [.titled, .closable]
        window.setContentSize(CGSize(width: 360, height: 240))
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

    private func configureView(in rootView: NSView) {
        iconView.image = NSApp.applicationIconImage
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.setAccessibilityIdentifier("about-app-icon")

        nameLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        nameLabel.alignment = .center
        nameLabel.setAccessibilityIdentifier("about-app-name")

        versionLabel.font = .systemFont(ofSize: 13)
        versionLabel.alignment = .center
        versionLabel.setAccessibilityIdentifier("about-version")

        copyrightLabel.font = .systemFont(ofSize: 11)
        copyrightLabel.textColor = .secondaryLabelColor
        copyrightLabel.alignment = .center
        copyrightLabel.setAccessibilityIdentifier("about-copyright")

        githubLink.alignment = .center
        githubLink.isEditable = false
        githubLink.isSelectable = true
        githubLink.allowsEditingTextAttributes = true
        githubLink.usesSingleLineMode = true
        githubLink.lineBreakMode = .byTruncatingMiddle
        githubLink.setAccessibilityIdentifier("about-github-link")

        [iconView, nameLabel, versionLabel, copyrightLabel, githubLink].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        [iconView, nameLabel, versionLabel, copyrightLabel, githubLink].forEach {
            rootView.addSubview($0)
        }

        NSLayoutConstraint.activate([
            nameLabel.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 24),
            nameLabel.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -24),
            nameLabel.heightAnchor.constraint(equalToConstant: 28),
            nameLabel.centerYAnchor.constraint(equalTo: rootView.centerYAnchor, constant: 15),
            iconView.widthAnchor.constraint(equalToConstant: 96),
            iconView.heightAnchor.constraint(equalToConstant: 96),
            iconView.centerXAnchor.constraint(equalTo: rootView.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: rootView.centerYAnchor, constant: -51),
            versionLabel.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 24),
            versionLabel.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -24),
            versionLabel.heightAnchor.constraint(equalToConstant: 18),
            versionLabel.centerYAnchor.constraint(equalTo: rootView.centerYAnchor, constant: 40),
            copyrightLabel.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 24),
            copyrightLabel.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -24),
            copyrightLabel.heightAnchor.constraint(equalToConstant: 18),
            copyrightLabel.centerYAnchor.constraint(equalTo: rootView.centerYAnchor, constant: 62),
            githubLink.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 24),
            githubLink.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -24),
            githubLink.heightAnchor.constraint(equalToConstant: 18),
            githubLink.centerYAnchor.constraint(equalTo: rootView.centerYAnchor, constant: 90)
        ])
    }

    private func refreshContent() {
        let linkParagraphStyle = NSMutableParagraphStyle()
        linkParagraphStyle.alignment = .center

        nameLabel.stringValue = "Rearview"
        versionLabel.stringValue = L10n.format("버전 %@", appInfo.version, language: language)
        copyrightLabel.stringValue = appInfo.copyright
        githubLink.attributedStringValue = NSAttributedString(
            string: Self.githubURL.absoluteString,
            attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .paragraphStyle: linkParagraphStyle,
                .link: Self.githubURL
            ]
        )
        githubLink.toolTip = Self.githubURL.absoluteString
    }
}
