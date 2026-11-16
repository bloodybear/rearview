import AppKit
import CryptoKit
import NotionAXCore

struct AXImageOCRDiagnostic: Codable, Sendable {
    let node: Int
    let box: CGRect
    let pixelBox: CGRect
    var status: String
    var cacheHit = false
    var startedSeconds = 0.0
    var completedSeconds = 0.0
    var ocrSeconds = 0.0
    var translationSeconds = 0.0
    var lines: [Line] = []
    var error: String?
    struct Line: Codable, Sendable {
        let source: String
        let translation: String?
        let box: CGRect // crop-local, Vision normalized coordinates
    }
}
struct AXImageOCRLayer: @unchecked Sendable {
    let image: CGImage
    let pixelBox: CGRect // full-frame, bottom-left pixels
    let items: [MirrorItem] // crop-local normalized coordinates
    let debugItems: [OCRDebugItem]
}
struct AXImageOCRResult: Sendable {
    var layers: [AXImageOCRLayer] = []
    var diagnostics: [AXImageOCRDiagnostic] = []
    var maxConcurrentOCR = 0
    var failures: Int { diagnostics.filter { $0.status == "failed" || $0.status == "translation_failed" }.count }
}

/// Only the preceding completed frame's recognition is retained. Translation
/// caching remains the broker's responsibility; geometry never enters its key.
@MainActor final class AXImageOCRProcessor {
    private var cache: [String: OCRService.RecognitionBatch] = [:]
    private var epoch = 0
    private let concurrency: Int
    private let permits: RecognitionPermits
    init(concurrency: Int = 2) {
        self.concurrency = max(1, concurrency)
        self.permits = RecognitionPermits(limit:max(1,concurrency))
    }
    // Retained across frame invalidation: an uncancellable Vision call still
    // occupies its permit until it actually returns.
    @MainActor private final class RecognitionPermits {
        let limit: Int
        var active = 0
        var waiters: [(UUID, CheckedContinuation<Void,Error>)] = []
        init(limit:Int) { self.limit = limit }
        func acquire() async throws {
            try Task.checkCancellation()
            if active < limit { active += 1; return }
            let id=UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { waiters.append((id,$0)) }
            } onCancel: {
                Task { @MainActor in
                    if let index=self.waiters.firstIndex(where: { $0.0 == id }) {
                        self.waiters.remove(at:index).1.resume(throwing:CancellationError())
                    }
                }
            }
        }
        func release() {
            active -= 1
            if !waiters.isEmpty { active += 1; waiters.removeFirst().1.resume() }
        }
        func recognize(pixels:CGImage,ocr:any SessionOCRProvider,settings:OCRSettings,
                       direction:TranslationDirection) async throws -> OCRService.RecognitionBatch {
            try await acquire()
            defer { release() }
            try Task.checkCancellation()
            return try await ocr.recognize(image:pixels,mode:.realtime,regionOfInterest:nil,
                includeRejectedAlternatives:false,settings:settings,direction:direction)
        }
    }

    struct Job: Sendable {
        let index: Int
        let node: Int
        let box: CGRect
        let crop: CGRect
    }
    struct Completion: Sendable {
        let index: Int
        let result: AXImageOCRResult
    }
    nonisolated static func jobs(snapshot: AXExtractionSnapshot, image: CGImage, selection: CGRect) -> [Job] {
        var jobs: [Job] = []
        for region in snapshot.imageRegions where region.status == "selected" {
            for box in region.displayBoxes ?? [] {
                let crop = pixelBox(box.cgRect, selection:selection, image:image)
                if !crop.isNull, crop.width > 1, crop.height > 1 {
                    jobs.append(Job(index:jobs.count,node:region.node,box:box.cgRect,crop:crop))
                }
            }
        }
        return jobs
    }
    // One invocation owns these tasks, including cancellation of shared recognition.
    @MainActor private final class RecognitionStore {
        var completed: [String:OCRService.RecognitionBatch]
        var retained: [String:OCRService.RecognitionBatch] = [:]
        var tasks: [String:Task<OCRService.RecognitionBatch, Error>] = [:]
        var active = 0
        var maximum = 0
        let permits: RecognitionPermits
        init(_ cache: [String:OCRService.RecognitionBatch], permits:RecognitionPermits) {
            completed = cache; self.permits = permits
        }
        func cancel() { tasks.values.forEach { $0.cancel() } }
        func recognize(key:String?, pixels:CGImage, ocr:any SessionOCRProvider,
                       settings:OCRSettings, direction:TranslationDirection) async throws -> (OCRService.RecognitionBatch,Bool) {
            try Task.checkCancellation()
            if let key, let value = completed[key] { retained[key] = value; return (value,true) }
            if let key, let task = tasks[key] {
                let value = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
                try Task.checkCancellation()
                retained[key] = value
                return (value,true)
            }
            active += 1; maximum = max(maximum,active)
            defer { active -= 1 }
            let task = Task {
                try Task.checkCancellation()
                return try await permits.recognize(pixels:pixels,ocr:ocr,settings:settings,direction:direction)
            }
            // A missing digest is deliberately never shared.
            let identity = key ?? UUID().uuidString
            tasks[identity] = task
            let value = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
            if let key { completed[key] = value; retained[key] = value }
            return (value,false)
        }
    }
    func reset() { epoch += 1; cache.removeAll() }

    nonisolated static func normalized(_ rect: CGRect, in crop: CGRect, frameSize: CGSize) -> CGRect {
        CGRect(x:(crop.minX+rect.minX*crop.width)/frameSize.width,
               y:(crop.minY+rect.minY*crop.height)/frameSize.height,
               width:rect.width*crop.width/frameSize.width,height:rect.height*crop.height/frameSize.height)
    }
    nonisolated static func pixelBox(_ rect: CGRect, selection: CGRect, image: CGImage) -> CGRect {
        let sx = CGFloat(image.width)/selection.width, sy = CGFloat(image.height)/selection.height
        // Round inward so the crop cannot include captions or pixels outside the viewport.
        let x = ceil((rect.minX-selection.minX)*sx), y = ceil((rect.minY-selection.minY)*sy)
        let right = floor((rect.maxX-selection.minX)*sx), bottom = floor((rect.maxY-selection.minY)*sy)
        return CGRect(x:x,y:y,width:max(0,right-x),height:max(0,bottom-y))
            .intersection(CGRect(x:0,y:0,width:image.width,height:image.height))
    }
    private static func digest(_ image: CGImage) async -> String? {
        await Task.detached(priority:.userInitiated) {
            let row = image.width*4
            var bytes = [UInt8](repeating:0,count:row*image.height)
            let success = bytes.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(data:buffer.baseAddress,width:image.width,height:image.height,
                    bitsPerComponent:8,bytesPerRow:row,space:CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                context.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height)); return true
            }
            return success ? "\(image.width)x\(image.height):"+SHA256.hash(data:Data(bytes)).map { String(format:"%02x",$0) }.joined() : nil
        }.value
    }
    func process(snapshot: AXExtractionSnapshot, image: CGImage, selection: CGRect,
                 ocr: any SessionOCRProvider, broker: any SessionTranslationProvider,
                 settings: OCRSettings, direction: TranslationDirection,
                 onCompletion: @escaping @MainActor @Sendable (Completion) -> Void = { _ in }) async throws -> AXImageOCRResult {
        let activeEpoch = epoch
        let jobs = Self.jobs(snapshot:snapshot,image:image,selection:selection)
        let store = RecognitionStore(cache,permits:permits)
        let started = ContinuousClock.now
        defer { store.cancel() }
        var values: [Int:AXImageOCRResult] = [:]
        try await withThrowingTaskGroup(of:Completion.self) { group in
            var next = 0
            func submit(_ job:Job) {
                group.addTask {
                    try await self.process(job:job,image:image,store:store,activeEpoch:activeEpoch,
                        ocr:ocr,broker:broker,settings:settings,direction:direction,started:started)
                }
            }
            while next < min(concurrency,jobs.count) { submit(jobs[next]); next += 1 }
            for try await value in group {
                try Task.checkCancellation()
                guard activeEpoch == epoch else { throw CancellationError() }
                values[value.index] = value.result
                if next < jobs.count { submit(jobs[next]); next += 1 }
                onCompletion(value)
            }
        }
        try Task.checkCancellation()
        guard activeEpoch == epoch else { throw CancellationError() }
        cache = store.retained
        return AXImageOCRResult(layers:jobs.flatMap { values[$0.index]?.layers ?? [] },
            diagnostics:jobs.flatMap { values[$0.index]?.diagnostics ?? [] },maxConcurrentOCR:store.maximum)
    }

    private func process(job:Job, image:CGImage, store:RecognitionStore, activeEpoch:Int,
                         ocr:any SessionOCRProvider, broker:any SessionTranslationProvider,
                         settings:OCRSettings, direction:TranslationDirection, started:ContinuousClock.Instant) async throws -> Completion {
        try Task.checkCancellation()
        guard activeEpoch == epoch else { throw CancellationError() }
        let crop = job.crop
        let bottomBox = CGRect(x:crop.minX,y:CGFloat(image.height)-crop.maxY,width:crop.width,height:crop.height)
        guard let pixels = image.cropping(to:crop) else {
            return Completion(index:job.index,result:AXImageOCRResult(diagnostics:[
                AXImageOCRDiagnostic(node:job.node,box:job.box,pixelBox:bottomBox,status:"failed",error:"image_crop_failed")]))
        }
        var result = AXImageOCRResult()
        var diagnostic = AXImageOCRDiagnostic(node:job.node,box:job.box,pixelBox:bottomBox,status:"complete")
        func elapsed() -> Double {
            let d = (ContinuousClock.now-started).components
            return Double(d.seconds) + Double(d.attoseconds)/1e18
        }
        diagnostic.startedSeconds = elapsed()
        do {
            let key = await Self.digest(pixels).map { "\($0):\(settings):\(direction):\(OCRRecognitionPolicy.minimumConfidence)" }
            try Task.checkCancellation()
            guard activeEpoch == epoch else { throw CancellationError() }
            let started = Date()
            let (batch, hit) = try await store.recognize(key:key,pixels:pixels,ocr:ocr,settings:settings,direction:direction)
            diagnostic.cacheHit = hit
            diagnostic.ocrSeconds = Date().timeIntervalSince(started)
            try Task.checkCancellation()
            guard activeEpoch == epoch else { throw CancellationError() }
            let recognized = batch.lines.map { line in
                RecognizedLine(sourceText:line.sourceText,normalizedRect:line.normalizedRect,confidence:line.confidence,
                    background:line.background,foreground:line.foreground,selectionFragments:line.selectionFragments,
                    selectionGeometrySource:line.selectionGeometrySource)
            }
            let translationStart = Date()
            let translations = try await withThrowingTaskGroup(of:MirrorTranslation?.self) { group in
                for line in recognized where LanguageProtector.containsSourceLanguage(line.sourceText,direction:direction) {
                    group.addTask {
                        do { return MirrorTranslation(frameID:0,line:line,translatedText:try await broker.translate(line.sourceText)) }
                        catch is CancellationError { throw CancellationError() }
                        catch { return nil }
                    }
                }
                var values: [MirrorTranslation] = []
                for try await value in group { if let value { values.append(value) } }
                return values
            }
            try Task.checkCancellation()
            guard activeEpoch == epoch else { throw CancellationError() }
            diagnostic.translationSeconds = Date().timeIntervalSince(translationStart)
            let items = makeMirrorItems(frameID:0,recognizedLines:recognized,translations:translations)
            let byID = Dictionary(uniqueKeysWithValues:translations.map { ($0.line.id,$0.translatedText) })
            diagnostic.lines = recognized.map { .init(source:$0.sourceText,translation:byID[$0.id],box:$0.normalizedRect) }
            if recognized.contains(where: { LanguageProtector.containsSourceLanguage($0.sourceText,direction:direction) && byID[$0.id] == nil }) {
                diagnostic.status = "translation_failed"
            }
            let freshIDs = Dictionary(uniqueKeysWithValues:zip(batch.lines,recognized).map { ($0.0.id,$0.1.id) })
            let debugItems = batch.debugItems.map { item in
                let id = freshIDs[item.id] ?? UUID()
                let translated = byID[id]
                return OCRDebugItem(id:id,
                    status:item.status == .translationPending ? (translated == nil ? .translationFailed : .success) : item.status,
                    rawText:item.rawText,confidence:item.confidence,recognitionLanguages:item.recognitionLanguages,
                    translatedText:translated,normalizedRect:item.normalizedRect)
            }
            result.layers.append(.init(image:pixels,pixelBox:bottomBox,items:items,debugItems:debugItems))
        } catch is CancellationError { throw CancellationError() }
        catch { diagnostic.status = "failed"; diagnostic.error = String(describing:error) }
        diagnostic.completedSeconds = elapsed()
        result.maxConcurrentOCR = store.maximum
        result.diagnostics.append(diagnostic)
        try Task.checkCancellation()
        guard activeEpoch == epoch else { throw CancellationError() }
        return Completion(index:job.index,result:result)
    }

}

