import Foundation
@testable import Rearview
@preconcurrency import Translation

/// Standalone research adapter; production app sources are reused read-only.
/// Model calls/eligibility/strategy reuse production read-only. Typed AX math
/// orchestration is a stage-2 prototype, per AX_MATH_POLICY.md, not app behavior.
typealias ReportTranslationInput = AXTranslationRequest
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
            let translator = AXParagraphTranslator(broker:broker,direction:direction)
            var entries: [AXParagraphTranslation] = []
            for (index, input) in sources.enumerated() {
                entries.append(try await translator.translate(input,node:index))
                struct Export: Encodable { let entries: [AXParagraphTranslation] }
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
                try encoder.encode(Export(entries:entries)).write(to:output,options:.atomic)
            }
            return entries.contains { $0.status == "failed" } ? 2 : 0
        } catch { fputs("\(error)\n", stderr); return 1 }
    }
}
