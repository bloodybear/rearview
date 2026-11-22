import AppKit
import UniformTypeIdentifiers

@MainActor final class DiagnosticExportController: NSObject {
    static let shared = DiagnosticExportController()
    private var busy = false
    var isExporting:Bool { busy }
    private var worker: Task<DiagnosticManifest,Error>?
    private var progressPanel: NSPanel?
    func present(_ snapshot:DiagnosticSnapshot) {
        guard !busy else { progressPanel?.orderFrontRegardless();return }
        busy=true
        let alert=NSAlert()
        alert.messageText=L10n.text("진단 자료 저장")
        alert.informativeText=DiagnosticBundleWriter.warning
        alert.addButton(withTitle:L10n.text("저장…"));alert.addButton(withTitle:L10n.text("취소"))
        let symptom=NSPopUpButton(frame:.zero,pullsDown:false)
        let labels=["번역 실패","화면 미표시·갱신 멈춤","인식·번역 누락","결과 부정확","기타"]
        symptom.addItems(withTitles:labels.map { L10n.text($0) })
        let scope=NSPopUpButton(frame:.zero,pullsDown:false)
        scope.addItems(withTitles:[L10n.text("최근 로그 포함"),L10n.text("현재 화면만")])
        scope.selectItem(at:0)
        scope.setAccessibilityLabel(L10n.text("진단 자료 범위"))
        let scopeHint=NSTextField(wrappingLabelWithString:L10n.text("최근 로그 포함은 최근 처리 기록과 보관된 프레임을 저장합니다. 현재 화면만은 표시 중인 화면을 만드는 데 쓰인 자료와 관련 프레임 로그를 저장합니다."))
        scopeHint.font = .systemFont(ofSize:11)
        let description=NSTextField(string:"");description.placeholderString=L10n.text("문제 설명 (선택 사항)")
        let include=NSButton(checkboxWithTitle:L10n.text("화면 이미지·문서 원문·번역문 포함"),target:nil,action:nil);include.state = .on
        let hint=NSTextField(wrappingLabelWithString:L10n.text("설명에 입력한 내용은 위 선택과 관계없이 포함됩니다."))
        hint.font = .systemFont(ofSize:11);hint.textColor = .secondaryLabelColor
        let stack=NSStackView(views:[symptom,scope,scopeHint,description,include,hint]);stack.orientation = .vertical;stack.alignment = .leading;stack.spacing=10
        stack.frame=NSRect(x:0,y:0,width:430,height:224)
        description.widthAnchor.constraint(equalToConstant:420).isActive=true
        scopeHint.widthAnchor.constraint(equalToConstant:420).isActive=true
        alert.accessoryView=stack
        guard alert.runModal() == .alertFirstButtonReturn else { busy=false;return }
        let panel=NSSavePanel();panel.allowedContentTypes=[.zip]
        let date=ISO8601DateFormatter().string(from:Date()).replacingOccurrences(of:":",with:"-")
        panel.nameFieldStringValue="Rearview-Diagnostics-\(date).zip"
        guard panel.runModal() == .OK, let destination=panel.url else { busy=false;return }
        let codes=["translation_failure","no_display_or_stalled","missing_text","inaccurate_result","other"]
        let options=DiagnosticExportOptions(includesContent:include.state == .on,symptom:codes[symptom.indexOfSelectedItem],description:description.stringValue,includesRecentLogs:scope.indexOfSelectedItem == 0)
        let progress=NSPanel(contentRect:NSRect(x:0,y:0,width:340,height:110),styleMask:[.titled],backing:.buffered,defer:false)
        progress.title=L10n.text("진단 자료 저장 중…");progress.isReleasedWhenClosed=false
        let spinner=NSProgressIndicator(frame:NSRect(x:20,y:58,width:24,height:24));spinner.style = .spinning;spinner.startAnimation(nil)
        let label=NSTextField(labelWithString:L10n.text("진단 자료를 ZIP으로 묶고 있습니다."));label.frame=NSRect(x:56,y:57,width:270,height:24)
        let cancel=NSButton(title:L10n.text("취소"),target:self,action:#selector(cancelExport));cancel.frame=NSRect(x:240,y:14,width:80,height:28)
        progress.contentView?.addSubview(spinner);progress.contentView?.addSubview(label);progress.contentView?.addSubview(cancel)
        progress.center();progress.orderFrontRegardless();progressPanel=progress
        let work=Task.detached(priority:.utility) { try DiagnosticBundleWriter.write(snapshot,options:options,destination:destination) }
        worker=work
        Task { @MainActor in
            defer { self.busy=false;self.worker=nil;self.progressPanel?.close();self.progressPanel=nil }
            do {
                let manifest=try await work.value
                progress.orderOut(nil)
                let done=NSAlert();done.messageText=L10n.text("진단 자료를 저장했습니다.")
                let incomplete = !manifest.omissions.isEmpty || manifest.frames.contains { !$0.omissions.isEmpty }
                done.informativeText=incomplete ? L10n.text("일부 자료가 없거나 제외되었습니다. 누락 사유는 ZIP 안에 기록되어 있습니다. 파일은 자동으로 전송되지 않습니다.") : L10n.text("파일은 자동으로 전송되지 않습니다. 민감한 내용을 확인한 후 개발자에게 직접 전달해 주세요.")
                done.addButton(withTitle:L10n.text("Finder에서 보기"));done.addButton(withTitle:L10n.text("닫기"))
                if done.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.activateFileViewerSelecting([destination]) }
            } catch is CancellationError { }
            catch { progress.orderOut(nil);let failed=NSAlert();failed.messageText=L10n.text("진단 자료 저장 실패");failed.informativeText=error.localizedDescription;failed.runModal() }
        }
    }
    @objc private func cancelExport() { worker?.cancel() }
}
