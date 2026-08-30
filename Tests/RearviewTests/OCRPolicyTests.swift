import Foundation
import Testing
@testable import Rearview

@Suite
struct OCRPolicyTests {
    @Test func recognitionPolicyClampsAndProtectsJapanese() {
        withTestDefaults { defaults in
            #expect(OCRRecognitionPolicy.load(from: defaults) == OCRRecognitionPolicy.defaultMinimumConfidence)
            #expect(OCRRecognitionPolicy.defaultMinimumConfidence == AppDefaults.ocrMinimumConfidence)
            #expect(OCRRecognitionPolicy.clamp(-0.1) == 0)
            #expect(OCRRecognitionPolicy.clamp(1.1) == 1)

            OCRRecognitionPolicy.save(0.62, to: defaults)
            #expect(OCRRecognitionPolicy.load(from: defaults) == 0.62)
            #expect(!OCRRecognitionPolicy.accepts(
                text: "English", confidence: 0.61, minimumConfidence: 0.62
            ))
            #expect(OCRRecognitionPolicy.accepts(
                text: "日本語", confidence: 0.01, minimumConfidence: 0.62
            ))
            #expect(OCRRecognitionPolicy.accepts(text: "한국어 日本語です", confidence: 0.01))
        }
    }

    @Test func ocrSettingsUseStableProfilesAndClampInput() {
        withTestDefaults { defaults in
            let realtime = OCRSettings.load(mode: .realtime, from: defaults)
            let refinement = OCRSettings.load(mode: .refinement, from: defaults)
            #expect(realtime == OCRSettings.defaultProfile(for: .realtime))
            #expect(refinement == OCRSettings.defaultProfile(for: .refinement))
            #expect(realtime.engine == AppDefaults.ocrEngine)
            #expect(refinement.engine == AppDefaults.ocrEngine)
            #expect(realtime.recognitionLevel == AppDefaults.ocrRecognitionLevel)
            #expect(refinement.recognitionLevel == AppDefaults.ocrRecognitionLevel)
            #expect(realtime.revision == AppDefaults.ocrRevision)
            #expect(refinement.revision == AppDefaults.ocrRevision)
            #expect(realtime.usesLanguageCorrection == AppDefaults.ocrUsesLanguageCorrection)
            #expect(refinement.usesLanguageCorrection == AppDefaults.ocrUsesLanguageCorrection)
            #expect(realtime.automaticallyDetectsLanguage == AppDefaults.ocrAutomaticallyDetectsLanguage)
            #expect(refinement.automaticallyDetectsLanguage == AppDefaults.ocrAutomaticallyDetectsLanguage)
            #expect(realtime.minimumTextHeight == AppDefaults.ocrMinimumTextHeight)
            #expect(refinement.minimumTextHeight == AppDefaults.ocrMinimumTextHeight)
            #expect(realtime.imageScale == AppDefaults.realtimeOCRImageScale)
            #expect(refinement.imageScale == AppDefaults.refinementOCRImageScale)
            #expect(OCRSettings(usesLanguageCorrection: false, imageScale: 0.5).imageScale == 1.0)
            #expect(OCRSettings(usesLanguageCorrection: false, imageScale: 3.5).imageScale == 3.0)

            let documentSettings = OCRSettings(engine: .document, usesLanguageCorrection: true)
            documentSettings.save(mode: .refinement, to: defaults)
            #expect(OCRSettings.load(mode: .refinement, from: defaults).engine == .text)

            let custom = OCRSettings(
                engine: .document,
                recognitionLevel: .accurate,
                minimumTextHeight: 0.025,
                revision: .revision3,
                usesLanguageCorrection: true,
                automaticallyDetectsLanguage: false,
                imageScale: 2.0
            )
            custom.save(mode: .refinement, to: defaults)
            let loaded = OCRSettings.load(mode: .refinement, from: defaults)
            #expect(loaded.engine == .text)
            #expect(loaded.recognitionLevel == .accurate)
            #expect(loaded.revision == .current)
            #expect(loaded.minimumTextHeight == custom.minimumTextHeight)
            #expect(loaded.usesLanguageCorrection == custom.usesLanguageCorrection)
            #expect(loaded.automaticallyDetectsLanguage == custom.automaticallyDetectsLanguage)
            #expect(loaded.imageScale == custom.imageScale)
        }
    }

    @Test func recognitionLanguageChoicesRoundTrip() {
        withTestDefaults { defaults in
            #expect(OCRRecognitionLanguageChoice.load(from: defaults) == AppDefaults.recognitionLanguageChoice)
            for choice in OCRRecognitionLanguageChoice.allCases {
                choice.save(to: defaults)
                #expect(OCRRecognitionLanguageChoice.load(from: defaults) == choice)
            }
            #expect(OCRRecognitionLanguageChoice.japaneseFirst.languages == ["ja-JP", "ko-KR", "en-US"])
            #expect(OCRRecognitionLanguageChoice.koreanFirst.languages == ["ko-KR", "ja-JP", "en-US"])
            #expect(OCRRecognitionLanguageChoice.unset.languages == nil)
        }
    }

    @Test func refinementPolicyRoundTripsAndBoundsValues() {
        withTestDefaults { defaults in
            let defaultPolicy = RefinementOCRPolicy.load(from: defaults)
            #expect(defaultPolicy == RefinementOCRPolicy())
            #expect(defaultPolicy.automaticStrategy == AppDefaults.automaticOCRStrategy)
            #expect(defaultPolicy.manualStrategy == AppDefaults.manualOCRStrategy)

            let disabled = RefinementOCRPolicy(
                manualStrategy: .realtimeImmediately,
                alwaysRun: true,
                confidenceThreshold: 0.6,
                delayMilliseconds: 750
            )
            disabled.save(to: defaults)
            #expect(RefinementOCRPolicy.load(from: defaults) == disabled)
            #expect(RefinementOCRPolicy(delayMilliseconds: 8_000).delayMilliseconds == 5_000)

            let automatic = RefinementOCRPolicy(
                automaticStrategy: .refinementImmediately,
                manualStrategy: .realtimeThenRefinement,
                alwaysRun: false,
                confidenceThreshold: 0.73,
                delayMilliseconds: 3_000
            )
            automatic.save(to: defaults)
            #expect(RefinementOCRPolicy.load(from: defaults) == automatic)
        }
    }

    @Test func refinementDecisionSeparatesFallbackAndConfidenceCases() {
        let policy = RefinementOCRPolicy()
        #expect(decideRefinementOCR(observationCount: 0, japaneseLines: [], policy: policy) == .fullFrameFallback)
        #expect(decideRefinementOCR(observationCount: 2, japaneseLines: [], policy: policy) == .fullFrameFallback)
        #expect(decideRefinementOCR(
            observationCount: 1,
            japaneseLines: [testLine("設定", confidence: 0.95)],
            policy: policy
        ) == .skipHighConfidence)
        #expect(decideRefinementOCR(
            observationCount: 1,
            japaneseLines: [testLine("設定", confidence: 0.60)],
            policy: policy
        ) == .lowConfidenceROI)
    }

    @Test func lowConfidenceJapaneseEvidenceIsPreserved() {
        #expect(LanguageProtector.analyzeJapanese(in: "設", visionLanguages: nil).containsJapanese)
        #expect(LanguageProtector.analyzeJapanese(
            in: "設", visionLanguages: [Locale.Language(identifier: "ko")]
        ).containsJapanese)
        #expect(!OCRRecognitionPolicy.accepts(
            text: "낮은 신뢰도", confidence: 0.34, minimumConfidence: 0.62
        ))
        #expect(OCRRecognitionPolicy.accepts(
            text: "低い信頼度", confidence: 0.01, minimumConfidence: 0.62
        ))
    }

    @Test func translationStrategyUsesLowLatencyWhenAvailable() {
        if #available(macOS 26.4, *) {
            #expect(TranslationStrategyPolicy.preferred() == .lowLatency)
        }
    }
}
