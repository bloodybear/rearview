import Foundation
@testable import Rearview
@preconcurrency import Translation

// Candidate API experiment, not the product TranslationBroker path. Reuses its
// language eligibility/direction/strategy read-only, but calls TranslationSession
// directly because the current broker only accepts String. Never report these
// results as an implemented production feature or mix them into report caches.
struct MathAttributedInput: Decodable {
    struct Part: Decodable { let kind: String; let text: String? }
    let key: String
    let parts: [Part]
}
@main struct MathAttributedProbe {
    @MainActor static func main() async {
        guard #available(macOS 26.4, *) else { fputs("Requires macOS 26.4\n", stderr); exit(1) }
        do {
            let input = URL(fileURLWithPath: CommandLine.arguments[1])
            let output = URL(fileURLWithPath: CommandLine.arguments[2])
            let rows = try JSONDecoder().decode([MathAttributedInput].self, from: Data(contentsOf: input))
            let direction = TranslationDirection.japaneseToKorean
            let highFidelity = CommandLine.arguments.contains("--high-fidelity")
            let strategy = highFidelity ? TranslationSession.Strategy.highFidelity : TranslationStrategyPolicy.preferred()
            let session = TranslationSession(installedSource: direction.sourceLocale, target: direction.targetLocale, preferredStrategy: strategy)
            defer { session.cancel() }
            let availability = LanguageAvailability(preferredStrategy: strategy)
            guard await availability.status(from: direction.sourceLocale, to: direction.targetLocale) == .installed else {
                throw NSError(domain: "MathAttributedProbe: models not installed", code: 1)
            }
            try await session.prepareTranslation()
            var entries: [[String: Any]] = []
            for row in rows {
                var source = AttributedString()
                var expectedMath: [String] = []
                for part in row.parts {
                    var attributed = AttributedString(part.text ?? "")
                    if part.kind == "math" {
                        attributed.skipsTranslation = true
                        expectedMath.append(part.text ?? "")
                    }
                    source.append(attributed)
                }
                let plain = String(source.characters)
                var result: [String: Any] = ["key": row.key, "source": plain, "expectedMath": expectedMath,
                    "route": "direct TranslationSession attributed-string research; not current production broker",
                    "strategy": highFidelity ? "research-only highFidelity" : "same production lowLatency", "sourceLanguage": "ja", "targetLanguage": "ko"]
                result["sourceRuns"] = source.runs.map { run -> [String: Any] in
                    ["text": String(source[run.range].characters), "skipsTranslation": run.skipsTranslation as Any? ?? NSNull()]
                }
                guard LanguageProtector.containsSourceLanguage(plain, direction: direction) else {
                    result["status"] = "skipped_non_source_language"; entries.append(result); continue
                }
                do {
                    let start = Date()
                    let response: TranslationSession.Response
                    if CommandLine.arguments.contains("--batch") {
                        let responses = try await session.translations(from: [.init(sourceText: source, clientIdentifier: row.key)])
                        guard let first = responses.first else { throw NSError(domain: "Empty attributed batch", code: 1) }
                        response = first
                        result["call"] = "translations(from:) singleton batch"
                    } else {
                        response = try await session.translate(source)
                        result["call"] = "translate(AttributedString)"
                    }
                    result["seconds"] = Date().timeIntervalSince(start)
                    result["status"] = "translated"
                    result["translation"] = response.targetText
                    if let target = response.attributedTargetText {
                        let runs = target.runs.map { run -> [String: Any] in
                            ["text": String(target[run.range].characters), "skipsTranslation": run.skipsTranslation as Any? ?? NSNull(),
                             "attributes": String(describing: run.attributes)]
                        }
                        result["runs"] = runs
                        let kept = target.runs.filter { $0.skipsTranslation == true }.map { String(target[$0.range].characters) }
                        result["actualProtectedMath"] = kept
                        result["exactMathAndOrder"] = kept == expectedMath
                    } else { result["exactMathAndOrder"] = false; result["attributedTargetMissing"] = true }
                } catch { result["status"] = "failed"; result["error"] = String(describing: error) }
                entries.append(result)
                try JSONSerialization.data(withJSONObject: ["entries": entries], options: [.prettyPrinted, .sortedKeys]).write(to: output, options: .atomic)
                print("attributed math \(entries.count)/\(rows.count)"); fflush(stdout)
            }
        } catch { fputs("\(error)\n", stderr); exit(1) }
    }
}
