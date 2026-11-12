import Foundation
import NotionAXCore

struct AXTranslationRequest: Codable, Sendable {
    let source: String
    let protectNonSourceText: Bool
    let parts: [MathContentPart]?

    init(paragraph: AXParagraph) {
        source = paragraph.text
        protectNonSourceText = paragraph.isCodeBlock
        parts = paragraph.inlineContent.map { values in
            values.map { .init(kind: $0.kind == "math" ? .math : .text,
                               text: $0.kind == "math" ? nil : $0.text ?? "") }
        }
    }
}

struct AXParagraphTranslation: Codable, Sendable {
    let node: Int
    let source: String
    let sourceLanguage: String
    let targetLanguage: String
    let protectNonSourceText: Bool
    var provider = "production TranslationBroker / macOS Translation"
    let parts: [MathContentPart]?
    let mathPolicy: String?
    var sourceLanguageEligible: Bool
    var status: String
    var translation: String?
    var error: String?
    var method: String?
    var markerValidation: String?
    var rawContextTranslation: String?
    var contextError: String?
    var segments: [MathTranslationPolicy.SegmentResult]?

    static func timedOut(_ paragraph: AXParagraph, direction: TranslationDirection) -> Self {
        let request = AXTranslationRequest(paragraph:paragraph)
        let forward = direction == .japaneseToKorean
        return Self(node:paragraph.node,source:request.source,sourceLanguage:forward ? "ja" : "ko",
            targetLanguage:forward ? "ko" : "ja",protectNonSourceText:request.protectNonSourceText,
            parts:request.parts,mathPolicy:request.parts == nil ? nil : MathTranslationPolicy.version,
            sourceLanguageEligible:LanguageProtector.containsSourceLanguage(
                request.parts.map { $0.filter { $0.kind == .text }.map { $0.text ?? "" }.joined() } ?? request.source,
                direction:direction),status:"failed",error:"translation_timeout")
    }
}

@MainActor
struct AXParagraphTranslator {
    let broker: any SessionTranslationProvider
    let direction: TranslationDirection

    func translate(_ request: AXTranslationRequest, node: Int) async throws -> AXParagraphTranslation {
        try Task.checkCancellation()
        let normal = request.parts.map { $0.filter { $0.kind == .text }.map { $0.text ?? "" }.joined() } ?? request.source
        let eligible = LanguageProtector.containsSourceLanguage(normal, direction: direction)
        let forward = direction == .japaneseToKorean
        var result = AXParagraphTranslation(node: node, source: request.source,
            sourceLanguage: forward ? "ja" : "ko", targetLanguage: forward ? "ko" : "ja",
            protectNonSourceText: request.protectNonSourceText, parts: request.parts,
            mathPolicy: request.parts == nil ? nil : MathTranslationPolicy.version,
            sourceLanguageEligible: eligible, status: eligible ? "pending" : "skipped_non_source_language")
        guard eligible else { return result }
        do {
            if let parts = request.parts {
                // Exact typed content + policy scope both complete and segment caches.
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                let identity = try encoder.encode(request).base64EncodedString()
                var contextRequest = true
                let outcome = try await MathTranslationPolicy.translate(parts,
                    eligible: { LanguageProtector.containsSourceLanguage($0, direction: direction) },
                    using: { source in
                        let context = contextRequest ? "context" : "fallback"
                        contextRequest = false
                        return try await broker.translate(source, options: .init(
                            protectsNonSourceText: request.protectNonSourceText,
                            context: "ax-\(MathTranslationPolicy.version)-\(context)-\(identity)"))
                    })
                result.status = outcome.status; result.translation = outcome.translation
                result.method = outcome.method; result.markerValidation = outcome.markerValidation
                result.rawContextTranslation = outcome.rawContextTranslation; result.contextError = outcome.contextError
                result.segments = outcome.segments
            } else {
                result.translation = try await broker.translate(request.source, options: .init(
                    protectsNonSourceText: request.protectNonSourceText, context: "ax-paragraph-v1"))
                let plan = LanguageProtector.makeTranslationPlan(for: request.source, direction: direction,
                    protectNonSourceText: request.protectNonSourceText)
                result.status = plan.translatableCharacterCount == 0 ? "preserved_by_policy" : "translated"
            }
            try Task.checkCancellation()
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            result.status = "failed"; result.error = String(describing: error)
        }
        return result
    }
}
