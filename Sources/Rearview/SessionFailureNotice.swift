import AppKit
import NotionAXCore

struct SessionFailure: Equatable {
    enum Stage: String { case capture, ax, ocr, translation }
    enum Permission: String { case accessibility, screenCapture }
    let stage: Stage
    let permission: Permission?
    let message: String
    var key: String { "\(stage.rawValue):\(permission?.rawValue ?? message)" }

    static func make(_ error: Error?, stage: Stage) -> Self {
        if let ax = error as? AXExtractionError, ax == .permissionDenied {
            return Self(stage: stage, permission: .accessibility, message: L10n.text("손쉬운 사용 권한이 없어 AX 수집을 시작할 수 없습니다."))
        }
        let ns = error as NSError?
        let screenDenied = (error as? TranslatorError).map { if case .screenPermission = $0 { return true }; return false } ?? false
        if screenDenied || (ns?.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain" && ns?.code == -3801) {
            return Self(stage: stage, permission: .screenCapture, message: L10n.text("화면 기록 권한이 없어 화면을 캡처할 수 없습니다."))
        }
        let message: String
        switch stage {
        case .capture: message = L10n.text("화면 캡처에 실패했습니다.")
        case .ocr: message = L10n.text("화면의 글자 인식에 실패했습니다.")
        case .translation: message = L10n.text("번역에 실패했습니다.")
        case .ax:
            switch error as? AXExtractionError {
            case .targetTerminated: message = L10n.text("대상 앱 또는 창이 종료되어 AX 수집에 실패했습니다.")
            case .windowMappingFailed, .windowChanged: message = L10n.text("대상 창을 확인할 수 없어 AX 수집에 실패했습니다.")
            default: message = L10n.text("앱의 텍스트를 가져오는 AX 수집에 실패했습니다.")
            }
        }
        return Self(stage: stage, permission: nil, message: message)
    }
}

/// Deduplication is tied to a stage/target, not a frame or content revision.
struct SessionFailureDeduplicator {
    private var failures: [SessionFailure.Stage: String] = [:]
    mutating func shouldPresent(_ failure: SessionFailure, userInitiated: Bool) -> Bool {
        let previous = failures.updateValue(failure.key, forKey: failure.stage)
        return userInitiated || previous != failure.key
    }
    mutating func succeeded(_ stage: SessionFailure.Stage) { failures[stage] = nil }
    mutating func reset() { failures.removeAll() }
}

private final class FailureNoticePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class SessionFailureNotice: NSObject {
    private var panel: NSPanel?
    private var expiry: Task<Void, Never>?
    private var current: SessionFailure?
    var openSettings: (URL) -> Bool = { NSWorkspace.shared.open($0) }
    func show(_ failure: SessionFailure, anchor: NSWindow?, anchorRect: CGRect? = nil) {
        dismiss()
        current = failure
        let button = NSButton(title: failure.message + (failure.permission == nil ? "" : L10n.text(" · 클릭하여 권한 설정 열기")), target: self, action: #selector(activate))
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: 12)
        button.setAccessibilityLabel(button.title)
        let width = min(620, max(260, button.intrinsicContentSize.width + 24))
        let panel = FailureNoticePanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 44), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        button.frame = panel.contentView!.bounds.insetBy(dx: 6, dy: 6)
        button.autoresizingMask = [.width, .height]
        panel.contentView?.addSubview(button)
        let bounds = anchor?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let anchorFrame = anchorRect ?? anchor?.frame
        panel.setFrameOrigin(NSPoint(x: min(max(bounds.minX, (anchorFrame?.midX ?? bounds.midX) - width / 2), bounds.maxX - width), y: max(bounds.minY, (anchorRect?.minY ?? (anchorFrame?.maxY ?? bounds.maxY) - 46) - 48)))
        self.panel = panel
        panel.orderFrontRegardless()
        expiry = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }
    @objc func activate() {
        guard let permission = current?.permission else { dismiss(); return }
        let pane = permission == .accessibility ? "Privacy_Accessibility" : "Privacy_ScreenCapture"
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
        if openSettings(url) { dismiss() }
        else {
            let name = permission == .accessibility ? L10n.text("손쉬운 사용") : L10n.text("화면 기록")
            show(SessionFailure(stage: current!.stage, permission: nil, message: L10n.format("시스템 설정 → 개인정보 보호 및 보안 → %@에서 권한을 허용하세요.", name)), anchor: nil)
        }
    }
    func dismiss() {
        expiry?.cancel(); expiry = nil
        panel?.orderOut(nil); panel = nil; current = nil
    }
}
