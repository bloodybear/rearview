import Foundation
import NaturalLanguage

enum JapaneseDetectionReason: String, Codable, Sendable, Equatable {
    case kanaDetected
    case visionJapaneseLanguage
    case visionNonJapaneseLanguage
    case hanDetectedWithoutVisionLanguage
    case noJapaneseScript
    case hanJapaneseProbabilityTooLow
}

struct ScriptCounts: Codable, Sendable, Equatable {
    let kana: Int
    let han: Int
    let hangul: Int
    let latin: Int
}

struct JapaneseDetection: Codable, Sendable, Equatable {
    let containsJapanese: Bool
    let reason: JapaneseDetectionReason
    let counts: ScriptCounts
    let japaneseProbability: Double?
}

enum TextSegmentKind: String, Sendable, Equatable {
    case translate
    case preserve
}

struct TextSegment: Sendable, Equatable {
    let kind: TextSegmentKind
    let text: String
}

struct TranslationPlan: Sendable, Equatable {
    let source: String
    let segments: [TextSegment]

    var translatableCharacterCount: Int {
        segments.filter { $0.kind == .translate }.reduce(0) { $0 + $1.text.count }
    }
}

enum LanguageProtector {
    static func containsSourceLanguage(
        _ text: String, direction: TranslationDirection,
        visionLanguages: [Locale.Language]? = nil
    ) -> Bool {
        switch direction {
        case .japaneseToKorean:
            return containsJapanese(text, visionLanguages: visionLanguages)
        case .koreanToJapanese:
            let scalars = text.unicodeScalars
            let hangul = scalars.filter(isHangul).count
            if visionLanguages?.contains(where: { $0.languageCode?.identifier == "ko" }) == true {
                return true
            }
            return hangul > 0
        }
    }

    static func makeTranslationPlan(
        for source: String, direction: TranslationDirection,
        protectNonSourceText: Bool = true
    ) -> TranslationPlan {
        guard protectNonSourceText else {
            return source.isEmpty
                ? TranslationPlan(source: source, segments: [])
                : TranslationPlan(
                    source: source,
                    segments: [TextSegment(kind: .translate, text: source)]
                )
        }
        guard direction == .koreanToJapanese else { return makeTranslationPlan(for: source) }
        var raw: [(kind: TextSegmentKind, text: String)] = []
        var buffer = ""
        var currentKind: TextSegmentKind?

        func flush() {
            guard let currentKind, !buffer.isEmpty else { return }
            raw.append((currentKind, buffer)); buffer = ""
        }
        for scalar in source.unicodeScalars {
            let kind: TextSegmentKind = isHangul(scalar) ? .translate : .preserve
            if let currentKind, currentKind != kind { flush() }
            currentKind = kind
            buffer.unicodeScalars.append(scalar)
        }
        flush()
        return TranslationPlan(
            source: source,
            segments: raw.map { TextSegment(kind: $0.kind, text: $0.text) }
        )
    }

    static func containsJapanese(_ text: String, visionLanguages: [Locale.Language]? = nil) -> Bool {
        analyzeJapanese(in: text, visionLanguages: visionLanguages).containsJapanese
    }

    static func analyzeJapanese(
        in text: String, visionLanguages: [Locale.Language]? = nil
    ) -> JapaneseDetection {
        let scalars = text.unicodeScalars
        let counts = ScriptCounts(
            kana: scalars.filter(isKana).count,
            han: scalars.filter(isHan).count,
            hangul: scalars.filter(isHangul).count,
            latin: scalars.filter(isLatin).count
        )
        if let visionLanguages,
           visionLanguages.contains(where: { $0.languageCode?.identifier == "ja" }) {
            return JapaneseDetection(
                containsJapanese: true,
                reason: .visionJapaneseLanguage,
                counts: counts, japaneseProbability: nil
            )
        }
        if counts.kana > 0 {
            return JapaneseDetection(
                containsJapanese: true, reason: .kanaDetected,
                counts: counts, japaneseProbability: nil
            )
        }
        guard counts.han > 0 else {
            if let visionLanguages, !visionLanguages.isEmpty {
                return JapaneseDetection(
                    containsJapanese: false, reason: .visionNonJapaneseLanguage,
                    counts: counts, japaneseProbability: nil
                )
            }
            return JapaneseDetection(
                containsJapanese: false, reason: .noJapaneseScript,
                counts: counts, japaneseProbability: nil
            )
        }
        return JapaneseDetection(
            containsJapanese: true,
            reason: .hanDetectedWithoutVisionLanguage,
            counts: counts, japaneseProbability: nil
        )
    }

    /// English, Hangul, and digits never enter the translation model. Punctuation and
    /// whitespace stay attached to the neighboring Japanese text for natural output.
    static func makeTranslationPlan(for source: String) -> TranslationPlan {
        var raw: [(kind: TextSegmentKind, text: String)] = []
        var buffer = ""
        var currentKind: TextSegmentKind?

        func flush() {
            guard let currentKind, !buffer.isEmpty else { return }
            raw.append((currentKind, buffer))
            buffer = ""
        }

        for scalar in source.unicodeScalars {
            let kind: TextSegmentKind
            if isLatin(scalar) || isHangul(scalar) || CharacterSet.decimalDigits.contains(scalar) {
                kind = .preserve
            } else {
                kind = .translate
            }
            if let currentKind, currentKind != kind { flush() }
            currentKind = kind
            buffer.unicodeScalars.append(scalar)
        }
        flush()

        // A punctuation-only translate segment contains no Japanese meaning. Merge it
        // into an adjacent preserved segment instead of sending it to the model.
        var segments: [TextSegment] = []
        for (index, item) in raw.enumerated() {
            let hasJapanese = item.text.unicodeScalars.contains { isKana($0) || isHan($0) }
            if item.kind == .translate, !hasJapanese {
                if !segments.isEmpty {
                    let last = segments.removeLast()
                    segments.append(TextSegment(kind: last.kind, text: last.text + item.text))
                } else if index + 1 < raw.count {
                    raw[index + 1].text = item.text + raw[index + 1].text
                } else {
                    segments.append(TextSegment(kind: .preserve, text: item.text))
                }
            } else {
                segments.append(TextSegment(kind: item.kind, text: item.text))
            }
        }
        return TranslationPlan(source: source, segments: segments)
    }

    private static func isKana(_ scalar: UnicodeScalar) -> Bool {
        (0x3040...0x30FF).contains(scalar.value) || (0x31F0...0x31FF).contains(scalar.value)
    }

    private static func isHan(_ scalar: UnicodeScalar) -> Bool {
        (0x3400...0x9FFF).contains(scalar.value) || (0xF900...0xFAFF).contains(scalar.value)
    }

    static func isHangul(_ scalar: UnicodeScalar) -> Bool {
        (0x1100...0x11FF).contains(scalar.value) || (0x3130...0x318F).contains(scalar.value)
            || (0xAC00...0xD7AF).contains(scalar.value)
    }

    private static func isLatin(_ scalar: UnicodeScalar) -> Bool {
        (0x0041...0x005A).contains(scalar.value) || (0x0061...0x007A).contains(scalar.value)
            || (0x00C0...0x024F).contains(scalar.value)
    }
}
