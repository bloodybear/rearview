import Foundation
import Testing
@testable import Rearview

@Suite(.serialized)
struct LanguageProtectorTests {
    @Test func detectsJapaneseAndRejectsKoreanEnglish() {
        #expect(LanguageProtector.containsJapanese("設定を保存します"))
        #expect(LanguageProtector.containsJapanese("ゲーム開始"))
        #expect(LanguageProtector.containsJapanese(
            "設定", visionLanguages: [Locale.Language(identifier: "ko")]
        ))
        #expect(LanguageProtector.containsJapanese(
            "설정", visionLanguages: [Locale.Language(identifier: "ja")]
        ))
        #expect(!LanguageProtector.containsJapanese("설정을 저장합니다"))
        #expect(!LanguageProtector.containsJapanese("Save settings"))
    }

    @Test func reportsScriptCountsAndDetectionReasons() {
        let japanese = LanguageProtector.analyzeJapanese(in: "設定をSave합니다")
        #expect(japanese.containsJapanese)
        #expect(japanese.reason == .kanaDetected)
        #expect(japanese.counts.kana == 1)
        #expect(japanese.counts.han == 2)
        #expect(japanese.counts.latin == 4)
        #expect(japanese.counts.hangul == 3)

        let english = LanguageProtector.analyzeJapanese(in: "Save settings")
        #expect(!english.containsJapanese)
        #expect(english.reason == .noJapaneseScript)
    }

    @Test func buildsMixedLanguageTranslationPlanWithoutProtectionTokens() {
        let source = "Start ボタン을 2回押す"
        let plan = LanguageProtector.makeTranslationPlan(for: source)
        #expect(plan.segments.map(\.text).joined() == source)
        let translatedInput = plan.segments.filter { $0.kind == .translate }.map(\.text).joined()
        #expect(!translatedInput.contains("Start"))
        #expect(!translatedInput.contains("을"))
        #expect(!translatedInput.contains("2"))
    }

    @Test func unprotectedMixedLanguageTranslationPlanUsesOneRequest() {
        let source = "Start ボタン을 2回押す"
        let plan = LanguageProtector.makeTranslationPlan(
            for: source, direction: .japaneseToKorean, protectNonSourceText: false
        )
        #expect(plan.segments == [TextSegment(kind: .translate, text: source)])
        #expect(plan.translatableCharacterCount == source.count)
    }

    @Test func refinementOCRDecisionDistinguishesConfidenceStates() {
        let policy = RefinementOCRPolicy()
        #expect(decideRefinementOCR(observationCount: 0, japaneseLines: [], policy: policy) == .fullFrameFallback)
        #expect(decideRefinementOCR(observationCount: 3, japaneseLines: [], policy: policy) == .fullFrameFallback)
        #expect(decideRefinementOCR(observationCount: 1, japaneseLines: [line("設定", 0.95)], policy: policy) == .skipHighConfidence)
        #expect(decideRefinementOCR(observationCount: 1, japaneseLines: [line("設定", 0.60)], policy: policy) == .lowConfidenceROI)
    }

    @Test func ocrStringsAreRecordedOnlyForBenchmarkReports() throws {
        let profiler = PerformanceProfiler.shared
        let secret = "PRIVATE OCR STRING"
        let recognized = [line(secret, 0.9)]

        profiler.start(benchmark: false)
        profiler.recordOCRDiagnostics(
            recognized, frameID: 1, mode: .realtime,
            regionOfInterest: nil, purpose: .runtime
        )
        let ordinary = try #require(profiler.stop())
        #expect(ordinary.ocrDiagnostics.isEmpty)
        #expect(!String(decoding: try ProfileReportWriter.jsonData(ordinary), as: UTF8.self).contains(secret))

        profiler.start(benchmark: true)
        profiler.recordOCRDiagnostics(
            recognized, frameID: 2, mode: .refinement,
            regionOfInterest: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
            purpose: .initialComparison
        )
        let benchmark = try #require(profiler.stop())
        #expect(benchmark.ocrDiagnostics.first?.text == secret)
        #expect(benchmark.ocrDiagnostics.first?.scope == .roi)
    }

    private func line(_ text: String, _ confidence: Float) -> RecognizedLine {
        RecognizedLine(
            sourceText: text, normalizedRect: CGRect(x: 0, y: 0, width: 1, height: 1),
            confidence: confidence, background: .lightBackground, foreground: .darkText
        )
    }
}