extension AXImageOCRLayer {
    func mappedItems(frameSize: CGSize) -> [MirrorItem] {
        items.map { item in
            MirrorItem(id:item.id,translatedText:item.translatedText,presentation:item.presentation,
                normalizedRect:AXImageOCRProcessor.normalized(item.normalizedRect,in:pixelBox,frameSize:frameSize),
                background:item.background,foreground:item.foreground,
                sourceSelectionFragments:item.sourceSelectionFragments.map { .init(text:$0.text,normalizedRect:AXImageOCRProcessor.normalized($0.normalizedRect,in:pixelBox,frameSize:frameSize)) },
                selectionGeometrySource:item.selectionGeometrySource.map { $0.mapped(to:pixelBox,frameSize:frameSize) })
        }
    }
}

// Saved reports rebuild the same native views without invoking OCR or models.
struct AXImageOCRSavedLayer: Codable {
    let pixelBox: CGRect
    let items: [Item]
    struct Fragment: Codable { let text: String; let box: CGRect }
    struct Item: Codable {
        let id: UUID
        let text: String
        let translated: Bool
        let box: CGRect
        let background, foreground: [Double]
        let fragments: [Fragment]
    }
    init(_ layer: AXImageOCRLayer) {
        pixelBox = layer.pixelBox
        func color(_ c:RGBAColor) -> [Double] { [c.red,c.green,c.blue,c.alpha] }
        items = layer.items.map { item in
            Item(id:item.id,text:item.translatedText,translated:item.isTranslated,box:item.normalizedRect,
                background:color(item.background),foreground:color(item.foreground),
                fragments:(item.sourceSelectionFragments.isEmpty ? item.selectionGeometrySource?.fragments() ?? [] : item.sourceSelectionFragments)
                    .map { Fragment(text:$0.text,box:$0.normalizedRect) })
        }
    }
    func restore(source: CGImage) -> AXImageOCRLayer? {
        let top = CGRect(x:pixelBox.minX,y:CGFloat(source.height)-pixelBox.maxY,width:pixelBox.width,height:pixelBox.height)
        guard let image = source.cropping(to:top) else { return nil }
        func color(_ values:[Double]) -> RGBAColor { RGBAColor(red:values[0],green:values[1],blue:values[2],alpha:values[3]) }
        guard items.allSatisfy({ $0.background.count == 4 && $0.foreground.count == 4 }) else { return nil }
        return .init(image:image,pixelBox:pixelBox,items:items.map {
            MirrorItem(id:$0.id,translatedText:$0.text,presentation:$0.translated ? .translated : .selectionOnly,
                normalizedRect:$0.box,background:color($0.background),foreground:color($0.foreground),
                sourceSelectionFragments:$0.fragments.map { .init(text:$0.text,normalizedRect:$0.box) })
        },debugItems:[])
    }
}
