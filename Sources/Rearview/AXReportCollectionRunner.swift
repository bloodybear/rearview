#if !LST_EXCLUDE_DEBUG_FEATURES
import AppKit
import NotionAXCore
import NotionAXReportSupport

@MainActor enum AXReportCollectionRunner {
    static func run() async -> Int32 {
        let coordinator = SessionCoordinator(broker:TranslationBroker(),createsOutputWindow:false)
        let previousRefresh = coordinator.currentRefreshMode
        defer { coordinator.setRefreshMode(previousRefresh) }
        do {
            _ = NSApplication.shared
            let input = try AXReportInput(arguments:CommandLine.arguments)
            guard let screen = NSScreen.screens.first(where: {
                guard let id = $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
                return CGDisplayBounds(id.uint32Value).intersects(input.request.windowFrame)
            }), let display = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { throw TranslatorError.noDisplay }
            let repeatIndex = CommandLine.arguments.firstIndex(of:"--ax-repeat")
            let repeatCount = repeatIndex.flatMap { $0+1 < CommandLine.arguments.count ? Int(CommandLine.arguments[$0+1]) : nil } ?? 2
            guard (1...5).contains(repeatCount) else { throw CocoaError(.coderInvalidValue) }
            var samples: [[String:Any]] = []
            var collected: AXExtractionSnapshot?, frameID: UInt64?, failure: Error?
            coordinator.onAXExtraction = { snapshot, _, id in
                collected = snapshot; frameID = id
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
            let deadline = ContinuousClock.now + .seconds(60)
            var requestedRepeat = 0
            while samples.count < repeatCount && failure == nil && ContinuousClock.now < deadline {
                try await Task.sleep(for:.milliseconds(50))
                if samples.count > requestedRepeat && samples.count < repeatCount {
                    requestedRepeat = samples.count
                    coordinator.translateImmediately()
                }
            }
            if let failure { throw failure }
            guard samples.count >= repeatCount, let collected else { throw CocoaError(.coderValueNotFound) }
            let output = try input.write(collected,collector:"rearview",frameID:frameID,sessionCollections:samples)
            await coordinator.stop()
            print(output.path)
            return 0
        } catch {
            await coordinator.stop()
            fputs("AX report collection failed: \(error)\n",stderr)
            return 1
        }
    }
}
#endif
