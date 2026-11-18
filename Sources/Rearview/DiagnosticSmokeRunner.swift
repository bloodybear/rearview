#if !LST_EXCLUDE_DEBUG_FEATURES
import AppKit
@preconcurrency import Translation

/// Developer-only validation: real capture + Vision + installed production translation + native mirror.
@MainActor enum DiagnosticSmokeRunner {
    private final class Output:SessionOutputSink {
        var finished=false
        func display(_ frame:MirrorFrame) {}
        func showProcessingStatus(_ status:MirrorProcessingStatus,frameID:UInt64) { if case .completed=status { finished=true } }
        func cancelProcessingStatus() {}
    }
    static func runOCR() async -> Int32 {
        guard #available(macOS 26,*) else { return 1 }
        let previousRefresh=RefreshMode.load()
        defer { previousRefresh.save() }
        var coordinator:SessionCoordinator?
        var session:TranslationSession?
        var worker:Task<Void,Never>?
        do {
            guard let index=CommandLine.arguments.firstIndex(of:"--diagnostic-ocr-smoke"),index+1<CommandLine.arguments.count else { return 1 }
            let destination=URL(fileURLWithPath:CommandLine.arguments[index+1])
            guard let fixture=NSRunningApplication.runningApplications(withBundleIdentifier:"io.github.bloodybear.rearview.benchmark").first,
                  let screen=NSScreen.main,
                  let window=(CGWindowListCopyWindowInfo(.optionOnScreenOnly,kCGNullWindowID) as? [[String:Any]])?.first(where: { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value==fixture.processIdentifier && ($0[kCGWindowLayer as String] as? NSNumber)?.intValue==0 }),
                  let bounds=window[kCGWindowBounds as String] as? [String:Any],let frame=CGRect(dictionaryRepresentation:bounds as CFDictionary),
                  let windowID=(window[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let display=(screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { throw CocoaError(.coderValueNotFound) }
            let broker=TranslationBroker(direction:.japaneseToKorean,protectsNonSourceText:false)
            let installed:TranslationSession
            if #available(macOS 26.4,*) { installed=TranslationSession(installedSource:Locale.Language(identifier:"ja"),target:Locale.Language(identifier:"ko"),preferredStrategy:TranslationStrategyPolicy.preferred()) }
            else { installed=TranslationSession(installedSource:Locale.Language(identifier:"ja"),target:Locale.Language(identifier:"ko")) }
            session=installed;worker=Task { await broker.run(session:installed) }
            let prepareDeadline=ContinuousClock.now + .seconds(15)
            while !broker.isReadyForTranslation,broker.preparationError == nil,ContinuousClock.now<prepareDeadline { try await Task.sleep(for:.milliseconds(20)) }
            let output=Output()
            let c=SessionCoordinator(broker:broker,outputSink:output,createsOutputWindow:true,initialTranslationDirection:.japaneseToKorean,initialTextExtractionMode:.ocr)
            coordinator=c
            NSApplication.shared.setActivationPolicy(.regular)
            try await c.start(screen:screen,selection:appKitSelectionRect(for:frame,screenFrame:screen.frame,displayBounds:CGDisplayBounds(display)),captureTarget:.application(.init(processID:fixture.processIdentifier,bundleIdentifier:fixture.bundleIdentifier!,name:"BenchmarkFixture",anchorWindowID:windowID,anchorWindowFrame:frame)))
            c.setRefreshMode(.automatic);c.setPaused(false)
            let deadline=ContinuousClock.now + .seconds(25)
            while !output.finished,ContinuousClock.now<deadline { try await Task.sleep(for:.milliseconds(25)) }
            c.setPaused(true)
            try await Task.sleep(for:.milliseconds(150)) // Let the submitted frame's actual AppKit draw finish.
            let snapshot=c.diagnosticSnapshot()
            let manifest=try await Task.detached { try DiagnosticBundleWriter.write(snapshot,options:.init(),destination:destination) }.value
            await c.stop();worker?.cancel();installed.cancel()
            guard output.finished,manifest.frames.contains(where: { $0.files.contains("composite.png") }) else { throw CocoaError(.coderValueNotFound) }
            print(destination.path);return 0
        } catch {
            if let coordinator { await coordinator.stop() }
            worker?.cancel();session?.cancel();fputs("Diagnostic OCR smoke failed: \(error)\n",stderr);return 1
        }
    }
}
#endif
