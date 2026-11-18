import AppKit
import ApplicationServices
import NotionAXCore

/// These closures only serialize already collected immutable values. They never query providers.
struct DiagnosticDocument: @unchecked Sendable {
    let estimatedBytes: Int
    let encode: () throws -> Data
    init<T: Encodable>(_ value: T, estimatedBytes: Int) {
        self.estimatedBytes = estimatedBytes
        encode = { let encoder=JSONEncoder(); encoder.outputFormatting=[.prettyPrinted,.sortedKeys]; return try encoder.encode(value) }
    }
    init(estimatedBytes:Int, encode:@escaping @Sendable () throws -> Data) { self.estimatedBytes=estimatedBytes;self.encode=encode }
    init(data: Data) { estimatedBytes=data.count; encode={ data } }
}
struct DiagnosticEvent: Codable, Sendable {
    let sequence: UInt64
    let date: Date
    let uptime: TimeInterval
    let name: String
    let frame: UUID?
    let fields: [String:String] // Call sites must supply only structural values, never document text/errors/paths.
}
struct DiagnosticFrameRecord: @unchecked Sendable {
    let id: UUID
    let session: UUID
    let frameID: UInt64
    let generation: Int
    let revision: Int
    let task: UInt64
    let receivedAt: UInt64
    let createdAt: Date
    var summary: [String:String]
    var documents: [String:DiagnosticDocument] = [:]
    var images: [String:CGImage] = [:]
    var omissions: [String] = []
    var estimatedBytes: Int {
        documents.values.reduce(0) { $0+$1.estimatedBytes } + images.values.reduce(0) { $0+$1.bytesPerRow*$1.height }
    }
}
struct DiagnosticSnapshot: @unchecked Sendable {
    let schemaVersion = 1
    let createdAt: Date
    let session: UUID
    let state: [String:String]
    let contentEnvironment: [String:String]
    let events: [DiagnosticEvent]
    let frames: [DiagnosticFrameRecord]
    let current: UUID?
    let displayed: UUID?
    let failed: UUID?
    let omissions: [String]
}
/// Bound to one coordinator, not a process-global bag of unrelated frames.
@MainActor final class DiagnosticRecorder {
    nonisolated static let maximumBytes = 128*1024*1024
    nonisolated static let maximumEvents = 5_000
    var enabled = true // Test/performance seam; production keeps lightweight history enabled.
    private(set) var session = UUID()
    private(set) var state: [String:String] = [:]
    private(set) var contentEnvironment: [String:String] = [:]
    private(set) var events: [DiagnosticEvent] = []
    private(set) var frames: [UUID:DiagnosticFrameRecord] = [:]
    private(set) var current: UUID?
    private(set) var displayed: UUID?
    private(set) var failed: UUID?
    private var sequence: UInt64 = 0
    private var omissions: [String] = []
    private(set) var stopped = true
    private let byteLimit: Int
    init(byteLimit: Int = maximumBytes) { self.byteLimit=byteLimit }
    func begin() {
        guard enabled else { return }
        session=UUID(); frames=[:];events=[];omissions=[];current=nil;displayed=nil;failed=nil
        state=[:];contentEnvironment=[:];stopped=false
        event("session.start")
    }
    func stop() { stopped=true; event("session.stop"); state["sessionState"]="stopped" }
    func update(_ values: [String:String], content: [String:String] = [:]) {
        guard enabled else { return }; state.merge(values) { _,new in new };contentEnvironment.merge(content) { _,new in new }
    }
    func event(_ name: String, frame: UUID? = nil, _ fields: [String:String] = [:], now: Date = Date()) {
        guard enabled else { return }
        sequence &+= 1
        events.append(.init(sequence:sequence,date:now,uptime:ProcessInfo.processInfo.systemUptime,name:name,frame:frame,fields:fields))
        let cutoff=now.addingTimeInterval(-300)
        if events.count > Self.maximumEvents { events.removeFirst(events.count-Self.maximumEvents) }
        if let index=events.firstIndex(where: { $0.date >= cutoff }),index>0 { events.removeFirst(index) }
    }
    @discardableResult func startFrame(image: CGImage, frameID: UInt64, receivedAt: UInt64,
                                      generation: Int, revision: Int, task: UInt64, mode: String) -> UUID? {
        guard enabled else { return nil }
        let id=UUID()
        frames[id] = .init(id:id,session:session,frameID:frameID,generation:generation,revision:revision,task:task,
            receivedAt:receivedAt,createdAt:Date(),summary:["mode":mode,"stage":"started","width":String(image.width),"height":String(image.height)],images:["source.png":image])
        current=id
        event("processing.start",frame:id,["mode":mode]); trim(prefer:id)
        return id
    }
    func event(_ name:String,_ fields:[String:String]) { event(name,frame:nil,fields) }
    func find(frameID:UInt64,generation:Int,revision:Int) -> UUID? {
        frames.values.filter { $0.frameID==frameID && $0.generation==generation && $0.revision==revision }.max { $0.task<$1.task }?.id
    }
    func matches(_ id: UUID?) -> Bool { guard let id else { return false };return frames[id]?.session == session }
    func add(_ name:String, document:DiagnosticDocument, to id:UUID?) {
        guard enabled,let id,matches(id) else { return }
        frames[id]?.documents[name]=document;trim(prefer:id)
    }
    func omit(_ reason:String,to id:UUID?) {
        guard let id,matches(id) else { return };frames[id]?.omissions.append(reason)
    }
    func image(_ name:String, _ image:CGImage?, to id:UUID?) {
        guard enabled,let id,matches(id),let image else { return }
        frames[id]?.images[name]=image;trim(prefer:id)
    }
    func mark(_ stage:String, id:UUID?, _ fields:[String:String] = [:]) {
        guard enabled,let id,matches(id) else { return }
        frames[id]?.summary.merge(fields) { _,new in new };frames[id]?.summary["stage"]=stage
        event(stage,frame:id,fields)
    }
    func error(_ error:Error?, stage:String, id:UUID?) {
        guard enabled else { return }
        if let id,!matches(id) { event("result.discarded",frame:id,["reason":"unretained_failure"]);return }
        if error is CancellationError { mark("processing.cancelled",id:id);return }
        let ns=error as NSError?
        // Raw descriptions/domains are content: their text can contain source strings or paths.
        mark("failure",id:id,["failureStage":stage,"errorCode":String(ns?.code ?? 0)])
        if id == nil,let error { contentEnvironment["error-"+stage]=String(describing:error) }
        if let error { add("error-\(stage).json",document:.init(["description":String(describing:error),"domain":ns?.domain ?? ""],estimatedBytes:4096),to:id) }
        failed=id; state["lastFailureStage"]=stage;state["lastErrorCode"]=String(ns?.code ?? 0)
        event("failure",frame:id,["stage":stage,"code":String(ns?.code ?? 0)])
        trim(prefer:id)
    }
    func submitted(_ frame:MirrorFrame, id:UUID?) {
        guard enabled,let id,matches(id) else { return }
        displayed=id
        mark("display.submitted",id:id,["items":String(frame.translatedItems.count)])
        let textBytes=frame.translatedItems.reduce(0) { $0+$1.translatedText.utf8.count*4+2048 }
        // Reuse the saved-image layer format for exact OCR geometry and presentation flags.
        let layer=AXImageOCRLayer(image:frame.image,pixelBox:CGRect(x:0,y:0,width:frame.image.width,height:frame.image.height),items:frame.translatedItems,debugItems:frame.ocrDebugItems)
        add("mirror-items.json",document:.init(estimatedBytes:textBytes,encode:{ try JSONEncoder().encode(AXImageOCRSavedLayer(layer)) }),to:id)
        add("ocr-debug.json",document:.init(frame.ocrDebugItems,estimatedBytes:textBytes),to:id)
        for (i,layer) in frame.imageOCRLayers.enumerated() {
            image("image-layer-\(i).png",layer.image,to:id)
        }
        let imageLayers=frame.imageOCRLayers
        add("image-layers.json",document:.init(estimatedBytes:textBytes,encode:{ try JSONEncoder().encode(imageLayers.enumerated().map { AXImageOCRSavedLayer($0.element,imageFile:"image-layer-\($0.offset).png") }) }),to:id)
        if let art=frame.axArtwork {
            add("render-layout.json",document:.init(art.diagnostics,estimatedBytes:art.diagnostics.count*4096),to:id)
            add("render-fragments.json",document:.init(art.fragments,estimatedBytes:art.fragments.count*192),to:id)
            add("render-clips.json",document:.init(art.clipRects,estimatedBytes:art.clipRects.count*96),to:id)
            add("selection-clips.json",document:.init(art.selectionClipRects,estimatedBytes:art.selectionClipRects.count*96),to:id)
            add("full-text-hover.json",document:.init(art.fullTextHover,estimatedBytes:textBytes),to:id)
            image("background.png",art.background,to:id);image("text.png",art.text,to:id);image("debug.png",art.debug,to:id)
        }
        trim(prefer:id)
    }
    private func trim(prefer:UUID?) {
        let keep=Set([current,displayed,failed].compactMap { $0 })
        frames=frames.filter { keep.contains($0.key) }
        // Drop payloads, never structural frame identity. This keeps incomplete exports honest.
        let ordered=frames.values.sorted { ($0.id == prefer ? Date.distantFuture : $0.createdAt) < ($1.id == prefer ? Date.distantFuture : $1.createdAt) }
        var total=frames.values.reduce(0) { $0+$1.estimatedBytes }
        for frame in ordered where total>byteLimit {
            total-=frame.estimatedBytes
            frames[frame.id]?.images=[:];frames[frame.id]?.documents=[:]
            if !(frames[frame.id]?.omissions.contains("payload_evicted_memory_limit") ?? false) { frames[frame.id]?.omissions.append("payload_evicted_memory_limit") }
        }
    }
    func snapshot(now:Date = Date()) -> DiagnosticSnapshot {
        // Prune by time even when no new events arrive (e.g. a stalled session).
        let recent=events.filter { $0.date >= now.addingTimeInterval(-300) }
        return .init(createdAt:now,session:session,state:state,contentEnvironment:contentEnvironment,
                     events:recent,frames:frames.values.sorted { $0.createdAt<$1.createdAt },current:current,displayed:displayed,failed:failed,omissions:omissions+(frames.isEmpty ? ["no_frame_captured"] : []))
    }
}

/// A weak link means a mirror view cannot extend a session's diagnostic lifetime.
@MainActor final class DiagnosticFrameContext {
    weak var recorder: DiagnosticRecorder?
    let id: UUID
    init(_ recorder:DiagnosticRecorder,id:UUID) { self.recorder=recorder;self.id=id }
}

struct DiagnosticNativeLayout: Codable {
    let id:UUID
    let box:CGRect
    let fontSize,horizontalScale:CGFloat
    let lineCount:Int
    let text:String
}

enum DiagnosticTaskScope {
    @TaskLocal static var context: DiagnosticFrameContext?
}

extension Dictionary where Key == String, Value == String {
    func mapKeysWithAXPrefix() -> [String:String] { Dictionary(uniqueKeysWithValues:map { ("ax."+$0.key,$0.value) }) }
}
