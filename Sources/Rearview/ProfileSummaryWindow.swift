import AppKit
import UniformTypeIdentifiers

@MainActor
final class ProfileSummaryWindowController: NSWindowController {
    private var report: SessionReport?
    private var files: (json: URL, csv: URL)?
    private weak var summaryTextView: NSTextView?
    private var actionButtons: [NSButton] = []

    convenience init(report: SessionReport, files: (json: URL, csv: URL)?) {
        let controller = NSViewController()
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 760, height: 620))
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 46, width: 760, height: 574))
        let textView = NSTextView(frame: scroll.bounds)
        textView.isEditable = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.string = Self.summary(report: report, files: files)
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        container.addSubview(scroll)
        controller.view = container
        let window = NSWindow(contentViewController: controller)
        window.title = report.metadata.benchmark
            ? L10n.text("벤치마크 성능 결과") : L10n.text("성능 프로파일 결과")
        window.setContentSize(CGSize(width: 760, height: 620))
        self.init(window: window)
        self.report = report
        self.files = files
        summaryTextView = textView
        let buttons = [
            NSButton(title: L10n.text("JSON 다른 이름으로 저장…"), target: self, action: #selector(exportJSON)),
            NSButton(title: L10n.text("CSV 다른 이름으로 저장…"), target: self, action: #selector(exportCSV)),
            NSButton(title: L10n.text("보고서 폴더 열기"), target: self, action: #selector(openReportFolder))
        ]
        actionButtons = buttons
        var x: CGFloat = 12
        for button in buttons {
            button.frame = CGRect(x: x, y: 10, width: 190, height: 26)
            container.addSubview(button)
            x += 198
        }
    }

    func refreshLocalization() {
        guard let report else { return }
        window?.title = report.metadata.benchmark
            ? L10n.text("벤치마크 성능 결과") : L10n.text("성능 프로파일 결과")
        summaryTextView?.string = Self.summary(report: report, files: files)
        let titles = [
            L10n.text("JSON 다른 이름으로 저장…"),
            L10n.text("CSV 다른 이름으로 저장…"),
            L10n.text("보고서 폴더 열기")
        ]
        for (button, title) in zip(actionButtons, titles) { button.title = title }
    }

    @objc private func exportJSON() { export(source: files?.json, fileType: "json") }
    @objc private func exportCSV() { export(source: files?.csv, fileType: "csv") }
    @objc private func openReportFolder() {
        guard let folder = files?.json.deletingLastPathComponent() else { return }
        NSWorkspace.shared.open(folder)
    }

    private func export(source: URL?, fileType: String) {
        guard let source else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = fileType == "json" ? [.json] : [.commaSeparatedText]
        panel.nameFieldStringValue = source.lastPathComponent
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }

    private static func summary(report: SessionReport, files: (json: URL, csv: URL)?) -> String {
        var lines = [
            L10n.format(
                "측정 시간: %@초", String(format: "%.1f", report.metadata.durationSeconds)
            ),
            L10n.format(
                "선택 영역: %d × %d px",
                report.metadata.selectionWidth ?? 0, report.metadata.selectionHeight ?? 0
            ),
            "",
            L10n.text("단계                         count    p50       p95       max       total")
        ]
        for item in report.stages {
            lines.append(String(
                format: "%-27s %6d %8.2f %8.2f %8.2f %10.2f ms",
                (item.stage.title as NSString).utf8String!, item.count, item.p50Milliseconds,
                item.p95Milliseconds, item.maxMilliseconds, item.totalMilliseconds
            ))
        }
        let received = report.counter("frame.received")
        let dropped = report.counter("frame.throttled") + report.counter("frame.overwritten")
        let cacheHit = report.counter("translation.cacheHit")
        let cacheMiss = report.counter("translation.cacheMiss")
        let cacheRate = cacheHit + cacheMiss > 0 ? Double(cacheHit) / Double(cacheHit + cacheMiss) * 100 : 0
        let segmentHit = report.counter("translation.segmentCacheHit")
        let segmentMiss = report.counter("translation.segmentCacheMiss")
        let segmentRate = segmentHit + segmentMiss > 0
            ? Double(segmentHit) / Double(segmentHit + segmentMiss) * 100 : 0
        lines += [
            "", L10n.format("프레임 수신: %d, 손실/교체: %d", received, dropped),
            L10n.format("번역 캐시 적중률: %@%%", String(format: "%.1f", cacheRate)),
            L10n.format(
                "세그먼트 캐시 적중률: %@%%, 진행 중 요청 합류: %d",
                String(format: "%.1f", segmentRate), report.counter("translation.inFlightHit")
            )
        ]
        if report.counters.contains(where: { $0.name == "capture.filter.application" }) {
            let filter = report.counter("capture.filter.application") == 1
                ? L10n.text("단일 앱") : L10n.text("선택 영역 전체")
            lines.append(L10n.format("캡처 필터: %@", filter))
        }
        lines += ["", L10n.text("개선 제안")]
        lines += report.recommendations.enumerated().map {
            "\($0.offset + 1). \(L10n.text($0.element))"
        }
        if let files {
            lines += ["", "JSON: \(files.json.path)", "CSV:  \(files.csv.path)"]
        }
        if report.metadata.benchmark {
            lines += ["", L10n.text("내장 벤치마크 보고서에는 고정 공개 샘플의 OCR 원문이 포함됩니다. 번역문과 캡처 이미지는 포함되지 않습니다.")]
        } else {
            lines += ["", L10n.text("보고서에는 OCR 원문, 번역문 또는 캡처 이미지가 포함되지 않습니다.")]
        }
        return lines.joined(separator: "\n")
    }
}
