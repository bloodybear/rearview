import Foundation
@preconcurrency import Translation

/// Installed-model, public-corpus smoke test. No AX, screenshots, preference
/// writes, model downloads, source strings or output strings are persisted.
@MainActor
enum TranslationProviderSmokeRunner {
    static let corpus = ["これは翻訳のテストです。",
        "画面の上部、中部、下部で同じ順序と完全な文字列を取得してください。"]

    static func validOutputs(_ outputs: [String], sources: [String]) -> Bool {
        outputs.count == sources.count && Set(outputs).count == outputs.count
            && zip(outputs, sources).allSatisfy { output, source in
                !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && output != source
                    && output.unicodeScalars.contains { (0xAC00...0xD7A3).contains($0.value) }
            }
    }

    static func run() async -> Int32 {
        guard #available(macOS 26, *) else {
            return emit(status: "unavailable-installed-session-api", completed: 0, errorRejected: false)
        }
        let direction = TranslationDirection.japaneseToKorean
        let availability: LanguageAvailability
        let session: TranslationSession
        if #available(macOS 26.4, *) {
            availability = LanguageAvailability(preferredStrategy: TranslationStrategyPolicy.preferred())
        } else { availability = LanguageAvailability() }
        guard await availability.status(from: direction.sourceLocale, to: direction.targetLocale) == .installed else {
            return emit(status: "blocked-model-not-installed", completed: 0, errorRejected: false)
        }
        if #available(macOS 26.4, *) {
            session = TranslationSession(installedSource: direction.sourceLocale, target: direction.targetLocale,
                preferredStrategy: TranslationStrategyPolicy.preferred())
        } else {
            session = TranslationSession(installedSource: direction.sourceLocale, target: direction.targetLocale)
        }
        guard !session.canRequestDownloads else {
            return emit(status: "blocked-download-capable-session", completed: 0, errorRejected: false)
        }
        let broker = TranslationBroker(direction: direction, protectsNonSourceText: true)
        var errorRejected = false
        do { _ = try await broker.translate(corpus[0]) }
        catch TranslatorError.translationSessionUnavailable { errorRejected = true }
        catch { return emit(status: "failed-unprepared-error-classification", completed: 0, errorRejected: false) }
        guard errorRejected else {
            return emit(status: "failed-unprepared-session-accepted", completed: 0, errorRejected: false)
        }
        var finished = false
        var timedOut = false
        let worker = Task { @MainActor in
            await broker.run(session: session)
            finished = true
        }
        let timeout = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            timedOut = true
            session.cancel()
            worker.cancel()
        }
        defer { timeout.cancel(); session.cancel(); worker.cancel() }
        var submitted = 0
        do {
            while !broker.isReadyForTranslation, !finished, !timedOut {
                try await Task.sleep(for: .milliseconds(10))
            }
            guard broker.isReadyForTranslation, !timedOut else {
                return emit(status: timedOut ? "failed-timeout" : "failed-session-prepare",
                    completed: 0, errorRejected: errorRejected)
            }
            var outputs: [String] = []
            for source in corpus {
                submitted += 1
                outputs.append(try await broker.translate(source))
            }
            let valid = !timedOut && validOutputs(outputs, sources: corpus)
            return emit(status: valid ? "passed" : "failed-block-correspondence",
                completed: outputs.count, errorRejected: errorRejected, submitted: submitted)
        } catch {
            return emit(status: timedOut ? "failed-timeout" : "failed-provider-request",
                completed: 0, errorRejected: errorRejected, submitted: submitted)
        }
    }

    private static func emit(status: String, completed: Int, errorRejected: Bool, submitted: Int = 0) -> Int32 {
        let report: [String: Any] = ["schemaVersion": 1, "status": status,
            "provider": "production-TranslationBroker", "expectedBlockCount": corpus.count,
            "submittedBlockCount": submitted,
            "completedBlockCount": completed, "unpreparedSessionRejected": errorRejected,
            "stringsPersisted": false, "modelDownloadsRequested": false,
            "notVerified": ["Live AX-to-provider rendering", "First-paint latency distribution",
                            "Three complete visual suites", "Native engine fault injection"]]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
            print(String(decoding: data, as: UTF8.self))
        }
        return status == "passed" ? EXIT_SUCCESS : EXIT_FAILURE
    }
}
