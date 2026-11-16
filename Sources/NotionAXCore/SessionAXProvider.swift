import AppKit
import ApplicationServices

public enum TextExtractionMode: Sendable { case ocr, ax }
public struct AXExtractionRequest: Sendable {
    public let collectParentTextDiagnostics: Bool
    public let processID: pid_t
    public let windowID: CGWindowID
    public let windowFrame: CGRect
    public let selectionRegion: CGRect
    public init(processID: pid_t, windowID: CGWindowID, windowFrame: CGRect, selectionRegion: CGRect, collectParentTextDiagnostics: Bool = false) {
        self.collectParentTextDiagnostics = collectParentTextDiagnostics
        self.processID = processID; self.windowID = windowID
        self.windowFrame = windowFrame; self.selectionRegion = selectionRegion
    }
}
public enum AXExtractionError: String, Error, Sendable {
    case permissionDenied, targetTerminated, windowMappingFailed, windowChanged, activationFailed, invalidRequest
}
// JSON is the versioned report wire format. Only value data crosses the queue;
// handles and Chromium text markers remain private to a single traversal.
public struct AXExtractionSnapshot: Sendable {
    public var imageRegions: [AXImageRegion] {
        struct Metadata: Decodable { let imageRegions: [AXImageRegion]? }
        return (try? JSONDecoder().decode(Metadata.self, from: metadata).imageRegions) ?? []
    }
    public let observations: [AXNode]
    public let paragraphUnits: [AXParagraph]
    public let status: AXCollectionStatus
    public let nodes: Data
    public let selected: Data
    public let paragraphs: Data
    public let metadata: Data
    package init(nodes: Data, selected: Data, paragraphs: Data, metadata: Data) throws {
        struct Units: Decodable { let units: [AXParagraph] }
        self.nodes = nodes; self.selected = selected; self.paragraphs = paragraphs; self.metadata = metadata
        let decoder = JSONDecoder()
        observations = try decoder.decode([AXNode].self,from:nodes)
        paragraphUnits = try decoder.decode(Units.self,from:paragraphs).units
        let fields = try JSONSerialization.jsonObject(with:metadata) as? [String:Any]
        status = AXCollectionStatus(rawValue:fields?["status"] as? String ?? "failed") ?? .failed
    }
    init(nodes: [[String: Any]], selected: [[String: Any]], paragraphs: [[String: Any]], metadata: [String: Any]) throws {
        let options: JSONSerialization.WritingOptions = [.sortedKeys, .prettyPrinted]
        self.nodes = try JSONSerialization.data(withJSONObject: nodes, options: options)
        self.selected = try JSONSerialization.data(withJSONObject: selected, options: options)
        self.paragraphs = try JSONSerialization.data(withJSONObject: ["schemaVersion":1,"units":paragraphs,"unresolved":[]], options: options)
        self.metadata = try JSONSerialization.data(withJSONObject: metadata, options: options)
        self.observations = try JSONDecoder().decode([AXNode].self, from:self.nodes)
        self.paragraphUnits = try JSONDecoder().decode([AXParagraph].self, from:JSONSerialization.data(withJSONObject:paragraphs))
        self.status = AXCollectionStatus(rawValue:metadata["status"] as? String ?? "failed") ?? .failed
    }
}
public protocol SessionAXProvider: Sendable {
    func collect(_ request: AXExtractionRequest) async throws -> AXExtractionSnapshot
    func endSession() async
}
package final class AXCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func check() throws { lock.lock(); let value = cancelled; lock.unlock(); if value { throw CancellationError() } }
    var isCancelled: Bool { (try? check()) == nil }
}
package enum AXWindowMatch {
    static func near(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX-b.minX)<2 && abs(a.minY-b.minY)<2 && abs(a.width-b.width)<2 && abs(a.height-b.height)<2
    }
}
public final class NativeSessionAXProvider: SessionAXProvider, @unchecked Sendable {
    private let queue = DispatchQueue(label: "rearview.ax-extraction", qos: .userInitiated)
    // Accessed exclusively on queue, including restoration.
    private var activation: (pid_t, AXUIElement, CFTypeRef?, Date)?
    public init() {}
    private func restore() {
        if let (_, app, prior, _) = activation, let prior { AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, prior) }
        activation = nil
    }
    public func endSession() async {
        await withCheckedContinuation { continuation in queue.async { self.restore(); continuation.resume() } }
    }
    public func collect(_ request: AXExtractionRequest) async throws -> AXExtractionSnapshot {
        let cancellation = AXCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do { continuation.resume(returning: try self.collect(request, cancellation)) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { cancellation.cancel() }
    }
    private func collect(_ request: AXExtractionRequest, _ cancellation: AXCancellation) throws -> AXExtractionSnapshot {
        try cancellation.check()
        guard [request.windowFrame,request.selectionRegion].allSatisfy({
            [$0.minX,$0.minY,$0.width,$0.height].allSatisfy(\.isFinite) && $0.width > 0 && $0.height > 0
        }) else { throw AXExtractionError.invalidRequest }
        guard AXIsProcessTrusted() else { throw AXExtractionError.permissionDenied }
        guard let process = NSRunningApplication(processIdentifier: request.processID), !process.isTerminated,
              process.bundleIdentifier == "notion.id" else { throw AXExtractionError.targetTerminated }
        let initializationStarted = Date()
        var initialized = false
        if activation?.0 != request.processID {
            restore()
            let app = AXUIElementCreateApplication(request.processID)
            AXUIElementSetMessagingTimeout(app, 0.35)
            let prior = get(app, "AXManualAccessibility")
            guard AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue) == .success else { throw AXExtractionError.activationFailed }
            activation = (request.processID, app, prior, Date().addingTimeInterval(2.5))
            initialized = true
        }
        guard let (_, app, _, readyAt) = activation else { throw AXExtractionError.activationFailed }
        while Date() < readyAt { try cancellation.check(); Thread.sleep(forTimeInterval:min(0.05, max(0, readyAt.timeIntervalSinceNow))) }
        let initializationSeconds = Date().timeIntervalSince(initializationStarted)
        let mappingStarted = Date()
        // Map the session's CG window, never the focused window. Ambiguity fails.
        let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], request.windowID) as? [[String: Any]] ?? []
        guard info.contains(where: {
            ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == request.windowID &&
            ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == request.processID
        }) else { throw AXExtractionError.targetTerminated }
        let windows = get(app, "AXWindows") as? [AXUIElement] ?? []
        let matches = windows.filter { frame($0).map { AXWindowMatch.near($0, request.windowFrame) } == true }
        guard matches.count == 1 else { throw AXExtractionError.windowMappingFailed }
        let mappingSeconds = Date().timeIntervalSince(mappingStarted)
        var snapshot = try AXCollector.collect(request, window: matches[0], cancellation: cancellation)
        var metadata = try JSONSerialization.jsonObject(with: snapshot.metadata) as! [String: Any]
        metadata["initializationSeconds"] = initializationSeconds
        metadata["windowMappingSeconds"] = mappingSeconds
        metadata["activationObservationDelaySeconds"] = initialized ? 2.5 : 0
        snapshot = try AXExtractionSnapshot(nodes: JSONSerialization.jsonObject(with:snapshot.nodes) as! [[String:Any]], selected: JSONSerialization.jsonObject(with:snapshot.selected) as! [[String:Any]], paragraphs: (JSONSerialization.jsonObject(with:snapshot.paragraphs) as! [String:Any])["units"] as! [[String:Any]], metadata: metadata)
        return snapshot
    }
}
