import Foundation

// Stage-2 shared policy: compiled into the report adapter and its tests, never
// the Rearview app. Migration contract: notion-fixtures/AX_MATH_POLICY.md.
package struct MathContentPart: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case text, math }
    let kind: Kind
    let text: String?
}

package enum MathTranslationPolicy {
    static let version = "math-placeholder-context-v1"
    static func nonrendering(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy {
            CharacterSet.whitespacesAndNewlines.contains($0) || $0.properties.isDefaultIgnorableCodePoint
        }
    }
    struct Plan {
        let parts: [MathContentPart]
        let prefix: String
        let source: String
        let mathCount: Int
        let gapParts: [Int?]
        var tokens: [String] { (0..<mathCount).map { "⟦\(prefix)_\($0)⟧" } }
    }
    struct Parsed {
        var translations: [Int: String] = [:]
        var status: String
        var valid: Bool { status == "valid" }
    }
    static func plan(_ parts: [MathContentPart]) -> Plan? {
        let normal = parts.filter { $0.kind == .text }.map { $0.text ?? "" }.joined()
        var prefix = "MATH"
        // Avoid treating a literal marker in the user's normal text as our own.
        while normal.contains(prefix) { prefix += "X" }
        var source = "", count = 0, gaps: [Int?] = [nil]
        for (id, part) in parts.enumerated() {
            if part.kind == .math {
                source += "⟦\(prefix)_\(count)⟧"; count += 1; gaps.append(nil)
            } else {
                guard gaps[gaps.count - 1] == nil, let text = part.text else { return nil }
                gaps[gaps.count - 1] = id; source += text
            }
        }
        guard count > 0 else { return nil }
        return Plan(parts: parts, prefix: prefix, source: source, mathCount: count, gapParts: gaps)
    }
    static func parse(_ target: String, plan: Plan) -> Parsed {
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

    struct SegmentResult: Codable, Sendable {
        let id: Int
        let source: String
        let status: String
        let translation: String?
        var error: String? = nil
    }
    struct Outcome: Codable, Sendable {
        let status: String
        let method: String
        let markerValidation: String
        let rawContextTranslation: String?
        let contextError: String?
        let segments: [SegmentResult]
        let translation: String
    }
    @MainActor static func translate(_ parts: [MathContentPart],
        eligible: (String) -> Bool, using translator: (String) async throws -> String) async throws -> Outcome {
        guard let plan = plan(parts) else { throw NSError(domain: "Invalid math content parts", code: 1) }
        var raw: String?, contextError: String?, parsed = Parsed(status: "context_translation_error")
        do { raw = try await translator(plan.source); parsed = parse(raw!, plan: plan) }
        catch { contextError = String(describing: error) }
        var segments: [SegmentResult] = []
        for (id, part) in parts.enumerated() where part.kind == .text {
            let text = part.text ?? ""
            if nonrendering(text) {
                segments.append(.init(id: id, source: text, status: "nonrendering_text", translation: nil))
            } else if parsed.valid {
                segments.append(.init(id: id, source: text, status: "translated", translation: parsed.translations[id]))
            } else if !eligible(text) {
                segments.append(.init(id: id, source: text, status: "skipped_non_source_language", translation: nil))
            } else {
                do { segments.append(.init(id: id, source: text, status: "translated", translation: try await translator(text))) }
                catch { segments.append(.init(id: id, source: text, status: "failed", translation: nil, error: String(describing: error))) }
            }
        }
        var assembled = "", math = 0
        for (id, part) in parts.enumerated() {
            if part.kind == .math { assembled += plan.tokens[math]; math += 1 }
            else { assembled += segments.first(where: { $0.id == id })?.translation ?? part.text ?? "" }
        }
        return Outcome(status: segments.contains(where: { $0.status == "failed" }) ? "failed" : "translated",
            method: parsed.valid ? "math-placeholder-context" : "math-independent-fallback", markerValidation: parsed.status,
            rawContextTranslation: raw, contextError: contextError, segments: segments, translation: assembled)
    }
}
