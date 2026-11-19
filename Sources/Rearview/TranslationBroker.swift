import Foundation
import SwiftUI
@preconcurrency import Translation

/// Request policy is immutable even when differently protected paragraphs share a batch.
struct TranslationRequestOptions: Hashable, Sendable {
    let protectsNonSourceText: Bool
    let context: String
    let preservesCodeSyntax: Bool

    init(protectsNonSourceText: Bool, context: String, preservesCodeSyntax: Bool = false) {
        self.protectsNonSourceText = protectsNonSourceText
        self.context = context
        self.preservesCodeSyntax = preservesCodeSyntax
    }
}

@MainActor
final class TranslationPrefetch {
    @TaskLocal static var current: TranslationPrefetch?
    var cancelled = false
}

@MainActor
final class TranslationBroker: ObservableObject {
    struct RequestKey: Hashable {
        let source: String
        let direction: TranslationDirection
        let options: TranslationRequestOptions
    }
    weak var diagnosticRecorder: DiagnosticRecorder?
    private struct Pending {
        let diagnosticContext:DiagnosticFrameContext?
        let id: UUID
        let key: RequestKey
        let plan: TranslationPlan
        let prefetch: TranslationPrefetch?
        let enqueuedAt: UInt64
    }
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<String, Error>
    }
    private var runningPrefetchIDs: Set<UUID> = []
    private var prefetchRequests: [RequestKey: TranslationPrefetch] = [:]
    private var queue: [Pending] = []
    private var requests: [RequestKey: UUID] = [:]
    private var waiters: [UUID: [Waiter]] = [:]
    private var cache: [RequestKey: String] = [:]
    private var prefetchedKeys: Set<RequestKey> = []
    private let segmentCache = TranslationSegmentCache<RequestKey>(capacity: 2_048)
    private(set) var preparationError: String?
    private var sessionReady = false
    private var sessionGeneration = 0
    private var policyGeneration = 0
    @Published private(set) var direction: TranslationDirection
    @Published private(set) var protectsNonSourceText: Bool

    static func canCommitResults(activeGeneration: Int, currentGeneration: Int, isCancelled: Bool) -> Bool {
        !isCancelled && activeGeneration == currentGeneration
    }
    var isReadyForTranslation: Bool { sessionReady }
    init(direction: TranslationDirection = TranslationDirection.load(),
         protectsNonSourceText: Bool = TranslationTextProtection.load()) {
        self.direction = direction
        self.protectsNonSourceText = protectsNonSourceText
    }
    func setDirection(_ direction: TranslationDirection) {
        guard self.direction != direction else { return }
        self.direction = direction
        direction.save()
        sessionGeneration += 1
        sessionReady = false
        clearPolicy()
    }
    func setProtectsNonSourceText(_ enabled: Bool) {
        guard protectsNonSourceText != enabled else { return }
        protectsNonSourceText = enabled
        clearPolicy()
    }
    private func clearPolicy() {
        policyGeneration += 1
        cache.removeAll(); segmentCache.removeAll(); prefetchedKeys.removeAll()
        failPending(TranslatorError.translationSessionUnavailable)
    }
    func translate(_ source: String) async throws -> String {
        try await translate(source, options: .init(protectsNonSourceText: protectsNonSourceText, context: "ocr"))
    }
    func translate(_ source: String, options: TranslationRequestOptions) async throws -> String {
        guard let context=DiagnosticTaskScope.context,context.recorder?.enabled == true else { return try await performTranslate(source,options:options) }
        let requestID=UUID(),started=Date()
        var record=["source":source,"context":options.context,"protectsNonSourceText":String(options.protectsNonSourceText),"preservesCodeSyntax":String(options.preservesCodeSyntax),"direction":direction.rawValue]
        record["status"]="pending"
        context.recorder?.event("translation.request",frame:context.id,["request":requestID.uuidString])
        context.recorder?.add("request-\(requestID).json",document:.init(record,estimatedBytes:source.utf8.count*4+1024),to:context.id)
        defer {
            record["seconds"]=String(Date().timeIntervalSince(started))
            context.recorder?.add("request-\(requestID).json",document:.init(record,estimatedBytes:record.values.reduce(0) { $0+$1.utf8.count*4 }+512),to:context.id)
        }
        do {
            let result=try await performTranslate(source,options:options)
            record["output"]=result;record["status"]="completed"
            return result
        } catch { record["status"]=error is CancellationError ? "cancelled":"failed";record["error"]=String(describing:error);throw error }
    }
    private func performTranslate(_ source:String,options:TranslationRequestOptions) async throws -> String {
        try Task.checkCancellation()
        PerformanceProfiler.shared.increment("translation.requested")
        // Preserve AX text exactly; the legacy OCR API keeps its trimming behavior.
        let text = options.context == "ocr" ? source.trimmingCharacters(in: .whitespacesAndNewlines) : source
        let key = RequestKey(source: text, direction: direction, options: options)
        if let cached = cache[key] {
            if TranslationPrefetch.current == nil, prefetchedKeys.remove(key) != nil {
                PerformanceProfiler.shared.increment("translation.prefetchReused")
            }
            PerformanceProfiler.shared.increment("translation.cacheHit")
            PerformanceProfiler.shared.increment("translation.completed")
            return cached
        }
        PerformanceProfiler.shared.increment("translation.cacheMiss")
        guard sessionReady else { throw TranslatorError.translationSessionUnavailable }
        let prefetch = TranslationPrefetch.current
        guard prefetch?.cancelled != true else { throw CancellationError() }
        let waiterID = UUID()
        let result: String = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                if prefetchRequests[key]?.cancelled == true, let stale = requests[key],
                   !runningPrefetchIDs.contains(stale) {
                    requests.removeValue(forKey: key)
                    prefetchRequests.removeValue(forKey: key)
                    queue.removeAll { $0.id == stale }
                    waiters.removeValue(forKey: stale)?.forEach { $0.continuation.resume(throwing: CancellationError()) }
                }
                let requestID: UUID
                if let existing = requests[key] {
                    requestID = existing
                    if prefetch == nil, runningPrefetchIDs.contains(existing) {
                        PerformanceProfiler.shared.increment("translation.prefetchJoined")
                    }
                    PerformanceProfiler.shared.increment("translation.inFlightHit")
                } else {
                    requestID = UUID()
                    requests[key] = requestID
                    prefetchRequests[key] = prefetch
                    queue.append(Pending(diagnosticContext:DiagnosticTaskScope.context,id: requestID, key: key,
                        plan: LanguageProtector.makeTranslationPlan(for: text, direction: direction,
                            protectNonSourceText: options.protectsNonSourceText,
                            preserveCodeSyntax: options.preservesCodeSyntax),
                        prefetch: prefetch, enqueuedAt: DispatchTime.now().uptimeNanoseconds))
                }
                waiters[requestID, default: []].append(Waiter(id: waiterID, continuation: continuation))
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelWaiter(waiterID, key: key) }
        }
        try Task.checkCancellation()
        return result
    }
    private func cancelWaiter(_ id: UUID, key: RequestKey) {
        guard let requestID = requests[key], var values = waiters[requestID],
              let index = values.firstIndex(where: { $0.id == id }) else { return }
        values.remove(at: index).continuation.resume(throwing: CancellationError())
        if values.isEmpty {
            waiters.removeValue(forKey: requestID)
            guard !runningPrefetchIDs.contains(requestID) else { return }
            requests.removeValue(forKey: key)
            prefetchRequests.removeValue(forKey: key)
            queue.removeAll { $0.id == requestID }
        } else { waiters[requestID] = values }
    }
    func run(session: TranslationSession) async {
        await run(prepare: { try await session.prepareTranslation() }, model: { sources in
            nonisolated(unsafe) let requests = sources.enumerated().map {
                TranslationSession.Request(sourceText: $1, clientIdentifier: String($0))
            }
            let responses = try await session.translations(from: requests)
            var result: [String?] = Array(repeating: nil, count: sources.count)
            for response in responses {
                if let id = response.clientIdentifier, let index = Int(id), result.indices.contains(index) {
                    result[index] = response.targetText
                }
            }
            guard result.allSatisfy({ $0 != nil }) else { throw TranslatorError.translationSessionUnavailable }
            return result.map { $0! }
        })
    }
    /// Shared worker seam also used by deterministic cache/cancellation tests.
    func run(prepare: () async throws -> Void, model: ([String]) async throws -> [String]) async {
        let activeGeneration = sessionGeneration
        preparationError = nil
        diagnosticRecorder?.event("translation.prepare.start")
        do { try await prepare() } catch {
            diagnosticRecorder?.event("translation.prepare.failed", ["code":String((error as NSError).code)])
            if activeGeneration == sessionGeneration {
                preparationError = String(describing:error)
                failPending(error)
            }
            return
        }
        guard activeGeneration == sessionGeneration, !Task.isCancelled else { return }
        sessionReady = true
        diagnosticRecorder?.event("translation.prepare.ready")
        defer {
            if activeGeneration == sessionGeneration {
                sessionReady = false
                failPending(TranslatorError.translationSessionUnavailable)
            }
        }
        while !Task.isCancelled, activeGeneration == sessionGeneration {
            if queue.isEmpty { try? await Task.sleep(for: .milliseconds(12)); continue }
            let cancelled = queue.filter { $0.prefetch?.cancelled == true }
            for pending in cancelled { finish(pending, result: .failure(CancellationError())) }
            queue.removeAll { $0.prefetch?.cancelled == true }
            let foreground = prefetchRequests.isEmpty ? queue : queue.filter { $0.prefetch == nil }
            let batch = foreground.isEmpty ? Array(queue.prefix(1)) : Array(foreground.prefix(24))
            let ids = Set(batch.map(\.id))
            queue.removeAll { ids.contains($0.id) }
            guard !batch.isEmpty else { continue }
            let activePolicy = policyGeneration
            do {
                var missing: [RequestKey] = [], seen = Set<RequestKey>()
                // Keep batch results alive even when inserting a miss evicts a hit used below.
                var batchResults: [RequestKey: String] = [:]
                for pending in batch {
                    PerformanceProfiler.shared.recordElapsed(.translationQueue, startedAt: pending.enqueuedAt,
                        itemCount: 1, characterCount: pending.plan.translatableCharacterCount)
                    for segment in pending.plan.segments where segment.kind == .translate {
                        let key = RequestKey(source: segment.text, direction: pending.key.direction, options: pending.key.options)
                        if let cached = segmentCache.value(for: key) {
                            batchResults[key] = cached
                            PerformanceProfiler.shared.increment("translation.segmentCacheHit")
                        } else if seen.insert(key).inserted {
                            PerformanceProfiler.shared.increment("translation.segmentCacheMiss"); missing.append(key)
                        } else { PerformanceProfiler.shared.increment("translation.segmentBatchDuplicate") }
                    }
                }
                if !missing.isEmpty {
                    let token = PerformanceProfiler.shared.begin(.translationModel, itemCount: missing.count,
                        characterCount: missing.reduce(0) { $0 + $1.source.count })
                    PerformanceProfiler.shared.increment("translation.modelCall")
                    PerformanceProfiler.shared.increment("translation.modelBatchSegments", by: missing.count)
                    let output: [String]
                    let diagnosticModelID=UUID(),modelStarted=Date()
                    let runningPrefetch = batch.first.flatMap { $0.prefetch == nil ? nil : $0.id }
                    if let runningPrefetch { runningPrefetchIDs.insert(runningPrefetch) }
                    defer { if let runningPrefetch { runningPrefetchIDs.remove(runningPrefetch) } }
                    do {
                        output = try await model(missing.map(\.source)); PerformanceProfiler.shared.end(token)
                        recordModelBatch(batch,id:diagnosticModelID,sources:missing.map(\.source),outputs:output,error:nil,started:modelStarted)
                    } catch {
                        recordModelBatch(batch,id:diagnosticModelID,sources:missing.map(\.source),outputs:[],error:error,started:modelStarted)
                        PerformanceProfiler.shared.end(token);throw error
                    }
                    if batch.first?.prefetch != nil {
                        for pending in queue where pending.prefetch == nil {
                            PerformanceProfiler.shared.recordElapsed(.translationPrefetchForegroundWait, startedAt: pending.enqueuedAt)
                        }
                    }
                    guard Self.canCommitResults(activeGeneration: activeGeneration, currentGeneration: sessionGeneration,
                        isCancelled: Task.isCancelled) else { return }
                    guard activePolicy == policyGeneration else { continue }
                    guard output.count == missing.count else { throw TranslatorError.translationSessionUnavailable }
                    for (key, text) in zip(missing, output) {
                        segmentCache.insert(text, for: key)
                        batchResults[key] = text
                        PerformanceProfiler.shared.increment("translation.segmentTranslated")
                    }
                }
                guard activePolicy == policyGeneration else { continue }
                for pending in batch {
                    // An orphaned old request cannot complete newly queued waiters for the same key.
                    guard requests[pending.key] == pending.id else { continue }
                    var output = ""
                    for segment in pending.plan.segments {
                        if segment.kind == .preserve { output += segment.text }
                        else if let text = batchResults[RequestKey(source: segment.text,
                            direction: pending.key.direction, options: pending.key.options)] { output += text }
                        else { throw TranslatorError.translationSessionUnavailable }
                    }
                    let willTrim = cache.count >= 512
                    trimCacheIfNeeded(&cache, maximumCount: 512, removalCount: 128)
                    cache[pending.key] = output
                    if pending.prefetch != nil { prefetchedKeys.insert(pending.key) }
                    if willTrim, !prefetchedKeys.isEmpty { prefetchedKeys = prefetchedKeys.filter { cache[$0] != nil } }
                    finish(pending, result: .success(output))
                }
            } catch {
                guard activePolicy == policyGeneration else { continue }
                batch.forEach { finish($0, result: .failure(error)) }
            }
        }
    }
    private func recordModelBatch(_ batch:[Pending],id:UUID,sources:[String],outputs:[String],error:Error?,started:Date) {
        let data=DiagnosticModelBatch(id:id,sources:sources,outputs:outputs,error:error.map { String(describing:$0) },seconds:Date().timeIntervalSince(started))
        var recorded=Set<UUID>()
        for request in batch {
            guard let context=request.diagnosticContext,recorded.insert(context.id).inserted else { continue }
            context.recorder?.add("model-\(id).json",document:.init(data,estimatedBytes:(sources+outputs).reduce(0) { $0+$1.utf8.count*4 }+1024),to:context.id)
            context.recorder?.event("translation.model.finished",frame:context.id,["modelBatch":id.uuidString,"count":String(sources.count),"seconds":String(data.seconds),"failed":String(error != nil)])
        }
    }
    private func failPending(_ error: Error) {
        queue.removeAll(); requests.removeAll(); prefetchRequests.removeAll()
        let all = waiters; waiters.removeAll()
        all.values.joined().forEach { $0.continuation.resume(throwing: error) }
    }
    private func finish(_ pending: Pending, result: Result<String, Error>) {
        guard requests[pending.key] == pending.id else { return }
        requests.removeValue(forKey: pending.key)
        prefetchRequests.removeValue(forKey: pending.key)
        guard let values = waiters.removeValue(forKey: pending.id) else { return }
        if case .success = result { PerformanceProfiler.shared.increment("translation.completed", by: values.count) }
        values.forEach { $0.continuation.resume(with: result) }
    }
    private func trimCacheIfNeeded<K>(_ cache: inout [K: String], maximumCount: Int, removalCount: Int) {
        guard cache.count >= maximumCount else { return }
        for key in cache.keys.prefix(removalCount) { cache[key] = nil }
    }
}

@available(macOS 26.4, *)
enum TranslationStrategyPolicy {
    static func preferred() -> TranslationSession.Strategy { .lowLatency }
}

struct TranslationBridgeView: View {
    @ObservedObject var broker: TranslationBroker

    @ViewBuilder
    var body: some View {
        if #available(macOS 26.4, *) {
            translationHost.translationTask(
                source: broker.direction.sourceLocale,
                target: broker.direction.targetLocale,
                preferredStrategy: TranslationStrategyPolicy.preferred()
            ) { session in
                await broker.run(session: session)
            }
            .id(broker.direction.rawValue)
        } else {
            translationHost.translationTask(
                source: broker.direction.sourceLocale,
                target: broker.direction.targetLocale
            ) { session in
                await broker.run(session: session)
            }
            .id(broker.direction.rawValue)
        }
    }

    private var translationHost: some View {
        Color.clear.frame(width: 1, height: 1)
    }
}

private struct DiagnosticModelBatch:Codable {
    let id:UUID
    let sources,outputs:[String]
    let error:String?
    let seconds:Double
}
