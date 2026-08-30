import AppKit

final class FixtureDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var activity: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical],
            reason: "Rearview reproducible benchmark animation"
        )
        guard let screen = NSScreen.main else { return }
        let frame = BenchmarkGeometry.frame(in: screen.visibleFrame)
        let window = NSWindow(
            contentRect: frame, styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        window.title = "Rearview 성능 벤치마크"
        window.contentView = BenchmarkView(frame: CGRect(origin: .zero, size: frame.size))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
    }
}

enum BenchmarkGeometry {
    static func frame(in visibleFrame: CGRect) -> CGRect {
        let size = CGSize(width: min(1000, visibleFrame.width - 40), height: min(700, visibleFrame.height - 60))
        return CGRect(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.midY - size.height / 2,
            width: size.width, height: size.height
        )
    }
}

final class BenchmarkView: NSView {
    private let started = ProcessInfo.processInfo.systemUptime
    private var timer: Timer?
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.needsDisplay = true }
        }
        timer.tolerance = 0.001
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        let phase = elapsed.truncatingRemainder(dividingBy: 30)
        let scene = phase >= 22 ? Int((phase - 22) / 1.5).isMultiple(of: 2) : false
        (scene ? NSColor(calibratedRed: 0.09, green: 0.12, blue: 0.18, alpha: 1) : .white).setFill()
        bounds.fill()

        let scroll = phase >= 8 && phase < 22 ? (phase - 8) * 95 : 0
        let lines = [
            "リアルタイム翻訳の性能測定画面", "設定を保存して次のページへ進みます",
            "Start ボタン을 2回押してください", "ネットワーク接続は使用しません",
            "画面をスクロールすると翻訳も追従します", "英語 English と 한국어는 그대로 유지됩니다",
            "한국어 전용 문장은 원문 그대로 선택합니다",
            "高密度な文章でも一秒以内の応答を目標にします", "文字認識と翻訳モデルは端末上で動作します",
            "新しい画面へ切り替わると以前の表示を消去します", "ボタンの上に翻訳を表示してもクリックできます",
            "長い翻訳文は文字を縮小して二行まで表示します", "これは再現可能なベンチマーク用の文章です"
        ]
        let foreground = scene ? NSColor.white : NSColor(calibratedWhite: 0.12, alpha: 1)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 21, weight: .regular),
            .foregroundColor: foreground
        ]
        for repetition in 0..<4 {
            for (index, line) in lines.enumerated() {
                let y = 32 + CGFloat(repetition * lines.count + index) * 49 - CGFloat(scroll.truncatingRemainder(dividingBy: 49 * Double(lines.count)))
                (line as NSString).draw(
                    at: CGPoint(x: 38 + CGFloat((index % 3) * 7), y: y),
                    withAttributes: attributes
                )
            }
        }
        let label = phase < 8 ? "STATIC" : phase < 22 ? "SCROLL" : "SCENE CUT"
        let badge: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .bold),
            .foregroundColor: NSColor.systemOrange
        ]
        (label as NSString).draw(
            at: CGPoint(x: bounds.maxX - 110, y: 10),
            withAttributes: badge
        )
    }
}

let app = NSApplication.shared
let delegate = FixtureDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
