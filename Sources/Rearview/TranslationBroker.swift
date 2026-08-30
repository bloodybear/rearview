import Foundation
import SwiftUI
@preconcurrency import Translation

@MainActor
final class TranslationBroker: ObservableObject {
    private struct Pending {
        let plan: TranslationPlan
        let enqueuedAt: UInt64
    }

    private var queue: [Pending] = []
    private var waiters: [String: [CheckedContinuation<String, Error>]] = [:]
    private var cache: [String: String] = [:]
    private var segmentCache: [String: String] = [:]
    private var sessionReady = false
    private var sessionGeneration = 0
    private var policyGeneration = 0
    @Published private(set) var direction: TranslationDirection
    @Published private(set) var protectsNonSourceText: Bool

    static func canCommitResults(
        activeGeneration: Int, currentGeneration: Int, isCancelled: Bool
    ) -> Bool {
        !isCancelled && activeGeneration == currentGeneration
    }

    init() {
        direction = TranslationDirection.load()
        protectsNonSourceText = TranslationTextProtection.load()
    }

    func setDirection(_ direction: TranslationDirection) {
        guard self.direction != direction else { return }
        self.direction = direction
        direction.save()
        sessionGeneration += 1
        sessionReady = false
        cache.removeAll()
        segmentCache.removeAll()
        failPending(TranslatorError.translationSessionUnavailable)
    }

    func setProtectsNonSourceText(_ enabled: Bool) {
        guard protectsNonSourceText != enabled else { return }
        protectsNonSourceText = enabled
        policyGeneration += 1
        cache.removeAll()
        segmentCache.removeAll()
        failPending(TranslatorError.translationSessionUnavailable)
    }

    func translate(_ source: String) async throws -> String {
        PerformanceProfiler.shared.increment("translation.requested")
        let key = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if let cached = cache[key] {
            PerformanceProfiler.shared.increment("translation.cacheHit")
            PerformanceProfiler.shared.increment("translation.completed")
            return cached
        }
        PerformanceProfiler.shared.increment("translation.cacheMiss")
        guard sessionReady else { throw TranslatorError.translationSessionUnavailable }
        let plan = LanguageProtector.makeTranslationPlan(
            for: key, direction: direction,
            protectNonSourceText: protectsNonSourceText
        )
        return try await withCheckedThrowingContinuation { continuation in
            if waiters[key] != nil {
                waiters[key, default: []].append(continuation)
                PerformanceProfiler.shared.increment("translation.inFlightHit")
                return
            }
            waiters[key] = [continuation]
            queue.append(Pending(
                plan: plan, enqueuedAt: DispatchTime.now().uptimeNanoseconds
            ))
        }
    }

    func run(session: TranslationSession) async {
        let activeGeneration = sessionGeneration
        do {
            try await session.prepareTranslation()
        } catch {
            failPending(error)
            return
        }
        guard activeGeneration == sessionGeneration else { return }
        sessionReady = true
        defer {
            if activeGeneration == sessionGeneration {
                sessionReady = false
                failPending(TranslatorError.translationSessionUnavailable)
            }
        }

        while !Task.isCancelled, activeGeneration == sessionGeneration {
            if queue.isEmpty {
                try? await Task.sleep(for: .milliseconds(12))
                continue
            }
            let batch = Array(queue.prefix(24))
            queue.removeFirst(batch.count)
            let activePolicyGeneration = policyGeneration
            do {
                for pending in batch {
                    PerformanceProfiler.shared.recordElapsed(
                        .translationQueue, startedAt: pending.enqueuedAt, itemCount: 1,
                        characterCount: pending.plan.translatableCharacterCount
                    )
                }

                var uncachedSegments: [String] = []
                var seenSegments = Set<String>()
                for pending in batch {
                    for segment in pending.plan.segments where segment.kind == .translate {
                        if segmentCache[segment.text] != nil {
                            PerformanceProfiler.shared.increment("translation.segmentCacheHit")
                        } else if seenSegments.insert(segment.text).inserted {
                            PerformanceProfiler.shared.increment("translation.segmentCacheMiss")
                            uncachedSegments.append(segment.text)
                        } else {
                            PerformanceProfiler.shared.increment("translation.segmentBatchDuplicate")
                        }
                    }
                }
                if !uncachedSegments.isEmpty {
                    // Translation's Request is immutable but not annotated Sendable in this SDK.
                    // The array is consumed by one awaited batch call and never mutated afterward.
                    nonisolated(unsafe) let requests = uncachedSegments.enumerated().map {
                        TranslationSession.Request(sourceText: $1, clientIdentifier: String($0))
                    }
                    let modelToken = PerformanceProfiler.shared.begin(
                        .translationModel, itemCount: requests.count,
                        characterCount: uncachedSegments.reduce(0) { $0 + $1.count }
                    )
                    PerformanceProfiler.shared.increment("translation.modelCall")
                    PerformanceProfiler.shared.increment(
                        "translation.modelBatchSegments", by: requests.count
                    )
                    let responses: [TranslationSession.Response]
                    do {
                        responses = try await session.translations(from: requests)
                        PerformanceProfiler.shared.end(modelToken)
                        guard Self.canCommitResults(
                            activeGeneration: activeGeneration,
                            currentGeneration: sessionGeneration,
                            isCancelled: Task.isCancelled
                        ) else { return }
                        guard activePolicyGeneration == policyGeneration else { continue }
                    } catch {
                        PerformanceProfiler.shared.end(modelToken)
                        guard Self.canCommitResults(
                            activeGeneration: activeGeneration,
                            currentGeneration: sessionGeneration,
                            isCancelled: Task.isCancelled
                        ) else { return }
                        if activePolicyGeneration != policyGeneration { continue }
                        throw error
                    }
                    for response in responses {
                        guard let identifier = response.clientIdentifier,
                              let index = Int(identifier), uncachedSegments.indices.contains(index) else { continue }
                        trimCacheIfNeeded(&segmentCache, maximumCount: 2_048, removalCount: 512)
                        segmentCache[uncachedSegments[index]] = response.targetText
                        PerformanceProfiler.shared.increment("translation.segmentTranslated")
                    }
                }

                guard activePolicyGeneration == policyGeneration else { continue }

                for pending in batch {
                    var output = ""
                    for segment in pending.plan.segments {
                        if segment.kind == .preserve {
                            output += segment.text
                        } else if let translated = segmentCache[segment.text] {
                            output += translated
                        } else {
                            throw TranslatorError.translationSessionUnavailable
                        }
                    }
                    trimCacheIfNeeded(&cache, maximumCount: 512, removalCount: 128)
                    cache[pending.plan.source] = output
                    finishWaiters(for: pending.plan.source, with: .success(output))
                }
            } catch {
                batch.forEach { finishWaiters(for: $0.plan.source, with: .failure(error)) }
            }
        }
    }

    private func failPending(_ error: Error) {
        queue.removeAll()
        let pendingWaiters = waiters
        waiters.removeAll()
        pendingWaiters.values.joined().forEach { $0.resume(throwing: error) }
    }

    private func finishWaiters(for source: String, with result: Result<String, Error>) {
        guard let continuations = waiters.removeValue(forKey: source) else { return }
        if case .success = result {
            PerformanceProfiler.shared.increment("translation.completed", by: continuations.count)
        }
        for continuation in continuations {
            switch result {
            case .success(let output): continuation.resume(returning: output)
            case .failure(let error): continuation.resume(throwing: error)
            }
        }
    }

    private func trimCacheIfNeeded(
        _ cache: inout [String: String], maximumCount: Int, removalCount: Int
    ) {
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
