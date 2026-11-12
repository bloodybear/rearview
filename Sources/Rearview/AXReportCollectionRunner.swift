#if !LST_EXCLUDE_DEBUG_FEATURES
import AppKit
import NotionAXCore
import NotionAXReportSupport
@preconcurrency import Translation

@MainActor enum AXReportCollectionRunner {
    static func run() async -> Int32 {
        let skip = CommandLine.arguments.contains("--skip-translation")
        let directionIndex = CommandLine.arguments.firstIndex(of:"--ax-translation-direction")
        let directionValue = directionIndex.flatMap { $0+1 < CommandLine.arguments.count ? CommandLine.arguments[$0+1] : nil } ?? "ja-ko"
        guard ["ja-ko","ko-ja"].contains(directionValue) else { return 1 }
        let direction: TranslationDirection = directionValue == "ja-ko" ? .japaneseToKorean : .koreanToJapanese
        let broker = TranslationBroker(direction:direction)
        let coordinator = SessionCoordinator(broker:broker,createsOutputWindow:false,
            translatesAXParagraphs:!skip,initialTranslationDirection:direction)
        var worker: Task<Void,Never>?
        var translationSession: TranslationSession?
        defer { worker?.cancel(); if #available(macOS 26, *) { translationSession?.cancel() } }
        let previousRefresh = coordinator.currentRefreshMode
        defer { coordinator.setRefreshMode(previousRefresh) }
        do {
            _ = NSApplication.shared
            PerformanceProfiler.shared.start()
            defer { _ = PerformanceProfiler.shared.stop(translationDirection:direction) }
            let input = try AXReportInput(arguments:CommandLine.arguments)
            let preparationStart = Date()
            if !skip {
                guard #available(macOS 26, *) else { throw TranslatorError.translationSessionUnavailable }
                let session: TranslationSession
                if #available(macOS 26.4, *) {
                    session = TranslationSession(installedSource:direction.sourceLocale,target:direction.targetLocale,
                        preferredStrategy:TranslationStrategyPolicy.preferred())
                } else { session = TranslationSession(installedSource:direction.sourceLocale,target:direction.targetLocale) }
                translationSession = session
                worker = Task { @MainActor in await broker.run(session:session) }
                let readyDeadline = ContinuousClock.now + .seconds(15)
                while !broker.isReadyForTranslation && ContinuousClock.now < readyDeadline {
                    try await Task.sleep(for:.milliseconds(20))
                }
                // If preparation failed, preserve per-paragraph broker failures in the report.
            }
            let preparationSeconds = Date().timeIntervalSince(preparationStart)
            guard let screen = NSScreen.screens.first(where: {
                guard let id = $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
                return CGDisplayBounds(id.uint32Value).intersects(input.request.windowFrame)
            }), let display = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { throw TranslatorError.noDisplay }
            let repeatIndex = CommandLine.arguments.firstIndex(of:"--ax-repeat")
            let repeatCount = repeatIndex.flatMap { $0+1 < CommandLine.arguments.count ? Int(CommandLine.arguments[$0+1]) : nil } ?? 2
            guard (1...5).contains(repeatCount) else { throw CocoaError(.coderInvalidValue) }
            var samples: [[String:Any]] = []
            var translated: SessionCoordinator.AXTranslatedFrame?
            var finishedCount = 0
            var translationSamples: [[String:Any]] = []
            var translationStartedAt = Date()
            coordinator.onAXTranslationProgress = { translated = $0 }
            coordinator.onAXTranslation = { value in
                translated = value; finishedCount += 1
                translationSamples.append(["frameID":value.frame.frameID,
                    "elapsed":Date().timeIntervalSince(translationStartedAt),
                    "paragraphs":value.entries.count,
                    "failures":value.entries.filter { $0.status == "failed" }.count])
            }
            var collected: AXExtractionSnapshot?, frameID: UInt64?, failure: Error?
            coordinator.onAXExtraction = { snapshot, _, id in
                collected = snapshot; frameID = id
                translationStartedAt = Date()
                if skip { finishedCount += 1 }
                if var sample = (try? JSONSerialization.jsonObject(with:snapshot.metadata)) as? [String:Any] {
                    sample["frameID"] = id; samples.append(sample)
                }
            }
            coordinator.onAXExtractionError = { failure = $0 }
            await coordinator.setTextExtractionMode(.ax)
            coordinator.setRefreshMode(.automatic)
            coordinator.setPaused(false)
            // Track the replay's window, not the focused app/window.
            let target = CaptureApplication(processID:input.request.processID,bundleIdentifier:"notion.id",name:"Notion",
                anchorWindowID:input.request.windowID,anchorWindowFrame:input.request.windowFrame)
            let selection = appKitSelectionRect(for:input.request.selectionRegion,screenFrame:screen.frame,displayBounds:CGDisplayBounds(display.uint32Value))
            try await coordinator.start(screen:screen,selection:selection,captureTarget:.application(target))
            let deadline = ContinuousClock.now + .seconds(skip ? 60 : 540)
            var requestedRepeat = 0
            while finishedCount < repeatCount && failure == nil && ContinuousClock.now < deadline {
                try await Task.sleep(for:.milliseconds(50))
                if finishedCount > requestedRepeat && finishedCount < repeatCount {
                    requestedRepeat = finishedCount
                    coordinator.translateImmediately()
                }
            }
            if let failure { throw failure }
            guard let collected else { throw CocoaError(.coderValueNotFound) }
            let timedOut = finishedCount < repeatCount
            var exportEntries: [AXParagraphTranslation] = []
            if !skip {
                let completed = translated?.frame.frameID == frameID ? translated?.entries ?? [] : []
                exportEntries = collected.paragraphUnits.map { paragraph in
                    completed.first { $0.node == paragraph.node } ?? .timedOut(paragraph,direction:direction)
                }
            }
            let output = try input.write(collected,collector:"rearview",frameID:frameID,sessionCollections:samples)
            var metadata = try JSONSerialization.jsonObject(with:Data(contentsOf:output.appendingPathComponent("metadata.json"))) as! [String:Any]
            metadata["skipTranslation"] = skip
            metadata["translationSource"] = skip ? "disabled" : "rearview-session"
            metadata["translationPreparationSeconds"] = preparationSeconds
            metadata["translationPreparationError"] = broker.preparationError
            metadata["translationPreparationTimedOut"] = !skip && !broker.isReadyForTranslation && broker.preparationError == nil
            metadata["translationTimedOut"] = timedOut
            metadata["translationSessionReady"] = broker.isReadyForTranslation
            metadata["translationSamples"] = translationSamples
            if !skip {
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
                struct Export: Encodable { let frameID: UInt64; let entries: [AXParagraphTranslation] }
                try encoder.encode(Export(frameID:frameID ?? 0,entries:exportEntries))
                    .write(to:output.appendingPathComponent("native-translations.json"),options:.atomic)
            }
            try JSONSerialization.data(withJSONObject:metadata,options:[.prettyPrinted,.sortedKeys])
                .write(to:output.appendingPathComponent("metadata.json"),options:.atomic)
            if let profile = PerformanceProfiler.shared.stop(translationDirection:direction) {
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
                try encoder.encode(profile).write(to:output.appendingPathComponent("translation-profile.json"),options:.atomic)
            }
            await coordinator.stop()
            print(output.path)
            return timedOut || exportEntries.contains { $0.status == "failed" } ? 2 : 0
        } catch {
            await coordinator.stop()
            fputs("AX report collection failed: \(error)\n",stderr)
            return 1
        }
    }
}
#endif
