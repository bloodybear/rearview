import Foundation
import NotionAXCore

struct AXTranslationRequest: Codable, Sendable {
    let source: String
    let protectNonSourceText: Bool
    let parts: [MathContentPart]?
    var cacheScope: String? = nil
    var codeSegments: [AXCodeSegment]? = nil

    init(paragraph: AXParagraph) {
        source = paragraph.translationSourceText ?? ""
        protectNonSourceText = paragraph.isCodeBlock
        codeSegments = paragraph.codeSegments
        parts = paragraph.inlineContent.map { values in
            values.map { .init(kind: $0.kind == "math" ? .math : .text,
                               text: $0.kind == "math" ? nil : $0.text ?? "") }
        }
    }
}


struct AXCodeTranslation: Codable, Sendable {
    let id, rangeStart, rangeLength: Int
    let source: String
    var status: String
    var translation, rawTranslation, error: String?
}

struct AXLogicalTranslation: Codable, Sendable {
    let id: Int
    let sourcePart: Int?
    let logicalIndex: Int
    let rangeStart: Int
    let rangeLength: Int
    let source: String
    let delimiter: String
    var status: String
    var translation: String?
    var error: String?
    var rawTranslation: String?
    var generatedBreaksFlattened: Bool = false
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
    var codeTranslations: [AXCodeTranslation]?
    var logicalSegments: [AXLogicalTranslation]?
    var newlinePolicy: String?
    var elapsedSeconds: Double?

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
    let newlineContext: Bool
    init(broker: any SessionTranslationProvider, direction: TranslationDirection,
         newlineContext: Bool = !CommandLine.arguments.contains("--ax-newline-independent")) {
        self.broker = broker; self.direction = direction; self.newlineContext = newlineContext
    }

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
        guard !request.source.isEmpty else { result.status = "source_unavailable"; return result }
        if request.protectNonSourceText, request.parts == nil, forward {
            return try await translateCode(request,result:result)
        }
        guard eligible else { return result }
        let started = Date()
        do {
            if normal.rangeOfCharacter(from:.newlines) != nil {
                var expanded: [MathContentPart] = []
                var logical: [AXLogicalTranslation] = []
                let original = request.parts ?? [.init(kind:.text,text:request.source)]
                for (partID,part) in original.enumerated() {
                    if part.kind == .math { expanded.append(part); continue }
                    let source = part.text ?? ""
                    for (index,piece) in AXLogicalLines.pieces(source).enumerated() {
                        let text = (source as NSString).substring(with:piece.0)
                        logical.append(.init(id:expanded.count,sourcePart:request.parts == nil ? nil : partID,
                            logicalIndex:index,rangeStart:piece.0.location,rangeLength:piece.0.length,
                            source:text,delimiter:piece.1,status:"pending"))
                        expanded.append(.init(kind:.text,text:text))
                        if !piece.1.isEmpty { expanded.append(.init(kind:.hardBreak,text:piece.1)) }
                    }
                }
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                let identity = try encoder.encode(request).base64EncodedString()
                let outcome = try await MathTranslationPolicy.translate(expanded,
                    eligible:{ LanguageProtector.containsSourceLanguage($0,direction:direction) },
                    forceIndependent:request.protectNonSourceText || !newlineContext,
                    using:{ source in try await broker.translate(source,options:.init(
                        protectsNonSourceText:request.protectNonSourceText,
                        context:"ax-hardbreak-code-syntax-v2-\(identity)",
                        preservesCodeSyntax:request.protectNonSourceText)) })
                for i in logical.indices {
                    if let segment = outcome.segments.first(where: { $0.id == logical[i].id }) {
                        logical[i].status = segment.status; logical[i].error = segment.error
                        logical[i].rawTranslation = segment.translation
                        logical[i].translation = segment.translation.map(AXLogicalLines.flattenGeneratedBreaks)
                        logical[i].generatedBreaksFlattened = segment.translation != logical[i].translation
                    }
                }
                result.logicalSegments = logical
                result.newlinePolicy = "hardbreak-context-v1"
                result.status = outcome.status; result.method = outcome.method.replacingOccurrences(of:"math-",with:"boundary-")
                result.markerValidation = outcome.markerValidation; result.rawContextTranslation = outcome.rawContextTranslation
                result.contextError = outcome.contextError
                // Reassemble each original text part; math remains untouched.
                result.segments = original.enumerated().compactMap { id,part -> MathTranslationPolicy.SegmentResult? in
                    guard part.kind == .text else { return nil }
                    let values = logical.filter { $0.sourcePart == (request.parts == nil ? nil : id) }
                    let text = values.map { ($0.translation ?? $0.source)+$0.delimiter }.joined()
                    return MathTranslationPolicy.SegmentResult(id:id,source:part.text ?? "",status:values.contains(where: { $0.status == "failed" }) ? "failed" : "translated",translation:text)
                }
                let boundaryPlan = MathTranslationPolicy.plan(expanded)!
                var boundary = 0
                result.translation = expanded.enumerated().map { id,part in
                    if part.kind == .text { return logical.first(where: { $0.id == id }).map { $0.translation ?? $0.source } ?? "" }
                    defer { boundary += 1 }
                    return part.kind == .hardBreak ? (part.text ?? "") : boundaryPlan.tokens[boundary]
                }.joined()
            } else if let parts = request.parts {
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
                            context: "ax-code-syntax-v1-\(MathTranslationPolicy.version)-\(context)-\(identity)",
                            preservesCodeSyntax:request.protectNonSourceText))
                    })
                result.status = outcome.status; result.translation = outcome.translation
                result.method = outcome.method; result.markerValidation = outcome.markerValidation
                result.rawContextTranslation = outcome.rawContextTranslation; result.contextError = outcome.contextError
                result.segments = outcome.segments
            } else {
                result.translation = try await broker.translate(request.source, options: .init(
                    protectsNonSourceText: request.protectNonSourceText, context: "ax-paragraph-code-syntax-v3",
                    preservesCodeSyntax:request.protectNonSourceText))
                let plan = LanguageProtector.makeTranslationPlan(for: request.source, direction: direction,
                    protectNonSourceText: request.protectNonSourceText, preserveCodeSyntax:request.protectNonSourceText)
                result.status = plan.translatableCharacterCount == 0 ? "preserved_by_policy" : "translated"
            }
            try Task.checkCancellation()
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            result.status = "failed"; result.error = String(describing: error)
        }
        result.elapsedSeconds = Date().timeIntervalSince(started)
        return result
    }
    private func translateCode(_ request: AXTranslationRequest, result initial: AXParagraphTranslation) async throws -> AXParagraphTranslation {
        let started = Date()
        let parts = AXCodeTextSegments.split(request.source)
        var output = parts.enumerated().map { index,part in
            AXCodeTranslation(id:index,rangeStart:part.range.location,rangeLength:part.range.length,
                source:part.text,status:part.translates ? "pending" : "preserved_source")
        }
        // Snapshot geometry is optional only for translation-only research requests.
        let geometry = request.codeSegments
        let scope = request.cacheScope ?? "production"
        let translate: @MainActor @Sendable (String) async throws -> String = { [broker] source in
            try await broker.translate(source, options:.init(protectsNonSourceText:false,
                context:"ax-code-runs-v1-"+scope))
        }
        try await withThrowingTaskGroup(of: AXCodeTranslation.self) { group in
            for (index,part) in parts.enumerated() where part.translates {
                guard geometry == nil || geometry?.contains(where: {
                    $0.id == index && $0.rangeStart == part.range.location && $0.rangeLength == part.range.length
                    && $0.text == part.text && $0.status == "complete"
                }) == true else { output[index].status = "geometry_unavailable"; continue }
                group.addTask {
                    var value = AXCodeTranslation(id:index,rangeStart:part.range.location,rangeLength:part.range.length,
                        source:part.text,status:"translated")
                    do {
                        try Task.checkCancellation()
                        let raw = try await translate(part.text)
                        try Task.checkCancellation()
                        guard !raw.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else {
                            value.status="failed";value.error="empty_translation";return value
                        }
                        value.rawTranslation=raw;value.translation=AXLogicalLines.flattenGeneratedBreaks(raw)
                    } catch {
                        if error is CancellationError || Task.isCancelled { throw CancellationError() }
                        value.status="failed";value.error=String(describing:error)
                    }
                    return value
                }
            }
            for try await value in group { output[value.id]=value }
        }
        var result = initial
        result.codeTranslations=output;result.method="code-source-runs-v1"
        result.translation=output.map { $0.translation ?? $0.source }.joined()
        result.status=output.contains(where: {$0.status == "failed" || $0.status == "geometry_unavailable"}) ? "partial" :
            (output.contains(where: {$0.status == "translated"}) ? "translated" : "skipped_non_source_language")
        result.elapsedSeconds=Date().timeIntervalSince(started)
        return result
    }

}
