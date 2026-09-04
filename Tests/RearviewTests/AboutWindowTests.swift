import AppKit
import Testing
@testable import Rearview

@Suite
struct AboutWindowTests {
    private let appInfo = AboutAppInfo(
        version: "0.1.0",
        copyright: "Copyright © 2026 bloodybear"
    )

    @Test
    func appInfoUsesFallbackForMissingBundleValues() {
        let info = AboutAppInfo(version: nil, copyright: nil)

        #expect(info.version == AboutAppInfo.missingValue)
        #expect(info.copyright == AboutAppInfo.missingValue)
    }

    @Test
    func aboutCatalogIsCompleteForEverySupportedLanguage() {
        let keys = [
            "Rearview 정보…",
            "버전 %@"
        ]

        for language in AppDisplayLanguage.allCases {
            for key in keys {
                #expect(L10n.hasTranslation(for: key, language: language))
            }
        }
    }

    @Test @MainActor
    func aboutWindowShowsLocalizedContentAndFits() {
        for language in AppDisplayLanguage.allCases {
            let controller = AboutWindowController(appInfo: appInfo, language: language)
            controller.showWindow(nil)
            defer { controller.window?.orderOut(nil) }
            controller.window?.contentView?.layoutSubtreeIfNeeded()

            #expect(controller.window?.title == "Rearview")
            let contentView = controller.window?.contentView
            let nameLabel = aboutTextField("about-app-name", in: contentView)
            let iconView = aboutImageView("about-app-icon", in: contentView)
            let versionLabel = aboutTextField("about-version", in: contentView)
            let copyrightLabel = aboutTextField("about-copyright", in: contentView)
            let githubLink = aboutTextField("about-github-link", in: contentView)

            #expect(nameLabel?.stringValue == "Rearview")
            #expect(nameLabel?.font?.pointSize == 20)
            #expect(contentView?.frame.size == CGSize(width: 360, height: 240))
            #expect(versionLabel?.stringValue == L10n.format(
                "버전 %@", appInfo.version, language: language
            ))
            #expect(copyrightLabel?.stringValue == appInfo.copyright)
            #expect(githubLink?.stringValue == AboutWindowController.githubURL.absoluteString)
            #expect((iconView?.frame.minY ?? 0) > (nameLabel?.frame.maxY ?? 0))
            #expect((nameLabel?.frame.minY ?? 0) > (versionLabel?.frame.maxY ?? 0))
            #expect((versionLabel?.frame.minY ?? 0) > (copyrightLabel?.frame.maxY ?? 0))
            #expect((copyrightLabel?.frame.minY ?? 0) > (githubLink?.frame.maxY ?? 0))
            #expect(githubLink?.frame.minX == nameLabel?.frame.minX)
            #expect(githubLink?.frame.maxX == nameLabel?.frame.maxX)
            #expect(!hasAmbiguousLayout(in: contentView))
            #expect(contentFits(contentView))
        }
    }

    @Test @MainActor
    func githubLinkDisplaysAndTargetsTheHTTPSURL() {
        let controller = AboutWindowController(appInfo: appInfo, language: .english)
        let githubLink = aboutTextField(
            "about-github-link", in: controller.window?.contentView
        )
        let linkAttribute = githubLink?.attributedStringValue.attribute(
            .link, at: 0, effectiveRange: nil
        ) as? URL
        let paragraphStyle = githubLink?.attributedStringValue.attribute(
            .paragraphStyle, at: 0, effectiveRange: nil
        ) as? NSParagraphStyle

        #expect(githubLink?.stringValue == "https://github.com/bloodybear/rearview")
        #expect(linkAttribute == AboutWindowController.githubURL)
        #expect(paragraphStyle?.alignment == .center)
        #expect(githubLink?.isSelectable == true)
        #expect(githubLink?.allowsEditingTextAttributes == true)
    }

    @Test @MainActor
    func showingAgainReusesTheSameWindow() {
        let controller = AboutWindowController(appInfo: appInfo, language: .english)
        controller.showWindow(nil)
        let firstWindow = controller.window
        controller.window?.orderOut(nil)
        controller.showWindow(nil)

        #expect(controller.window === firstWindow)
        #expect(controller.window?.isVisible == true)
        controller.window?.orderOut(nil)
    }

    @Test @MainActor
    func statusMenuPlacesAboutImmediatelyBeforeQuit() {
        let delegate = AppDelegate()
        let menu = delegate.statusMenuForTesting()
        let visibleItems = menu.items.filter { !$0.isHidden }
        let aboutTitle = L10n.text("Rearview 정보…")
        let quitTitle = L10n.text("종료")

        #expect(visibleItems.count >= 2)
        #expect(visibleItems[visibleItems.count - 2].title == aboutTitle)
        #expect(visibleItems.last?.title == quitTitle)

        if let aboutIndex = menu.items.firstIndex(where: { $0.title == aboutTitle }) {
            #expect(aboutIndex > 0)
            #expect(menu.items[aboutIndex - 1].isSeparatorItem)
            #expect(aboutIndex + 1 < menu.items.count)
            #expect(menu.items[aboutIndex + 1].title == quitTitle)
        } else {
            Issue.record("About menu item is missing")
        }
    }

    @MainActor
    private func aboutTextField(_ identifier: String, in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let field = view as? NSTextField,
           field.accessibilityIdentifier() == identifier { return field }
        return view.subviews.lazy.compactMap { aboutTextField(identifier, in: $0) }.first
    }

    @MainActor
    private func aboutImageView(_ identifier: String, in view: NSView?) -> NSImageView? {
        guard let view else { return nil }
        if let imageView = view as? NSImageView,
           imageView.accessibilityIdentifier() == identifier { return imageView }
        return view.subviews.lazy.compactMap { aboutImageView(identifier, in: $0) }.first
    }

    @MainActor
    private func hasAmbiguousLayout(in view: NSView?) -> Bool {
        guard let view else { return false }
        return view.hasAmbiguousLayout || view.subviews.contains { hasAmbiguousLayout(in: $0) }
    }

    @MainActor
    private func contentFits(_ view: NSView?) -> Bool {
        guard let view else { return false }
        view.layoutSubtreeIfNeeded()
        return view.subviews.allSatisfy { subview in
            view.bounds.contains(subview.frame) && contentFits(subview)
        }
    }

}
