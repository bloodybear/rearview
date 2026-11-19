import AppKit
import ApplicationServices

public enum TextExtractionMode: Sendable { case ocr, ax }
public struct AXExtractionRequest: Sendable {
    public let diagnosticRequestID = UUID()
    public let prefetch: Bool
    public let retainScrollAnchors: Bool
    public let visibleFirst: Bool
    public let pruneOffscreenBranches: Bool
    public let collectParentTextDiagnostics: Bool
    public let processID: pid_t
    public let windowID: CGWindowID
    public let windowFrame: CGRect
    public let selectionRegion: CGRect
    public init(processID: pid_t, windowID: CGWindowID, windowFrame: CGRect, selectionRegion: CGRect, collectParentTextDiagnostics: Bool = false, visibleFirst: Bool = false, pruneOffscreenBranches: Bool = false, prefetch: Bool = false, retainScrollAnchors: Bool = false) {
        self.prefetch = prefetch
        self.retainScrollAnchors = retainScrollAnchors
        self.visibleFirst = visibleFirst
        self.pruneOffscreenBranches = pruneOffscreenBranches
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
    public let prefetchCandidateCount: Int
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
        prefetchCandidateCount = fields?["prefetchCandidateCount"] as? Int ?? 0
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
        self.prefetchCandidateCount = metadata["prefetchCandidateCount"] as? Int ?? 0
        self.status = AXCollectionStatus(rawValue:metadata["status"] as? String ?? "failed") ?? .failed
    }
}
public protocol SessionAXProvider: Sendable {
    func collect(_ request: AXExtractionRequest) async throws -> AXExtractionSnapshot
    func diagnosticSnapshot() async -> AXCollectionDiagnostics?
    func endSession() async
    func nextPrefetchSource(requestID: UUID) async throws -> String?
    func scrollDisplacement(from sourceID: UUID, to request: AXExtractionRequest) async -> CGFloat?
}
public extension SessionAXProvider {
    func diagnosticSnapshot() async -> AXCollectionDiagnostics? { nil }
    func nextPrefetchSource(requestID: UUID) async throws -> String? { nil }
    func scrollDisplacement(from sourceID: UUID, to request: AXExtractionRequest) async -> CGFloat? { nil }
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
    // Both the handles and the positions captured with them belong to this serial queue.
    private var scrollAnchors: (request: AXExtractionRequest, elements: [(AXUIElement, CGPoint)])?

