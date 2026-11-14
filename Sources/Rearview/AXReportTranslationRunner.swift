import Foundation
@preconcurrency import Translation

/// Research adapter only. Translation policy, segmentation, assembly, caching and
/// engine strategy come from production code; no fixture-specific corrections.
@MainActor enum AXReportTranslationRunner {
    static func run() async -> Int32 {
        guard #available(macOS 26, *),
              let flag = CommandLine.arguments.firstIndex(of: "--translate-ax-report"),
              CommandLine.arguments.count > flag + 2 else { return 1 }
        do {
            let input = URL(fileURLWithPath: CommandLine.arguments[flag + 1])
            let output = URL(fileURLWithPath: CommandLine.arguments[flag + 2])
            let inputData = try Data(contentsOf:input)
            let typedSources = try? JSONDecoder().decode([AXTranslationRequest].self,from:inputData)
            let sources = typedSources == nil ? try JSONDecoder().decode([String].self,from:inputData) : []
            // Explicit reproducible production settings, not per-source detection.
            let direction = TranslationDirection.japaneseToKorean
            let protects = false
            let initializationStart = Date()
            let broker = TranslationBroker(direction: direction, protectsNonSourceText: protects)
            let availability: LanguageAvailability
            let session: TranslationSession
            if #available(macOS 26.4, *) {
                availability = LanguageAvailability(preferredStrategy: TranslationStrategyPolicy.preferred())
                session = TranslationSession(installedSource: direction.sourceLocale, target: direction.targetLocale,
                    preferredStrategy: TranslationStrategyPolicy.preferred())
            } else {
                availability = LanguageAvailability()
                session = TranslationSession(installedSource: direction.sourceLocale, target: direction.targetLocale)
            }
            guard await availability.status(from: direction.sourceLocale, to: direction.targetLocale) == .installed else {
                throw NSError(domain: "Translation model not installed", code: 1)
            }
            let worker = Task { @MainActor in await broker.run(session: session) }
            let watchdog = Task { @MainActor in
                try? await Task.sleep(for: .seconds(540))
                if !Task.isCancelled { session.cancel(); worker.cancel() }
            }
            defer { watchdog.cancel(); session.cancel(); worker.cancel() }
            let deadline = Date().addingTimeInterval(15)
            while !broker.isReadyForTranslation, Date() < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            guard broker.isReadyForTranslation else { throw NSError(domain: "Production broker not ready", code: 1) }
            if let typedSources {
                var entries: [AXParagraphTranslation] = []
                let repeats = CommandLine.arguments.firstIndex(of:"--ax-translation-repeats").flatMap {
                    $0+1 < CommandLine.arguments.count ? Int(CommandLine.arguments[$0+1]) : nil
                } ?? 1
                let initializationSeconds = Date().timeIntervalSince(initializationStart)
                let translator = AXParagraphTranslator(broker:broker,direction:direction)
                for _ in 0..<max(1,min(5,repeats)) {
                    for (index,var request) in typedSources.enumerated() {
                        if repeats > 1 { request.cacheScope = UUID().uuidString }
                        entries.append(try await translator.translate(request,node:index))
                        struct Export: Encodable { let entries: [AXParagraphTranslation]; let initializationSeconds: Double }
                        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
                        try encoder.encode(Export(entries:entries,initializationSeconds:initializationSeconds)).write(to:output,options:.atomic)
                    }
                }
                return entries.contains { $0.status == "failed" } ? 2 : 0
            }
            var entries: [[String: String]] = []
            for (index, source) in sources.enumerated() {
                let plan = LanguageProtector.makeTranslationPlan(for: source.trimmingCharacters(in: .whitespacesAndNewlines),
                    direction: direction, protectNonSourceText: protects)
                var entry = ["source": source, "sourceLanguage": "ja", "targetLanguage": "ko",
                    "provider": "production TranslationBroker / macOS Translation", "protectNonSourceText": "false"]
                // Match SessionCoordinator's eligibility filter BEFORE the broker.
                // Disabling protection affects text inside an eligible paragraph;
                // it does not make English-only paragraphs translation targets.
                let eligible = LanguageProtector.containsSourceLanguage(source, direction: direction)
                entry["sourceLanguageEligible"] = String(eligible)
                if !eligible {
                    entry["status"] = "skipped_non_source_language"
                    entry["reason"] = "LanguageProtector.containsSourceLanguage=false"
                } else {
                    do {
                        entry["translation"] = try await broker.translate(source)
                        // A real provider result can equal the input; do not hide that.
                        entry["status"] = plan.translatableCharacterCount == 0 ? "preserved_by_policy" : "translated"
                    } catch {
                        entry["status"] = "failed"; entry["error"] = String(describing: error)
                    }
                }
                entries.append(entry)
                try JSONSerialization.data(withJSONObject: ["entries": entries], options: [.prettyPrinted, .sortedKeys])
                    .write(to: output, options: .atomic)
                if (index + 1) % 20 == 0 { print("production translation \(index + 1)/\(sources.count)"); fflush(stdout) }
            }
            return entries.contains { $0["status"] == "failed" } ? 2 : 0
        } catch { fputs("\(error)\n", stderr); return 1 }
    }
}
