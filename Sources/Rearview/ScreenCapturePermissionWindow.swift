import AppKit

enum ScreenCapturePermissionWindowKind: CaseIterable {
    case introduction
    case recovery
}

@MainActor
final class ScreenCapturePermissionWindowController: NSWindowController, NSWindowDelegate {
    private let titleLabel = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let primaryButton = NSButton()
    private let settingsButton = NSButton()
    private let buttonSpacer = NSView()
    private let buttonStack = NSStackView()
    private let contentStack = NSStackView()
    private weak var rootView: NSView?
    private let kind: ScreenCapturePermissionWindowKind
    private var language: AppDisplayLanguage
    private var isChecking = false
    private var confirmedShortcutTitle: String?
    private var showsPermissionConfirmation = false

    var onContinue: (() -> Void)?
    var onOpenSystemSettings: (() -> Void)?
    var onRetryPermission: (() -> Void)?
    var onConfirmPermission: (() -> Void)?
    var onRecoveryWindowBecameKey: (() -> Void)?
    var onQuit: (() -> Void)?

    init(
        kind: ScreenCapturePermissionWindowKind,
        language: AppDisplayLanguage = .load()
    ) {
        self.kind = kind
        self.language = language

        let viewController = NSViewController()
        let rootView = NSView(frame: CGRect(x: 0, y: 0, width: 560, height: 220))
        viewController.view = rootView

        let window = NSWindow(contentViewController: viewController)
        window.title = "Rearview"
        window.styleMask = [.titled, .closable]
        window.setContentSize(CGSize(width: 560, height: 220))
        window.contentMinSize = CGSize(width: 520, height: 180)
        window.isReleasedWhenClosed = false

        super.init(window: window)

        self.rootView = rootView
        window.delegate = self
        configureView(in: rootView)
        refreshContent()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setChecking(_ checking: Bool) {
        isChecking = checking
        primaryButton.isEnabled = !checking
    }

    func showPermissionRequired() {
        showsPermissionConfirmation = false
        confirmedShortcutTitle = nil
        isChecking = false
        refreshContent()
    }

    func showPermissionConfirmed(selectionShortcutTitle: String?) {
        showsPermissionConfirmation = true
        confirmedShortcutTitle = selectionShortcutTitle
        isChecking = false
        refreshContent()
    }

    func refreshLocalization(language: AppDisplayLanguage = .load()) {
        self.language = language
        refreshContent()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if kind == .recovery, showsPermissionConfirmation { return true }
        onQuit?()
        return false
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard kind == .recovery, !showsPermissionConfirmation else { return }
        onRecoveryWindowBecameKey?()
    }

    @objc private func primaryButtonPressed() {
        guard !isChecking else { return }
        switch kind {
        case .introduction:
            onContinue?()
        case .recovery:
            if showsPermissionConfirmation {
                onConfirmPermission?()
            } else {
                onRetryPermission?()
            }
        }
    }

    @objc private func settingsButtonPressed() {
        onOpenSystemSettings?()
    }

    private func refreshContent() {
        clearDefaultButtons()

        switch kind {
        case .introduction:
            titleLabel.stringValue = text("화면 기록 권한이 필요합니다")
            messageLabel.stringValue = text(
                "Rearview는 선택한 화면 영역의 텍스트를 인식하고 번역합니다. 계속하려면 화면 기록 권한이 필요합니다."
            )
            primaryButton.title = text("계속")
            setButtons([primaryButton], defaultButton: primaryButton)

        case .recovery:
            if showsPermissionConfirmation {
                titleLabel.stringValue = text("화면 기록 권한이 확인되었습니다")
                if let confirmedShortcutTitle {
                    messageLabel.stringValue = L10n.format(
                        "%@을 눌러 번역할 화면 영역을 선택하세요. 메뉴바의 Rearview 아이콘에서 ‘영역 선택…’을 선택해 시작할 수도 있습니다.",
                        confirmedShortcutTitle,
                        language: language
                    )
                } else {
                    messageLabel.stringValue = text(
                        "메뉴바의 Rearview 아이콘에서 ‘영역 선택…’을 선택해 시작하세요."
                    )
                }
                primaryButton.title = text("확인")
                setButtons([primaryButton], defaultButton: primaryButton)
            } else {
                titleLabel.stringValue = text("화면 기록 권한이 필요합니다")
                messageLabel.stringValue = text(
                    "시스템 설정에서 Rearview의 화면 기록 권한을 켜 주세요."
                )
                primaryButton.title = text("다시 확인")
                settingsButton.title = text("시스템 설정 열기")
                setButtons(
                    [primaryButton, settingsButton],
                    defaultButton: settingsButton
                )
            }
        }

        primaryButton.isEnabled = !isChecking
        settingsButton.isEnabled = true
        resizeToFitContent()
    }

    private func text(_ key: String) -> String {
        L10n.text(key, language: language)
    }

    private func configureView(in rootView: NSView) {
        titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        titleLabel.maximumNumberOfLines = 1
        titleLabel.setAccessibilityIdentifier("screen-capture-permission-title")

        messageLabel.font = .systemFont(ofSize: 13)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.maximumNumberOfLines = 0
        messageLabel.preferredMaxLayoutWidth = 504
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.setAccessibilityIdentifier("screen-capture-permission-message")

        configure(
            primaryButton,
            action: #selector(primaryButtonPressed),
            identifier: "screen-capture-permission-request"
        )
        configure(
            settingsButton,
            action: #selector(settingsButtonPressed),
            identifier: "screen-capture-permission-settings"
        )
        buttonSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        buttonSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        buttonStack.orientation = .horizontal
        buttonStack.alignment = .centerY
        buttonStack.spacing = 8
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        buttonStack.setAccessibilityIdentifier("screen-capture-permission-actions")

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 14
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(titleLabel)
        contentStack.addArrangedSubview(messageLabel)
        rootView.addSubview(contentStack)
        rootView.addSubview(buttonStack)

        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 28),
            contentStack.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -28),
            contentStack.topAnchor.constraint(equalTo: rootView.topAnchor, constant: 28),
            contentStack.bottomAnchor.constraint(
                lessThanOrEqualTo: buttonStack.topAnchor,
                constant: -14
            ),
            messageLabel.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            buttonStack.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 28),
            buttonStack.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -28),
            buttonStack.bottomAnchor.constraint(equalTo: rootView.bottomAnchor, constant: -24),
            buttonStack.heightAnchor.constraint(equalToConstant: 28)
        ])
    }

    private func configure(_ button: NSButton, action: Selector, identifier: String) {
        button.target = self
        button.action = action
        button.bezelStyle = .rounded
        button.setAccessibilityIdentifier(identifier)
    }

    private func setButtons(_ buttons: [NSButton], defaultButton: NSButton?) {
        buttonStack.arrangedSubviews.forEach {
            buttonStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        buttonStack.addArrangedSubview(buttonSpacer)
        buttons.forEach { buttonStack.addArrangedSubview($0) }
        defaultButton?.keyEquivalent = "\r"
    }

    private func clearDefaultButtons() {
        primaryButton.keyEquivalent = ""
        settingsButton.keyEquivalent = ""
    }

    private func resizeToFitContent() {
        guard let window, let rootView else { return }
        rootView.layoutSubtreeIfNeeded()
        let contentHeight = ceil(contentStack.fittingSize.height + 14 + 28 + 52)
        window.setContentSize(CGSize(width: 560, height: max(180, contentHeight)))
        rootView.layoutSubtreeIfNeeded()
    }
}