    public func scrollDisplacement(from sourceID: UUID, to request: AXExtractionRequest) async -> CGFloat? {
        let cancellation = AXCancellation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async {
                    guard !cancellation.isCancelled, let anchors = self.scrollAnchors,
                          anchors.request.diagnosticRequestID == sourceID,
                          anchors.request.processID == request.processID,
                          anchors.request.windowID == request.windowID,
                          anchors.request.windowFrame == request.windowFrame,
                          anchors.request.selectionRegion == request.selectionRegion,
                          anchors.elements.count >= 2 else {
                        continuation.resume(returning: nil)
                        return
                    }
                    let movements = anchors.elements.compactMap { element, before -> CGFloat? in
                        guard !cancellation.isCancelled, let after = position(element),
                              abs(after.x - before.x) <= 1 else { return nil }
                        return after.y - before.y
                    }
                    continuation.resume(returning: cancellation.isCancelled ? nil : Self.agreedScrollDisplacement(movements))
                }
            }
        } onCancel: { cancellation.cancel() }
    }

    static func agreedScrollDisplacement(_ movements: [CGFloat]) -> CGFloat? {
        guard let first = movements.first(where: { candidate in
            candidate.isFinite && abs(candidate) >= 3 &&
                movements.filter { abs($0 - candidate) <= 1 }.count >= 2
        }) else { return nil }
        return first
    }

    private var prefetchID: UUID?
    private var candidates: ArraySlice<AXUIElement> = []
    public func nextPrefetchSource(requestID: UUID) async throws -> String? {
        let cancellation = AXCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do {
                        try cancellation.check()
                        guard self.prefetchID == requestID, let candidate = self.candidates.popFirst() else {
                            continuation.resume(returning: nil)
                            return
                        }
                        self.setPrefetchReading(true)
                        defer { self.setPrefetchReading(false) }
                        continuation.resume(returning: try AXPrefetch.source(candidate, cancellation: cancellation) ?? "")
                    } catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { cancellation.cancel() }
    }

    private var activationFacts: [String:String] = [:]
    private var lastDiagnostic: AXCollectionDiagnostics?
    public func diagnosticSnapshot() async -> AXCollectionDiagnostics? {
        await withCheckedContinuation { continuation in queue.async { continuation.resume(returning:self.lastDiagnostic) } }
    }
    private let queue = DispatchQueue(label: "rearview.ax-extraction", qos: .userInitiated)
    // Accessed exclusively on queue. Ending a session leaves target AX activation enabled.
    private var activation: (pid_t, AXUIElement)?
    private var activatedAt: TimeInterval = 0
    private var readinessFinished = false
    private let cancellationLock = NSLock()
    private var activeCancellation: AXCancellation?
    private var prefetchReading = false
    private func setPrefetchReading(_ value: Bool) {
        cancellationLock.lock(); prefetchReading = value; cancellationLock.unlock()
    }
    private func prefetchReadInFlight() -> Bool {
        cancellationLock.lock(); defer { cancellationLock.unlock() }
        return prefetchReading
    }
    private func setActiveCancellation(_ value: AXCancellation?) {
        cancellationLock.lock(); activeCancellation = value; cancellationLock.unlock()
    }
    private func cancelActiveCollection() {
        cancellationLock.lock(); activeCancellation?.cancel(); cancellationLock.unlock()
    }
    public init() {}
    private func clearSessionActivation() {
        candidates = []; prefetchID = nil
        scrollAnchors = nil
        activation = nil
        readinessFinished = false
        activationFacts=[:]
    }
    public func endSession() async {
        cancelActiveCollection()
        await withCheckedContinuation { continuation in queue.async { self.clearSessionActivation(); continuation.resume() } }
    }
    public func collect(_ request: AXExtractionRequest) async throws -> AXExtractionSnapshot {
        let waitStart = prefetchReadInFlight() ? ProcessInfo.processInfo.systemUptime : nil
        let cancellation = AXCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    self.setActiveCancellation(cancellation)
                    defer { self.setActiveCancellation(nil) }
                    do { continuation.resume(returning: try self.collect(request, cancellation, prefetchWait: waitStart.map { ProcessInfo.processInfo.systemUptime - $0 })) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { cancellation.cancel() }
    }
    private func collect(_ request: AXExtractionRequest, _ cancellation: AXCancellation, prefetchWait: TimeInterval?) throws -> AXExtractionSnapshot {
        candidates = []; prefetchID = nil
        scrollAnchors = nil
        let started=Date()
        let queries=AXQueryDiagnostics()
        var diagnostic=AXCollectionDiagnostics(fields:["requestID":request.diagnosticRequestID.uuidString,"stage":"request","processID":String(request.processID),"windowID":String(request.windowID)])
        Thread.current.threadDictionary["rearview.ax.diagnostics"]=queries
        defer {
            diagnostic.fields["elapsedSeconds"]=String(Date().timeIntervalSince(started))
            diagnostic.queryResults=queries.counts
            self.lastDiagnostic=diagnostic
            Thread.current.threadDictionary.removeObject(forKey:"rearview.ax.diagnostics")
        }
        try cancellation.check()
        guard [request.windowFrame,request.selectionRegion].allSatisfy({
            [$0.minX,$0.minY,$0.width,$0.height].allSatisfy(\.isFinite) && $0.width > 0 && $0.height > 0
        }) else { throw AXExtractionError.invalidRequest }
        diagnostic.fields["accessibilityTrusted"]=String(AXIsProcessTrusted())
        diagnostic.fields["stage"]="permission"
        guard AXIsProcessTrusted() else { throw AXExtractionError.permissionDenied }
        guard let process = NSRunningApplication(processIdentifier: request.processID), !process.isTerminated,
              process.bundleIdentifier == "notion.id" else { throw AXExtractionError.targetTerminated }
        let initializationStarted = Date()
        var initialized = false
        if activation?.0 != request.processID {
            clearSessionActivation()
            let app = AXUIElementCreateApplication(request.processID)
            AXUIElementSetMessagingTimeout(app, 0.35)
            diagnostic.fields["stage"]="activation"
            let prior = get(app, "AXManualAccessibility")
            diagnostic.fields["previousManualAccessibility"]=(prior as? Bool).map(String.init) ?? "unavailable"
            activatedAt = ProcessInfo.processInfo.systemUptime
            let setResult=AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            diagnostic.fields["manualAccessibilitySetResult"]=String(setResult.rawValue)
            diagnostic.fields["manualAccessibilityReadback"]=(get(app,"AXManualAccessibility") as? Bool).map(String.init) ?? "unavailable"
            activationFacts=diagnostic.fields.filter { ["previousManualAccessibility","manualAccessibilitySetResult","manualAccessibilityReadback"].contains($0.key) }
            guard setResult == .success else { throw AXExtractionError.activationFailed }
            activation = (request.processID, app)
            initialized = true
        }
        guard let (_, app) = activation else { throw AXExtractionError.activationFailed }
        try cancellation.check()
        let initializationSeconds = Date().timeIntervalSince(initializationStarted)
        diagnostic.fields.merge(activationFacts) { old,_ in old }
        diagnostic.fields["activationReused"]=String(!initialized)
        diagnostic.fields["initializationSeconds"]=String(initializationSeconds)
        var totalMappingSeconds: TimeInterval = 0
        func attempt() throws -> AXExtractionSnapshot {
            try cancellation.check()
            guard let process = NSRunningApplication(processIdentifier:request.processID), !process.isTerminated else { throw AXExtractionError.targetTerminated }
            diagnostic.fields["stage"]="window_mapping"
            let mappingStarted = Date()
            // Map the session's CG window, never the focused window. Ambiguity fails.
            let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], request.windowID) as? [[String: Any]] ?? []
            guard info.contains(where: {
                ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == request.windowID &&
                ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == request.processID
            }) else { throw AXExtractionError.targetTerminated }
            let windows = get(app, "AXWindows") as? [AXUIElement] ?? []
            diagnostic.fields["windowCount"]=String(windows.count)
            let matches = windows.filter { frame($0).map { AXWindowMatch.near($0, request.windowFrame) } == true }
            diagnostic.fields["matchingWindows"]=String(matches.count)
            guard matches.count == 1 else { throw AXExtractionError.windowMappingFailed }
            let mappingSeconds = Date().timeIntervalSince(mappingStarted)
            diagnostic.fields["stage"]="collection"
            candidates = []; prefetchID = nil
            let retain: (([AXUIElement]) -> Void)? = request.prefetch ? { elements in
                self.prefetchID = request.diagnosticRequestID
                self.candidates = elements[...]
            } : nil
            scrollAnchors = nil
            let rememberScrollAnchors: (([(AXUIElement, CGPoint)]) -> Void)? = request.retainScrollAnchors ? { elements in
                self.scrollAnchors = (request, elements)
            } : nil
            let snapshot = try AXCollector.collect(request, window: matches[0], cancellation: cancellation,
                prefetch: retain, scrollAnchors: rememberScrollAnchors)
            totalMappingSeconds += mappingSeconds
            return snapshot
        }
        var attempts: [[String:Any]] = []
        var totalWait: TimeInterval = 0
        var snapshot: AXExtractionSnapshot
        while true {
            try cancellation.check()
            let attemptStarted = ProcessInfo.processInfo.systemUptime - activatedAt
            let countsBefore = queries.counts
            var result: AXExtractionSnapshot?
            var pendingError: Error?
            var reasons: [String] = []
            do {
                let collected = try attempt()
                result = collected
                let fields = try JSONSerialization.jsonObject(with:collected.metadata) as? [String:Any]
                reasons = fields?["activationReadinessReasons"] as? [String] ?? []
            } catch let error as AXReadinessError {
                pendingError = error
                reasons = ["visibility_search_unavailable"]
            }
            let elapsed = ProcessInfo.processInfo.systemUptime - activatedAt
            attempts.append(["startedAfterActivationSeconds":attemptStarted,
                "elapsedSeconds":elapsed-attemptStarted,"reasons":reasons,
                "status":result?.status.rawValue ?? "failed",
                "queryResults":queries.counts.reduce(into:[String:Int]()) { values, entry in
                    let count = entry.value - (countsBefore[entry.key] ?? 0)
                    if count > 0 { values[entry.key] = count }
                }])
            diagnostic.fields["activationReadinessAttempts"] = String(data:try JSONSerialization.data(withJSONObject:attempts),encoding:.utf8)
            guard !readinessFinished, !reasons.isEmpty,
                  let delay = AXActivationReadiness.nextDelay(attemptStarted:attemptStarted,elapsed:elapsed) else {
                readinessFinished = true
                diagnostic.fields["activationReadinessExit"] = reasons.isEmpty ? "no_retryable_missing_data" : "final_attempt_exhausted"
                if let pendingError { throw pendingError }
                guard let result else { throw AXExtractionError.activationFailed }
                snapshot = result
                break
            }
            diagnostic.fields["stage"]="activation_readiness_wait"
            totalWait += try AXActivationReadiness.wait(delay,cancellation:cancellation)
        }
        var metadata = try JSONSerialization.jsonObject(with: snapshot.metadata) as! [String: Any]
        metadata["prefetchCandidateCount"] = candidates.count
        metadata["prefetchAXWaitSeconds"] = prefetchWait
        metadata["initializationSeconds"] = initializationSeconds
        metadata["windowMappingSeconds"] = totalMappingSeconds
        metadata["activationObservationDelaySeconds"] = totalWait
        metadata["activationReadinessAttempts"] = attempts
        metadata["activationReadinessExit"] = diagnostic.fields["activationReadinessExit"]
        snapshot = try AXExtractionSnapshot(nodes: JSONSerialization.jsonObject(with:snapshot.nodes) as! [[String:Any]], selected: JSONSerialization.jsonObject(with:snapshot.selected) as! [[String:Any]], paragraphs: (JSONSerialization.jsonObject(with:snapshot.paragraphs) as! [String:Any])["units"] as! [[String:Any]], metadata: metadata)
        diagnostic.fields["stage"]="finished"
        diagnostic.fields["status"]=snapshot.status.rawValue
        diagnostic.fields["nodes"]=String(snapshot.observations.count)
        diagnostic.fields["paragraphs"]=String(snapshot.paragraphUnits.count)
        return snapshot
    }
}
