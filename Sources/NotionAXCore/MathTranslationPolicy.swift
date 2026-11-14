import Foundation

// Shared AX math translation policy for the app, report adapter and tests. Migration contract: notion-fixtures/AX_MATH_POLICY.md.
package struct MathContentPart: Codable, Equatable, Sendable {
    package enum Kind: String, Codable, Sendable { case text, math, hardBreak }
    package let kind: Kind
    package let text: String?
    package init(kind: Kind, text: String?) { self.kind = kind; self.text = text }
}

package enum MathTranslationPolicy {
    package static let version = "math-placeholder-context-v2"
    package static func nonrendering(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy {
            CharacterSet.whitespacesAndNewlines.contains($0) || $0.properties.isDefaultIgnorableCodePoint
        }
    }
    package struct Plan {
        let parts: [MathContentPart]
        let prefix: String
        let source: String
        let mathCount: Int
        let gapParts: [Int?]
        package var tokens: [String] { (0..<mathCount).map { "⟦\(prefix)_\($0)⟧" } }
    }
    package struct Parsed {
        var translations: [Int: String] = [:]
        var status: String
        var valid: Bool { status == "valid" }
    }
    package static func plan(_ parts: [MathContentPart]) -> Plan? {
        let normal = parts.filter { $0.kind == .text }.map { $0.text ?? "" }.joined()
        var prefix = parts.contains(where: { $0.kind == .hardBreak }) ? "AXBOUNDARY" : "MATH"
        // Avoid treating a literal marker in the user's normal text as our own.
        while normal.contains(prefix) { prefix += "X" }
        var source = "", count = 0, gaps: [Int?] = [nil]
        for (id, part) in parts.enumerated() {
            if part.kind != .text {
                source += "⟦\(prefix)_\(count)⟧"; count += 1; gaps.append(nil)
            } else {
                guard gaps[gaps.count - 1] == nil, let text = part.text else { return nil }
                gaps[gaps.count - 1] = id; source += text
            }
        }
        guard count > 0 else { return nil }
        return Plan(parts: parts, prefix: prefix, source: source, mathCount: count, gapParts: gaps)
    }
    package static func parse(_ target: String, plan: Plan) -> Parsed {
        // Only whitespace immediately inside the delimiters is insignificant.
        // Never repair a changed name/ID, merge tokens or reorder target chunks.
        let pattern = "⟦\\s*" + NSRegularExpression.escapedPattern(for: plan.prefix) + "_([0-9]+)\\s*⟧"
        let regex = try! NSRegularExpression(pattern: pattern)
        let ns = target as NSString
        let matches = regex.matches(in: target, range: NSRange(location: 0, length: ns.length))
        let ids = matches.map { ns.substring(with: $0.range(at: 1)) }
        guard ids == (0..<plan.mathCount).map(String.init) else { return Parsed(status: "marker_identity_count_or_order") }
        var chunks: [String] = [], start = 0
        for match in matches {
            chunks.append(ns.substring(with: NSRange(location: start, length: match.range.location - start)))
            start = NSMaxRange(match.range)
        }
        chunks.append(ns.substring(from: start))
        // Reject residual malformed/extra markers, even if every expected ID
        // also happened to appear. Do not silently discard generated prose.
        guard !chunks.contains(where: { $0.contains(plan.prefix) }) else { return Parsed(status: "residual_marker") }
        var result = Parsed(status: "valid")
        for (gap, chunk) in zip(plan.gapParts, chunks) {
            guard let id = gap, !nonrendering(plan.parts[id].text ?? "") else {
                if !nonrendering(chunk) { return Parsed(status: "text_without_source_segment") }
                if let id = gap { result.translations[id] = chunk }
                continue
            }
            guard !nonrendering(chunk) else { return Parsed(status: "empty_text_segment") }
            result.translations[id] = chunk
        }
        return result
    }

    package struct SegmentResult: Codable, Sendable {
        package let id: Int
        package let source: String
        package let status: String
        package let translation: String?
        package var error: String? = nil
        package init(id: Int, source: String, status: String, translation: String?, error: String? = nil) {
            self.id = id; self.source = source; self.status = status; self.translation = translation; self.error = error
        }
    }
    package struct Outcome: Codable, Sendable {
        package let status: String
        package let method: String
        package let markerValidation: String
        package let rawContextTranslation: String?
        package let contextError: String?
        package let segments: [SegmentResult]
        package let translation: String
    }
    @MainActor package static func translate(_ parts: [MathContentPart],
        eligible: (String) -> Bool, forceIndependent: Bool = false, using translator: @escaping @MainActor @Sendable (String) async throws -> String) async throws -> Outcome {
        try Task.checkCancellation()
        guard let plan = plan(parts) else { throw NSError(domain: "Invalid math content parts", code: 1) }
        var raw: String?, contextError: String?, parsed = Parsed(status: "context_translation_error")
        do { if !forceIndependent { raw = try await translator(plan.source); parsed = parse(raw!, plan: plan) }
              else { parsed = Parsed(status: "forced_independent") } }
        catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            contextError = String(describing: error)
        }
        try Task.checkCancellation()
        var segments: [SegmentResult] = []
        var pending: [(Int,String)] = []
        for (id, part) in parts.enumerated() where part.kind == .text {
            try Task.checkCancellation()
            let text = part.text ?? ""
            if nonrendering(text) {
                segments.append(.init(id:id,source:text,status:"nonrendering_text",translation:nil))
            } else if parsed.valid {
                segments.append(.init(id:id,source:text,status:"translated",translation:parsed.translations[id]))
            } else if !eligible(text) {
                segments.append(.init(id:id,source:text,status:"skipped_non_source_language",translation:nil))
            } else { pending.append((id,text)) }
        }
        // Submit independently before awaiting results so the broker can batch them.
        // Structured children propagate cancellation and never outlive this request.
        try await withThrowingTaskGroup(of: SegmentResult.self) { group in
            for (id,text) in pending {
                group.addTask {
                    try Task.checkCancellation()
                    do { return .init(id:id,source:text,status:"translated",translation:try await translator(text)) }
                    catch {
                        if error is CancellationError || Task.isCancelled { throw CancellationError() }
                        return .init(id:id,source:text,status:"failed",translation:nil,error:String(describing:error))
                    }
                }
            }
            for try await segment in group { segments.append(segment) }
        }
        segments.sort { $0.id < $1.id }
        var assembled = "", math = 0
        for (id, part) in parts.enumerated() {
            if part.kind != .text { assembled += part.kind == .hardBreak ? (part.text ?? "\n") : plan.tokens[math]; math += 1 }
            else { assembled += segments.first(where: { $0.id == id })?.translation ?? part.text ?? "" }
        }
        return Outcome(status: segments.contains(where: { $0.status == "failed" }) ? "failed" : "translated",
            method: parsed.valid ? "math-placeholder-context" : forceIndependent ? "math-independent" : "math-independent-fallback", markerValidation: parsed.status,
            rawContextTranslation: raw, contextError: contextError, segments: segments, translation: assembled)
    }
}
