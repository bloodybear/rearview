import Foundation
@testable import Rearview
@preconcurrency import Translation

/// Standalone research adapter; production app sources are reused read-only.
/// Model calls/eligibility/strategy reuse production read-only. Typed AX math
/// orchestration is a stage-2 prototype, per AX_MATH_POLICY.md, not app behavior.
struct ReportTranslationInput: Decodable {
    let source: String
    let protectNonSourceText: Bool
    let parts: [MathContentPart]?
}
@main struct AXReportTranslationMain {
    static func main() async { exit(await AXReportTranslationRunner.run()) }
}
@MainActor enum AXReportTranslationRunner {
    static func run() async -> Int32 {
        guard #available(macOS 26, *),
              let flag = CommandLine.arguments.firstIndex(of: "--translate-ax-report"),
              CommandLine.arguments.count > flag + 2 else { return 1 }
        do {
            let input = URL(fileURLWithPath: CommandLine.arguments[flag + 1])
            let output = URL(fileURLWithPath: CommandLine.arguments[flag + 2])
            let sources = try JSONDecoder().decode([ReportTranslationInput].self, from: Data(contentsOf: input))
            // Explicit reproducible production settings, not per-source detection.
            let direction = TranslationDirection.japaneseToKorean
            let protects = false
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
            var entries: [[String: Any]] = []
            for (index, input) in sources.enumerated() {
                let source = input.source
                let protects = input.protectNonSourceText
                // Existing broker policy is switched serially, after each request
                // completes. This resets its caches, preventing policy mixing.
                broker.setProtectsNonSourceText(protects)
                let plan = LanguageProtector.makeTranslationPlan(for: source.trimmingCharacters(in: .whitespacesAndNewlines),
                    direction: direction, protectNonSourceText: protects)
                var entry: [String: Any] = ["source": source, "sourceLanguage": "ja", "targetLanguage": "ko",
                    "provider": "production TranslationBroker / macOS Translation", "protectNonSourceText": String(protects)]
                if let parts = input.parts {
                    entry["parts"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(parts))
                    entry["mathPolicy"] = MathTranslationPolicy.version
                }
                // Match SessionCoordinator's eligibility filter BEFORE the broker.
                // Disabling protection affects text inside an eligible paragraph;
                // it does not make English-only paragraphs translation targets.
                let eligibilitySource = input.parts.map { $0.filter { $0.kind == .text }.map { $0.text ?? "" }.joined() } ?? source
                let eligible = LanguageProtector.containsSourceLanguage(eligibilitySource, direction: direction)
                entry["sourceLanguageEligible"] = String(eligible)
                if !eligible {
                    entry["status"] = "skipped_non_source_language"
                    entry["reason"] = "LanguageProtector.containsSourceLanguage=false"
                } else {
                    do {
                        if let parts = input.parts {
                            let result = try await MathTranslationPolicy.translate(parts,
                                eligible: { LanguageProtector.containsSourceLanguage($0, direction: direction) },
                                using: { try await broker.translate($0) })
                            let fields = try JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as! [String: Any]
                            entry.merge(fields) { _, new in new }
                        } else {
                            entry["translation"] = try await broker.translate(source)
                            // A real provider result can equal the input; do not hide that.
                            entry["status"] = plan.translatableCharacterCount == 0 ? "preserved_by_policy" : "translated"
                        }
                    } catch {
                        entry["status"] = "failed"; entry["error"] = String(describing: error)
                    }
                }
                entries.append(entry)
                try JSONSerialization.data(withJSONObject: ["entries": entries], options: [.prettyPrinted, .sortedKeys])
                    .write(to: output, options: .atomic)
                if (index + 1) % 20 == 0 { print("production translation \(index + 1)/\(sources.count)"); fflush(stdout) }
            }
            return entries.contains { $0["status"] as? String == "failed" } ? 2 : 0
        } catch { fputs("\(error)\n", stderr); return 1 }
    }
}
