#if DEBUG
import AppKit
import XCTest
@testable import Rearview
@testable import NotionAXCore

final class DiagnosticTests:XCTestCase {
    @MainActor func testDiagnosticMenuAvailableWithoutSessionOrDebug() {
        let delegate=AppDelegate()
        let item=delegate.statusMenuForTesting().items.first { $0.title == L10n.text("진단 자료 내보내기…") }
        XCTAssertNotNil(item);XCTAssertFalse(item?.isHidden ?? true);XCTAssertNotNil(item?.action)
    }
    @MainActor private func image(_ width:Int=300,_ height:Int=100)->CGImage {
        let ctx=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray:0.95,alpha:1));ctx.fill(CGRect(x:0,y:0,width:width,height:height));return ctx.makeImage()!
    }
    private func allFiles(_ folder:URL)->[URL] {
        let values=FileManager.default.enumerator(at:folder,includingPropertiesForKeys:[.isRegularFileKey])!
        return values.allObjects.compactMap { $0 as? URL }
    }
    private func folder()->URL { FileManager.default.temporaryDirectory.appendingPathComponent("DiagnosticTest-\(UUID())") }
    @MainActor func testRecorderPinsFramesAndRejectsPreviousSession() throws {
        let recorder=DiagnosticRecorder();recorder.begin()
        let a=recorder.startFrame(image:image(),frameID:1,receivedAt:10,generation:1,revision:1,task:1,mode:"ocr")!
        recorder.submitted(MirrorFrame(image:image(),translatedItems:[],frameID:1),id:a)
        let b=recorder.startFrame(image:image(),frameID:2,receivedAt:11,generation:1,revision:2,task:2,mode:"ax")!
        recorder.error(NSError(domain:"secret-path",code:8),stage:"ax",id:b)
        let c=recorder.startFrame(image:image(),frameID:3,receivedAt:12,generation:1,revision:3,task:3,mode:"ax")!
        XCTAssertEqual(Set(recorder.frames.keys),Set([a,b,c]))
        let frozen=recorder.snapshot()
        recorder.stop();XCTAssertEqual(recorder.snapshot().frames.count,3)
        recorder.begin();recorder.error(NSError(domain:"old",code:9),stage:"ax",id:b)
        recorder.add("late.json",document:.init(["secret":"old"],estimatedBytes:10),to:a)
        XCTAssertTrue(recorder.frames.isEmpty);XCTAssertNil(recorder.failed)
        XCTAssertEqual(frozen.frames.count,3);XCTAssertEqual(frozen.frames.first?.receivedAt,10)
    }
    @MainActor func testTimeAndEventLimitsAndMemoryEviction() {
        let recorder=DiagnosticRecorder(byteLimit:100);recorder.begin()
        let old=Date().addingTimeInterval(-301)
        recorder.event("old",now:old)
        for _ in 0..<5100 { recorder.event("test") }
        XCTAssertLessThanOrEqual(recorder.events.count,5000)
        XCTAssertFalse(recorder.snapshot().events.contains { $0.name=="old" })
        let id=recorder.startFrame(image:image(),frameID:1,receivedAt:0,generation:0,revision:0,task:0,mode:"ocr")!
        XCTAssertTrue(recorder.frames[id]!.images.isEmpty)
        XCTAssertTrue(recorder.frames[id]!.omissions.contains("payload_evicted_memory_limit"))
        let future=recorder.snapshot(now:Date().addingTimeInterval(301))
        XCTAssertTrue(future.events.isEmpty)
    }
    @MainActor func testContentExclusionAndZIPContainsNoSecrets() async throws {
        let recorder=DiagnosticRecorder();recorder.begin()
        recorder.update(["os":"test"],content:["path":"/Users/private/MY_SECRET"])
        let id=recorder.startFrame(image:image(),frameID:1,receivedAt:0,generation:1,revision:1,task:1,mode:"ax")!
        recorder.add("secret.json",document:.init(["source":"MY_SECRET","translation":"MY_SECRET"],estimatedBytes:100),to:id)
        recorder.error(NSError(domain:"MY_SECRET",code:3,userInfo:[NSLocalizedDescriptionKey:"MY_SECRET"]),stage:"ax",id:id)
        let snapshot=recorder.snapshot(),root=folder(),zip=root.appendingPathComponent("result.zip")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let manifest=try await Task.detached { try DiagnosticBundleWriter.write(snapshot,options:.init(includesContent:false),destination:zip) }.value
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath:zip.path)[.posixPermissions] as? NSNumber)?.intValue,0o600)
        XCTAssertFalse(manifest.contentIncluded);XCTAssertNil(manifest.contentEnvironment)
        XCTAssertTrue(manifest.frames.allSatisfy { $0.files.isEmpty })
        let unpack=root.appendingPathComponent("unpacked")
        let process=Process();process.executableURL=URL(fileURLWithPath:"/usr/bin/ditto");process.arguments=["-x","-k",zip.path,unpack.path]
        try process.run();process.waitUntilExit();XCTAssertEqual(process.terminationStatus,0)
        for file in allFiles(unpack) {
            if try file.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile == true {
                let data=try Data(contentsOf:file)
                XCTAssertFalse(String(decoding:data,as:UTF8.self).contains("MY_SECRET"))
                XCTAssertNotEqual(file.pathExtension,"png")
            }
        }
    }
    @MainActor func testFullExportIsFrozenAndReportsUnavailableData() async throws {
        let recorder=DiagnosticRecorder();recorder.begin()
        let id=recorder.startFrame(image:image(),frameID:1,receivedAt:1,generation:1,revision:1,task:1,mode:"ax")!
        recorder.add("bad.json",document:.init(estimatedBytes:1,encode:{ throw CocoaError(.coderInvalidValue) }),to:id)
        recorder.add("before.json",document:.init(["source":"日本語"],estimatedBytes:100),to:id)
        let snapshot=recorder.snapshot()
        recorder.add("after.json",document:.init(["source":"changed"],estimatedBytes:100),to:id)
        let destination=folder();defer { try? FileManager.default.removeItem(at:destination) }
        let manifest=try await Task.detached { try DiagnosticBundleWriter.writeFolder(snapshot,options:.init(),to:destination) }.value
        XCTAssertTrue(manifest.frames[0].files.contains("before.json"));XCTAssertFalse(manifest.frames[0].files.contains("after.json"))
        XCTAssertTrue(manifest.frames[0].omissions.contains("bad.json:serialization_or_write_failed"))
        XCTAssertTrue(FileManager.default.fileExists(atPath:destination.appendingPathComponent(id.uuidString+"/source.png").path))
    }
    @MainActor func testCurrentScreenExportExcludesHistoryAndPendingFrame() async throws {
        let recorder = DiagnosticRecorder()
        recorder.begin()
        recorder.update(["history": "previous-state"], content: ["path": "private-path"])
        let failed = try XCTUnwrap(recorder.startFrame(image: image(), frameID: 1, receivedAt: 1,
            generation: 1, revision: 1, task: 1, mode: "ax"))
        recorder.error(nil, stage: "ax", id: failed)
        let displayed = try XCTUnwrap(recorder.startFrame(image: image(), frameID: 2, receivedAt: 2,
            generation: 1, revision: 1, task: 2, mode: "ax"))
        recorder.submitted(MirrorFrame(image: image(), translatedItems: [], frameID: 2), id: displayed)
        recorder.image("composite.png", image(), to: displayed)
        recorder.image("retained-source.png", image(), to: displayed)
        recorder.add("retained-translations.json", document: .init(["source": "private"], estimatedBytes: 100), to: displayed)
        let pending = try XCTUnwrap(recorder.startFrame(image: image(), frameID: 3, receivedAt: 3,
            generation: 1, revision: 1, task: 3, mode: "ax"))
        let snapshot = recorder.snapshot()
        XCTAssertEqual(Set(snapshot.frames.map(\.id)), Set([failed, displayed, pending]))
        let destination = folder()
        defer { try? FileManager.default.removeItem(at: destination) }
        let manifest = try await Task.detached {
            try DiagnosticBundleWriter.writeFolder(snapshot, options: .init(includesRecentLogs: false), to: destination)
        }.value

        XCTAssertEqual(manifest.recentLogsIncluded, false)
        XCTAssertEqual(manifest.displayed, displayed)
        XCTAssertNil(manifest.current)
        XCTAssertNil(manifest.failed)
        XCTAssertNil(manifest.contentEnvironment)
        XCTAssertTrue(manifest.state.isEmpty)
        XCTAssertEqual(manifest.frames.map(\.id), [displayed])
        XCTAssertEqual(Set(allFiles(destination).filter { $0.hasDirectoryPath == false }.map(\.lastPathComponent))
            .subtracting([displayed.uuidString]), Set(["manifest.json", "README.txt", "source.png", "composite.png"]))
    }
    @MainActor func testCancelledExportDoesNotReplaceDestination() async throws {
        let recorder=DiagnosticRecorder();recorder.begin();let snapshot=recorder.snapshot()
        let root=folder();try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let destination=root.appendingPathComponent("result.zip"),original=Data("existing".utf8)
        try original.write(to:destination)
        let task=Task.detached { () throws -> DiagnosticManifest in
            // Ensure cancellation precedes any write, without relying on scheduler timing.
            while !Task.isCancelled { await Task.yield() }
            return try DiagnosticBundleWriter.write(snapshot,options:.init(),destination:destination)
        }
        task.cancel()
        do { _=try await task.value;XCTFail("expected cancellation") } catch is CancellationError { }
        XCTAssertEqual(try Data(contentsOf:destination),original)
        let leftovers=(try? FileManager.default.contentsOfDirectory(at:DiagnosticBundleWriter.temporaryRoot,includingPropertiesForKeys:nil)) ?? []
        XCTAssertFalse(leftovers.contains { $0.lastPathComponent.hasPrefix("\(ProcessInfo.processInfo.processIdentifier)-") })
    }
    @MainActor func testSavedOCRRenderingReplayUsesProductRenderer() async throws {
        let recorder=DiagnosticRecorder();recorder.begin();let source=image()
        let id=recorder.startFrame(image:source,frameID:17,receivedAt:42,generation:2,revision:3,task:4,mode:"ocr")!
        let item=MirrorItem(id:UUID(),translatedText:"한국어 번역",presentation:.translated,normalizedRect:CGRect(x:0.1,y:0.3,width:0.8,height:0.3),background:.lightBackground,foreground:.darkText)
        var frame=MirrorFrame(image:source,translatedItems:[item],frameID:17)
        frame.imageOCRLayers=[.init(image:source,pixelBox:CGRect(x:0,y:0,width:300,height:100),items:[item],debugItems:[])]
        recorder.submitted(frame,id:id);frame.diagnosticContext=DiagnosticFrameContext(recorder,id:id)
        let view=NativeTranslationMirrorView(frame:CGRect(x:0,y:0,width:300,height:100));view.setRenderingActive(true);view.backgroundOpacity=1;view.frameSnapshot=frame
        XCTAssertNotNil(view.compositedImage())
        let input=folder(),output=folder();defer { try? FileManager.default.removeItem(at:input);try? FileManager.default.removeItem(at:output) }
        let snapshot=recorder.snapshot()
        _=try await Task.detached { try DiagnosticBundleWriter.writeFolder(snapshot,options:.init(),to:input) }.value
        try await DiagnosticReviewRunner.review(folder:input,frame:id,output:output)
        let recorded=try Data(contentsOf:output.appendingPathComponent("recorded.png")),replayed=try Data(contentsOf:output.appendingPathComponent("rerendered.png"))
        XCTAssertEqual(NSBitmapImageRep(data:recorded)?.cgImage?.width,300)
        // PNG metadata can differ; the decoded pixel planes must agree.
        let a=NSBitmapImageRep(data:recorded)!,b=NSBitmapImageRep(data:replayed)!
        for y in 0..<100 { for x in 0..<300 { XCTAssertEqual(a.colorAt(x:x,y:y),b.colorAt(x:x,y:y)) } }
        XCTAssertTrue(recorder.snapshot().frames[0].summary["stage"]?.contains("render") ?? false)
    }
    @MainActor func testSavedAXRenderingReplayAndUnsupportedPrivacyBundle() async throws {
        let recorder=DiagnosticRecorder();recorder.begin();let source=image()
        let box:[String:Double]=["x":10,"y":10,"width":100,"height":18]
        let paragraph:[String:Any]=["node":1,"text":"日本語","lineSourceText":"日本語","lineRangeStatus":"complete_unverified","box":box,"members":[1],"isCodeBlock":false,"protectNonSourceText":false,"lineRanges":[["text":"日本語","rangeStart":0,"rangeLength":3,"box":box]]]
        let snapshot=try AXExtractionSnapshot(nodes:[],selected:[],paragraphs:[paragraph],metadata:["status":"complete","selectionRegion":["x":0,"y":0,"width":300,"height":100]])
        let payload:[String:Any]=["provider":"test","node":1,"source":"日本語","translation":"한국어","sourceLanguage":"ja","targetLanguage":"ko","protectNonSourceText":false,"sourceLanguageEligible":true,"status":"translated"]
        let entry=try JSONDecoder().decode(AXParagraphTranslation.self,from:JSONSerialization.data(withJSONObject:payload))
        let id=recorder.startFrame(image:source,frameID:2,receivedAt:0,generation:0,revision:0,task:0,mode:"ax")!
        for (name,data) in [("ax-nodes.json",snapshot.nodes),("ax-selected.json",snapshot.selected),("ax-paragraphs.json",snapshot.paragraphs),("ax-metadata.json",snapshot.metadata)] { recorder.add(name,document:.init(data:data),to:id) }
        recorder.add("ax-translations.json",document:.init([entry],estimatedBytes:1024),to:id)
        let art=await AXLineRendering.render(.init(frame:.init(snapshot:snapshot,image:source,frameID:2,receivedAt:0),entries:[entry]))
        var frame=MirrorFrame(image:source,translatedItems:art.items,frameID:2);frame.axArtwork=art
        recorder.submitted(frame,id:id);frame.diagnosticContext=DiagnosticFrameContext(recorder,id:id)
        let view=NativeTranslationMirrorView(frame:CGRect(x:0,y:0,width:300,height:100));view.setRenderingActive(true);view.backgroundOpacity=1;view.frameSnapshot=frame
        let frozen=recorder.snapshot(),input=folder(),output=folder(),privateInput=folder()
        defer { for folder in [input,output,privateInput] { try? FileManager.default.removeItem(at:folder) } }
        _=try await Task.detached { try DiagnosticBundleWriter.writeFolder(frozen,options:.init(),to:input) }.value
        try await DiagnosticReviewRunner.review(folder:input,frame:id,output:output)
        let a=NSBitmapImageRep(data:try Data(contentsOf:output.appendingPathComponent("recorded.png")))!
        let b=NSBitmapImageRep(data:try Data(contentsOf:output.appendingPathComponent("rerendered.png")))!
        for y in 0..<100 { for x in 0..<300 { XCTAssertEqual(a.colorAt(x:x,y:y),b.colorAt(x:x,y:y)) } }
        _=try await Task.detached { try DiagnosticBundleWriter.writeFolder(frozen,options:.init(includesContent:false),to:privateInput) }.value
        do { try await DiagnosticReviewRunner.review(folder:privateInput,frame:id,output:folder());XCTFail("privacy bundle is not replayable") } catch { }
    }

    func testAXDiagnosticsSurviveFailureBeforeAnyTreeQuery() async throws {
        let provider=NativeSessionAXProvider()
        let request=AXExtractionRequest(processID:0,windowID:0,windowFrame:.zero,selectionRegion:.zero)
        do { _=try await provider.collect(request);XCTFail("invalid request") }
        catch { XCTAssertEqual(error as? AXExtractionError,.invalidRequest) }
        let collected=await provider.diagnosticSnapshot()
        let diagnostic=try XCTUnwrap(collected)
        XCTAssertEqual(diagnostic.fields["requestID"],request.diagnosticRequestID.uuidString)
        XCTAssertEqual(diagnostic.fields["stage"],"request")
        XCTAssertTrue(diagnostic.queryResults.isEmpty)
    }

}
#endif
