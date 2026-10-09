import Foundation
import Testing
@testable import Rearview

@MainActor
struct TranslationProviderSmokeTests {
    @Test func explicitSmokePolicyDoesNotPersistUserPreferences() {
        let beforeDirection = TranslationDirection.load()
        let beforeProtection = TranslationTextProtection.load()
        let broker = TranslationBroker(direction: .japaneseToKorean, protectsNonSourceText: true)
        #expect(broker.direction == .japaneseToKorean && broker.protectsNonSourceText)
        #expect(TranslationDirection.load() == beforeDirection)
        #expect(TranslationTextProtection.load() == beforeProtection)
        #expect(!broker.isReadyForTranslation)
    }
    @Test func unpreparedProductionProviderRejectsTheRequest() async {
        let broker = TranslationBroker(direction: .japaneseToKorean, protectsNonSourceText: true)
        do {
            _ = try await broker.translate(TranslationProviderSmokeRunner.corpus[0])
            Issue.record("Unprepared provider accepted a request")
        } catch TranslatorError.translationSessionUnavailable {} catch {
            Issue.record("Unexpected provider error classification")
        }
    }
    @Test func smokeRequiresEveryDistinctKoreanBlockResult() {
        let sources = TranslationProviderSmokeRunner.corpus
        #expect(TranslationProviderSmokeRunner.validOutputs(["번역 테스트입니다.", "모든 문장을 정확히 가져오세요."], sources: sources))
        #expect(!TranslationProviderSmokeRunner.validOutputs(["번역 테스트입니다."], sources: sources))
        #expect(!TranslationProviderSmokeRunner.validOutputs(["동일 결과", "동일 결과"], sources: sources))
        #expect(!TranslationProviderSmokeRunner.validOutputs(sources, sources: sources))
        #expect(!TranslationProviderSmokeRunner.validOutputs(["", "English"], sources: sources))
    }
}
