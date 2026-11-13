#if !LST_EXCLUDE_DEBUG_FEATURES
import AppKit
import NotionAXCore
import NotionAXReportSupport
@preconcurrency import Translation

@MainActor enum AXReportCollectionRunner {
    // Native product views over a captured product frame; no capture permission
    // or model requests are needed to review an already collected report.
    static func reviewSaved() async -> Int32 {
        do {
            guard let index = CommandLine.arguments.firstIndex(of:"--review-ax-report"), index+1 < CommandLine.arguments.count else { return 1 }
            let folder = URL(fileURLWithPath:CommandLine.arguments[index+1])
            func read(_ name:String) throws -> Data { try Data(contentsOf:folder.appendingPathComponent(name)) }
            let snapshot = try AXExtractionSnapshot(nodes:read("rawAx.json"),selected:read("candidate.json"),paragraphs:read("native-paragraphs.json"),metadata:read("metadata.json"))
            struct Export: Decodable { let frameID: UInt64; let entries: [AXParagraphTranslation] }
            let translations = try JSONDecoder().decode(Export.self,from:read("native-translations.json"))
            let metadata = try JSONSerialization.jsonObject(with:read("metadata.json")) as! [String:Any]
            guard (metadata["frameID"] as? NSNumber)?.uint64Value == translations.frameID,
                  let image = NSBitmapImageRep(data:try read("render-source.png"))?.cgImage,
                  let region = metadata["selectionRegion"] as? [String:Double],
                  let screen = NSScreen.screens.first else { throw CocoaError(.coderInvalidValue) }
            let captured = SessionCoordinator.AXTranslatedFrame(frame:.init(snapshot:snapshot,image:image,frameID:translations.frameID,receivedAt:0),entries:translations.entries)
            fputs("AX review: loaded captured frame\n",stderr)
            let art = await AXLineRendering.render(captured)
            fputs("AX review: layout ready\n",stderr)
            var frame = MirrorFrame(image:image,translatedItems:art.items,frameID:translations.frameID)
            frame.axArtwork = art
            let display = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber
            let selection = appKitSelectionRect(for:CGRect(x:region["x"]!,y:region["y"]!,width:region["width"]!,height:region["height"]!),screenFrame:screen.frame,displayBounds:CGDisplayBounds(display.uint32Value))
            let modeIndex = CommandLine.arguments.firstIndex(of:"--ax-review-display-mode")
            let modeValue = modeIndex.flatMap { $0+1 < CommandLine.arguments.count ? CommandLine.arguments[$0+1] : nil } ?? "mirror"
            guard let mode = TranslationDisplayMode(rawValue:modeValue) else { throw CocoaError(.coderInvalidValue) }
            NSApplication.shared.setActivationPolicy(.regular)
            let window = TranslationMirrorWindow(selection:selection,screen:screen,backgroundOpacity:MirrorBackgroundOpacity.load(),displayMode:mode,overlaySettings:OverlayPresentationSettings.load())
            window.title = "AX 렌더링 검토 · 수집 프레임"
            window.setDebugFeaturesEnabled(true); window.display(frame)
            fputs("AX review: window ready\n",stderr)
            let i = CommandLine.arguments.firstIndex(of:"--ax-review-seconds")
            let seconds = i.flatMap { $0+1 < CommandLine.arguments.count ? Double(CommandLine.arguments[$0+1]) : nil } ?? 180
            let deadline = ContinuousClock.now + .seconds(min(600,max(0,seconds)))
            while ContinuousClock.now < deadline {
                try await Task.sleep(for:.milliseconds(50))
            }
            window.close()
            return 0
        } catch { fputs("AX saved-frame review failed: \(error)\n",stderr); return 1 }
    }
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
            let showsWindow = CommandLine.arguments.contains("--show-ax-render")
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
                    "elapsed":max(0,Date().timeIntervalSince(translationStartedAt)-(coordinator.latestAXRenderedFrame?.axArtwork?.elapsed ?? 0)),
                    "renderSeconds":coordinator.latestAXRenderedFrame?.axArtwork?.elapsed ?? 0,
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
            if let frame = coordinator.latestAXRenderedFrame, frame.frameID == frameID, let art = frame.axArtwork {
                func png(_ image: CGImage?, _ name: String) throws {
                    guard let image else { return }
                    let bitmap = NSBitmapImageRep(cgImage:image)
                    try bitmap.representation(using:.png,properties:[:])?.write(to:output.appendingPathComponent(name))
                }
                try png(frame.image,"render-source.png")
                let view = NativeTranslationMirrorView(frame:CGRect(x:0,y:0,width:frame.image.width,height:frame.image.height))
                view.setRenderingActive(true); view.backgroundOpacity = 1; view.frameSnapshot = frame
                if let result = view.compositedImage(), let tiff = result.tiffRepresentation, let bitmap = NSBitmapImageRep(data:tiff) {
                    try bitmap.representation(using:.png,properties:[:])?.write(to:output.appendingPathComponent("render-translated.png"))
                }
                try png(art.debug,"render-debug.png")
                try JSONSerialization.data(withJSONObject:["frameID":frame.frameID,
                    "clipRects":art.clipRects.map { ["x":$0.minX,"y":$0.minY,"width":$0.width,"height":$0.height] },
                    "fragments":art.fragments.map { ["text":$0.text,"offset":$0.characterOffset,"x":$0.rect.minX,"y":$0.rect.minY,"width":$0.rect.width,"height":$0.rect.height] }],options:[.sortedKeys,.prettyPrinted])
                    .write(to:output.appendingPathComponent("render-geometry.json"))
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
                try encoder.encode(art.diagnostics).write(to:output.appendingPathComponent("render-layout.json"))
                metadata["renderFrameID"] = frame.frameID
                metadata["renderSeconds"] = art.elapsed
            }
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
            if showsWindow {
                let index = CommandLine.arguments.firstIndex(of:"--ax-review-seconds")
                let seconds = index.flatMap { $0+1 < CommandLine.arguments.count ? Double(CommandLine.arguments[$0+1]) : nil } ?? 180
                let review = Process(); review.executableURL = URL(fileURLWithPath:"/usr/bin/open")
                review.arguments = ["-n","-g","-W","-a",Bundle.main.bundleURL.path,"--args","--review-ax-report",output.path,"--ax-review-seconds",String(min(600,max(0,seconds)))]
                review.standardOutput = FileHandle.standardError
                try review.run()
                while review.isRunning { try await Task.sleep(for:.milliseconds(50)) }
                guard review.terminationStatus == 0 else { throw CocoaError(.executableRuntimeMismatch) }
            }
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
