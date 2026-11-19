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
            let savedImages = (try? JSONDecoder().decode([AXImageOCRSavedLayer].self,from:read("image-ocr-layers.json"))) ?? []
            let imageLayers = savedImages.compactMap { layer in
                layer.restore(source:image,savedImage:layer.imageFile.flatMap { NSBitmapImageRep(data:(try? read($0)) ?? Data())?.cgImage })
            }
            let captured = SessionCoordinator.AXTranslatedFrame(frame:.init(snapshot:snapshot,image:image,frameID:translations.frameID,receivedAt:0),entries:translations.entries)
            fputs("AX review: loaded captured frame\n",stderr)
            var reviewed=captured
            reviewed.retainedBody=try await AXBodyReportSupport.restore(folder:folder,current:captured)
            let art = await AXLineRendering.render(reviewed)
            fputs("AX review: layout ready\n",stderr)
            var frame = MirrorFrame(image:image,translatedItems:art.items + imageLayers.flatMap { $0.mappedItems(frameSize:CGSize(width:image.width,height:image.height)) },frameID:translations.frameID)
            frame.axArtwork = art
            frame.imageOCRLayers = imageLayers
            if let index=CommandLine.arguments.firstIndex(of:"--ax-review-export"),index+1 < CommandLine.arguments.count {
                let view=NativeTranslationMirrorView(frame:CGRect(x:0,y:0,width:image.width,height:image.height))
                view.setRenderingActive(true);view.backgroundOpacity=1;view.frameSnapshot=frame
                guard let rendered=view.compositedImage(),let tiff=rendered.tiffRepresentation,
                      let png=NSBitmapImageRep(data:tiff)?.representation(using:.png,properties:[:]) else { throw CocoaError(.coderInvalidValue) }
                try png.write(to:URL(fileURLWithPath:CommandLine.arguments[index+1]))
                return 0
            }
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
        let measureLiveDraw = CommandLine.arguments.contains("--ax-measure-live-draw")
        let coordinator = SessionCoordinator(broker:broker,createsOutputWindow:measureLiveDraw,
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
            let controlIndex=CommandLine.arguments.firstIndex(of:"--ax-report-sequence-control")
            let control=controlIndex.flatMap { $0+1 < CommandLine.arguments.count ? URL(fileURLWithPath:CommandLine.arguments[$0+1]) : nil }
            let phaseNames: [String]
            if let control {
                phaseNames=try JSONDecoder().decode([String].self,from:Data(contentsOf:control.appendingPathComponent("phases.json")))
                guard !skip, (1...12).contains(phaseNames.count) else { throw CocoaError(.coderInvalidValue) }
                coordinator.setRefreshMode(.manual)
            } else { phaseNames=["capture"] }
            var samples: [[String:Any]] = []
            var translated: SessionCoordinator.AXTranslatedFrame?
            var finishedCount = 0
            var translationSamples: [[String:Any]] = []
            var translationStartedAt = Date()
            var presentations: [[String:Any]] = []
            coordinator.onAXPresentation = { value in
                presentations.append(["seconds":Date().timeIntervalSince(translationStartedAt),
                    "frameID":value.frame.frameID,
                    "sinceCaptureMs":Double(DispatchTime.now().uptimeNanoseconds - value.frame.receivedAt)/1e6,
                    "paragraphs":value.entries.count,"imageRegions":value.imageOCR.diagnostics.count])
            }
            coordinator.onAXTranslationProgress = { translated = $0 }
            coordinator.onAXTranslation = { value in
                if control != nil { fputs("AX sequence completion frame=\(value.frame.frameID)\n",stderr) }
                translated = value; finishedCount += 1
                translationSamples.append(["frameID":value.frame.frameID,
                    "elapsed":max(0,Date().timeIntervalSince(translationStartedAt)-(coordinator.latestAXRenderedFrame?.axArtwork?.elapsed ?? 0)),
                    "renderSeconds":coordinator.latestAXRenderedFrame?.axArtwork?.elapsed ?? 0,
                    "presentations":presentations,
                    "maxConcurrentOCR":value.imageOCR.maxConcurrentOCR,
                    "paragraphs":value.entries.count,
                    "imageOCR":value.imageOCR.diagnostics.map { d in
                        ["node":d.node,"status":d.status,"cacheHit":d.cacheHit,"ocrSeconds":d.ocrSeconds,
                         "translationSeconds":d.translationSeconds,"lines":d.lines.count,
                         "startedSeconds":d.startedSeconds,"completedSeconds":d.completedSeconds] as [String:Any]
                    },
                    "failures":value.imageOCR.failures + value.entries.filter { $0.status == "failed" }.count])
            }
            var collected: AXExtractionSnapshot?, frameID: UInt64?, failure: Error?
            coordinator.onAXExtraction = { snapshot, _, id in
                if control != nil { fputs("AX sequence extraction frame=\(id)\n",stderr) }
                collected = snapshot; frameID = id
                translationStartedAt = Date()
                presentations = []
                if skip { finishedCount += 1 }
                if var sample = (try? JSONSerialization.jsonObject(with:snapshot.metadata)) as? [String:Any] {
                    sample["frameID"] = id; samples.append(sample)
                }
            }
            coordinator.onAXExtractionError = { failure = $0 }
            await coordinator.setTextExtractionMode(.ax)
            coordinator.setRefreshMode(control == nil ? .automatic : .manual)
            coordinator.setPaused(false)
            // Track the replay's window, not the focused app/window.
            let target = CaptureApplication(processID:input.request.processID,bundleIdentifier:"notion.id",name:"Notion",
                anchorWindowID:input.request.windowID,anchorWindowFrame:input.request.windowFrame)
            let selection = appKitSelectionRect(for:input.request.selectionRegion,screenFrame:screen.frame,displayBounds:CGDisplayBounds(display.uint32Value))
            try await coordinator.start(screen:screen,selection:selection,captureTarget:.application(target))
            func exportPhase(targetCount:Int) throws -> (URL,Bool) {
                if let failure { throw failure }
                guard let collected else { throw CocoaError(.coderValueNotFound) }
                let timedOut = finishedCount < targetCount
                var exportEntries: [AXParagraphTranslation] = []
                if !skip {
                    let completed = translated?.frame.frameID == frameID ? translated?.entries ?? [] : []
                    exportEntries = collected.paragraphUnits.map { paragraph in
                        completed.first { $0.node == paragraph.node } ?? .timedOut(paragraph,direction:direction)
                    }
                }
                let output = try input.write(collected,collector:"rearview",frameID:frameID,sessionCollections:samples)
                var metadata = try JSONSerialization.jsonObject(with:Data(contentsOf:output.appendingPathComponent("metadata.json"))) as! [String:Any]
                if var frame = coordinator.latestAXRenderedFrame, frame.frameID == frameID, let art = frame.axArtwork {
                    if CommandLine.arguments.contains("--export-diagnostics"),let id=coordinator.diagnostics.current {
                        frame.diagnosticContext=DiagnosticFrameContext(coordinator.diagnostics,id:id)
                    }
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
                    let debugContext = CGContext(data:nil,width:frame.image.width,height:frame.image.height,bitsPerComponent:8,bytesPerRow:0,
                        space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)
                    if let debug = art.debug { debugContext?.draw(debug,in:CGRect(x:0,y:0,width:debug.width,height:debug.height)) }
                    for layer in frame.imageOCRLayers {
                        debugContext?.setStrokeColor(NSColor.systemPurple.cgColor); debugContext?.setLineWidth(2)
                        debugContext?.stroke(layer.pixelBox)
                        debugContext?.setStrokeColor(NSColor.systemYellow.cgColor)
                        for item in layer.items {
                            let r = item.normalizedRect
                            debugContext?.stroke(CGRect(x:layer.pixelBox.minX+r.minX*layer.pixelBox.width,
                                y:layer.pixelBox.minY+r.minY*layer.pixelBox.height,width:r.width*layer.pixelBox.width,height:r.height*layer.pixelBox.height))
                        }
                    }
                    try png(debugContext?.makeImage(),"render-debug.png")
                    let imageEncoder = JSONEncoder(); imageEncoder.outputFormatting = [.prettyPrinted,.sortedKeys]
                    var savedLayers: [AXImageOCRSavedLayer]=[]
                    for (index,layer) in frame.imageOCRLayers.enumerated() {
                        let name="image-ocr-layer-\(index).png"
                        try png(layer.image,name)
                        savedLayers.append(AXImageOCRSavedLayer(layer,imageFile:name))
                    }
                    try imageEncoder.encode(savedLayers).write(to:output.appendingPathComponent("image-ocr-layers.json"))
                    try imageEncoder.encode(coordinator.latestAXTranslation?.imageOCR.diagnostics ?? []).write(to:output.appendingPathComponent("image-ocr.json"))
                    try JSONSerialization.data(withJSONObject:["frameID":frame.frameID,
                        "clipRects":art.clipRects.map { ["x":$0.minX,"y":$0.minY,"width":$0.width,"height":$0.height] },
                        "imageOCRPixelBoxes":frame.imageOCRLayers.map { ["x":$0.pixelBox.minX,"y":$0.pixelBox.minY,"width":$0.pixelBox.width,"height":$0.pixelBox.height] },
                        "fragments":art.fragments.map { ["text":$0.text,"offset":$0.characterOffset,"x":$0.rect.minX,"y":$0.rect.minY,"width":$0.rect.width,"height":$0.rect.height] }],options:[.sortedKeys,.prettyPrinted])
                        .write(to:output.appendingPathComponent("render-geometry.json"))
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
                    try encoder.encode(art.fullTextHover).write(to:output.appendingPathComponent("full-text-hover.json"))
                    try encoder.encode(art.diagnostics).write(to:output.appendingPathComponent("render-layout.json"))
                    metadata["renderFrameID"] = frame.frameID
                    metadata["renderSeconds"] = art.elapsed
                    metadata["bodyReuseCompositeSeconds"] = art.bodyReuseSeconds
                }
                let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
                if let diagnostic=translated?.bodyReuseDiagnostic {
                    metadata["bodyReuse"]=try JSONSerialization.jsonObject(with:encoder.encode(diagnostic))
                }
                if let reuse=translated?.retainedBody {
                    let body=reuse.body
                    try body.frame.snapshot.nodes.write(to:output.appendingPathComponent("retained-body-rawAx.json"))
                    try body.frame.snapshot.selected.write(to:output.appendingPathComponent("retained-body-candidate.json"))
                    try body.frame.snapshot.paragraphs.write(to:output.appendingPathComponent("retained-body-paragraphs.json"))
                    try body.frame.snapshot.metadata.write(to:output.appendingPathComponent("retained-body-metadata.json"))
                    try encoder.encode(body.artwork.diagnostics.filter { body.paragraphNodes.contains($0.node) }).write(to:output.appendingPathComponent("retained-body-layout.json"))
                    try encoder.encode(body.entries).write(to:output.appendingPathComponent("retained-body-translations.json"))
                    try encoder.encode(Array(body.paragraphNodes).sorted()).write(to:output.appendingPathComponent("retained-body-nodes.json"))
                    if let png=NSBitmapImageRep(cgImage:body.frame.image).representation(using:.png,properties:[:]) {
                        try png.write(to:output.appendingPathComponent("retained-body-source.png"))
                    }
                }
                metadata["liveDrawMeasurement"] = measureLiveDraw
                metadata["performanceProfileScope"] = control == nil ? "collection_session" : "report_sequence"
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
                return (output,timedOut || exportEntries.contains { $0.status == "failed" })
            }
            var lastOutput: URL?, allOutputs: [URL]=[], anyFailure=false
            for (phase,name) in phaseNames.enumerated() {
                var targetCount=repeatCount
                if let control {
                    if phase > 0 {
                        let gate=control.appendingPathComponent("continue-\(phase).json")
                        let deadline=ContinuousClock.now + .seconds(540)
                        while !FileManager.default.fileExists(atPath:gate.path),ContinuousClock.now < deadline {
                            if FileManager.default.fileExists(atPath:control.appendingPathComponent("abort.json").path) { throw CancellationError() }
                            try await Task.sleep(for:.milliseconds(50))
                        }
                        guard FileManager.default.fileExists(atPath:gate.path) else { throw CocoaError(.fileReadNoSuchFile) }
                    }
                    // The external test driver has changed the UI; capture keeps
                    // running in manual mode. Give it a fresh current frame.
                    try await Task.sleep(for:.milliseconds(400))
                    failure=nil;collected=nil;translated=nil;samples=[];translationSamples=[]
                    targetCount=finishedCount+repeatCount
                    fputs("AX sequence phase \(phase): completed=\(finishedCount), target=\(targetCount)\n",stderr)
                    coordinator.translateImmediately()
                }
                let deadline=ContinuousClock.now + .seconds(skip ? 60 : 540)
                var requestedRepeat=finishedCount
                while finishedCount < targetCount && failure == nil && ContinuousClock.now < deadline {
                    try await Task.sleep(for:.milliseconds(50))
                    if finishedCount > requestedRepeat && finishedCount < targetCount {
                        requestedRepeat=finishedCount;coordinator.translateImmediately()
                    }
                }
                let (folder,failed)=try exportPhase(targetCount:targetCount)
                lastOutput=folder;allOutputs.append(folder);anyFailure = anyFailure || failed
                if let control {
                    try JSONSerialization.data(withJSONObject:["phase":phase,"name":name,"output":folder.path,"failed":failed],options:[.sortedKeys])
                        .write(to:control.appendingPathComponent("ready-\(phase).json"),options:.atomic)
                }
                print(folder.path)
            }
            guard let output=lastOutput else { throw CocoaError(.coderValueNotFound) }
            if let profile=PerformanceProfiler.shared.stop(translationDirection:direction) {
                let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
                for folder in allOutputs { try encoder.encode(profile).write(to:folder.appendingPathComponent("translation-profile.json"),options:.atomic) }
            }
            if CommandLine.arguments.contains("--export-diagnostics") {
                let snapshot=coordinator.diagnosticSnapshot()
                _=try await Task.detached(priority:.utility) {
                    try DiagnosticBundleWriter.write(snapshot,options:.init(),destination:output.appendingPathComponent("diagnostics.zip"))
                }.value
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
            return anyFailure ? 2 : 0
        } catch {
            await coordinator.stop()
            fputs("AX report collection failed: \(error)\n",stderr)
            return 1
        }
    }
}
#endif
