#if DEBUG
import XCTest
@testable import Rearview
@testable import NotionAXCore

@MainActor private final class AXTestTranslator: SessionTranslationProvider {
    var calls: [(String, TranslationRequestOptions)] = []
    var action: (String) throws -> String = { $0 }
    func setDirection(_ direction: TranslationDirection) {}
    func setProtectsNonSourceText(_ enabled: Bool) {}
    func translate(_ source: String) async throws -> String { try action(source) }
    func translate(_ source: String, options: TranslationRequestOptions) async throws -> String {
        calls.append((source, options)); return try action(source)
    }
}

@MainActor final class AXTranslationTests: XCTestCase {
    private func request(_ source: String, protect: Bool = false, parts: [MathContentPart]? = nil) throws -> AXTranslationRequest {
        var value: [String:Any] = ["source":source,"protectNonSourceText":protect]
        if let parts { value["parts"] = try JSONSerialization.jsonObject(with:JSONEncoder().encode(parts)) }
        return try JSONDecoder().decode(AXTranslationRequest.self,from:JSONSerialization.data(withJSONObject:value))
    }
    func testPlainPolicyEligibilityAndSeparateLocations() async throws {
        let broker = AXTestTranslator()
        let translator = AXParagraphTranslator(broker:broker,direction:.japaneseToKorean)
        let input = try request("日本語 English 👩‍💻")
        let first = try await translator.translate(input,node:10)
        let second = try await translator.translate(input,node:20)
        XCTAssertEqual(first.node,10); XCTAssertEqual(second.node,20)
        XCTAssertEqual(first.status,"translated")
        XCTAssertFalse(broker.calls[0].1.protectsNonSourceText)
        _ = try await translator.translate(request("日本語 code",protect:true),node:30)
        XCTAssertTrue(broker.calls.last!.1.protectsNonSourceText)
        let skipped = try await translator.translate(request("English only"),node:40)
        XCTAssertEqual(skipped.status,"skipped_non_source_language")
        XCTAssertEqual(broker.calls.count,3)
    }
    func testMathWhitespaceUsesContextAndNeverSendsFormula() async throws {
        let broker = AXTestTranslator()
        broker.action = { _ in "합계 ⟦ MATH_0 \n⟧ 입니다" }
        let parts: [MathContentPart] = [.init(kind:.text,text:"合計"),.init(kind:.math,text:nil),.init(kind:.text,text:"です")]
        let value = try await AXParagraphTranslator(broker:broker,direction:.japaneseToKorean)
            .translate(request("合計 SECRET_FORMULA です",parts:parts),node:9)
        XCTAssertEqual(value.method,"math-placeholder-context")
        XCTAssertEqual(value.markerValidation,"valid")
        XCTAssertEqual(value.segments?.map(\.id),[0,2])
        XCTAssertEqual(broker.calls.count,1)
        XCTAssertEqual(broker.calls[0].0,"合計⟦MATH_0⟧です")
    }
    func testMathOnlyJapaneseDoesNotTriggerTranslation() async throws {
        let broker = AXTestTranslator()
        let parts: [MathContentPart] = [.init(kind:.text,text:"English"),.init(kind:.math,text:nil)]
        let value = try await AXParagraphTranslator(broker:broker,direction:.japaneseToKorean)
            .translate(request("English 日本語の数式",parts:parts),node:1)
        XCTAssertEqual(value.status,"skipped_non_source_language"); XCTAssertTrue(broker.calls.isEmpty)
    }
    func testMathFallbackExcludesEnglishAndKeepsErrors() async throws {
        let broker = AXTestTranslator()
        broker.action = { source in
            if source.contains("⟦") { return "lost markers" }
            throw NSError(domain:"injected",code:1)
        }
        let parts: [MathContentPart] = [.init(kind:.text,text:"日本語"),.init(kind:.math,text:nil),.init(kind:.text,text:"English")]
        let value = try await AXParagraphTranslator(broker:broker,direction:.japaneseToKorean)
            .translate(request("日本語 FORMULA English",parts:parts),node:1)
        XCTAssertEqual(value.status,"failed"); XCTAssertEqual(value.method,"math-independent-fallback")
        XCTAssertEqual(value.rawContextTranslation,"lost markers")
        XCTAssertEqual(value.segments?.last?.status,"skipped_non_source_language")
        XCTAssertEqual(broker.calls.map { $0.0 },["日本語⟦MATH_0⟧English","日本語"])
        XCTAssertNotEqual(broker.calls[0].1.context,broker.calls[1].1.context)
    }
    func testReverseDirectionAndProviderFailure() async throws {
        let broker = AXTestTranslator()
        broker.action = { _ in throw NSError(domain:"unavailable",code:1) }
        let translator = AXParagraphTranslator(broker:broker,direction:.koreanToJapanese)
        let value = try await translator.translate(request("한국어 문장"),node:1)
        XCTAssertEqual(value.status,"failed"); XCTAssertNotNil(value.error)
        XCTAssertEqual(value.sourceLanguage,"ko"); XCTAssertEqual(value.targetLanguage,"ja")
        let skipped = try await translator.translate(request("日本語"),node:2)
        XCTAssertEqual(skipped.status,"skipped_non_source_language")
    }
    func testDevelopmentDirectionOverrideDoesNotPersist() {
        let saved = UserDefaults.standard.string(forKey:TranslationDirection.defaultsKey)
        let direction: TranslationDirection = TranslationDirection.load() == .japaneseToKorean ? .koreanToJapanese : .japaneseToKorean
        let broker = TranslationBroker(direction:direction,protectsNonSourceText:false)
        let coordinator = SessionCoordinator(broker:broker,createsOutputWindow:false,initialTranslationDirection:direction)
        XCTAssertEqual(coordinator.currentTranslationDirection,direction)
        XCTAssertEqual(UserDefaults.standard.string(forKey:TranslationDirection.defaultsKey),saved)
        XCTAssertFalse(broker.protectsNonSourceText)
    }
    private func ready(_ broker: TranslationBroker) async throws {
        for _ in 0..<1000 {
            if broker.isReadyForTranslation { return }
            try await Task.sleep(for:.milliseconds(1))
        }
        XCTFail("Broker did not become ready")
    }
    func testBrokerCachesAndInflightRequestsArePolicyScoped() async throws {
        let broker = TranslationBroker(direction:.japaneseToKorean,protectsNonSourceText:false)
        var sources: [String] = []
        let worker = Task { await broker.run(prepare:{},model:{ values in sources += values; return values.map { "訳:"+$0 } }) }
        defer { worker.cancel() }
        try await ready(broker)
        let prose = TranslationRequestOptions(protectsNonSourceText:false,context:"ax-prose")
        let code = TranslationRequestOptions(protectsNonSourceText:true,context:"ax-prose")
        let math = TranslationRequestOptions(protectsNonSourceText:false,context:"ax-math-v1-parts-a")
        let otherMath = TranslationRequestOptions(protectsNonSourceText:false,context:"ax-math-v2-parts-b")
        let first = Task { try await broker.translate("日本語 English",options:prose) }
        let duplicate = Task { try await broker.translate("日本語 English",options:prose) }
        let a = try await first.value, b = try await duplicate.value
        XCTAssertEqual(a,b); let count = sources.count
        _ = try await broker.translate("日本語 English",options:prose)
        XCTAssertEqual(sources.count,count)
        _ = try await broker.translate("日本語 English",options:code)
        XCTAssertGreaterThan(sources.count,count)
        _ = try await broker.translate("日本語 English",options:math)
        let mathCount = sources.count
        _ = try await broker.translate("日本語 English",options:otherMath)
        XCTAssertGreaterThan(sources.count,mathCount)
    }
    func testMixedProtectionRequestsShareWorkerWithoutGlobalPolicyChanges() async throws {
        let broker = TranslationBroker(direction:.japaneseToKorean,protectsNonSourceText:true)
        let worker = Task { await broker.run(prepare:{},model:{ values in
            values.map { $0.replacingOccurrences(of:"English",with:"영어") }
        }) }
        defer { worker.cancel() }
        try await ready(broker)
        let prose = Task { try await broker.translate("日本語 English",options:.init(protectsNonSourceText:false,context:"ax")) }
        let code = Task { try await broker.translate("日本語 English",options:.init(protectsNonSourceText:true,context:"ax")) }
        let a = try await prose.value, b = try await code.value
        XCTAssertTrue(a.contains("영어")); XCTAssertTrue(b.contains("English"))
        XCTAssertTrue(broker.protectsNonSourceText)
    }
    func testPreparationFailureIsRecordedWithoutReadiness() async {
        let broker = TranslationBroker(direction:.japaneseToKorean)
        await broker.run(prepare:{ throw NSError(domain:"model-unavailable",code:7) },model:{ $0 })
        XCTAssertFalse(broker.isReadyForTranslation)
        XCTAssertTrue(broker.preparationError?.contains("model-unavailable") == true)
    }
    func testDirectionIsPartOfRequestIdentity() {
        let options = TranslationRequestOptions(protectsNonSourceText:false,context:"ax")
        XCTAssertNotEqual(TranslationBroker.RequestKey(source:"text",direction:.japaneseToKorean,options:options),
                          TranslationBroker.RequestKey(source:"text",direction:.koreanToJapanese,options:options))
    }
    func testCancelledSharedWaiterDoesNotCancelOtherWaiter() async throws {
        let broker = TranslationBroker(direction:.japaneseToKorean)
        var release: CheckedContinuation<Void,Never>?
        let worker = Task { await broker.run(prepare:{},model:{ values in
            await withCheckedContinuation { release = $0 }
            return values.map { "訳:"+$0 }
        }) }
        defer { worker.cancel(); release?.resume(); release = nil }
        try await ready(broker)
        let a = Task { try await broker.translate("日本語") }
        let b = Task { try await broker.translate("日本語") }
        for _ in 0..<1000 {
            if release != nil { break }
            try await Task.sleep(for:.milliseconds(1))
        }
        _ = try XCTUnwrap(release)
        a.cancel()
        do { _ = try await a.value; XCTFail("must cancel") } catch is CancellationError {}
        release?.resume(); release = nil
        let value = try await b.value
        XCTAssertEqual(value,"訳:日本語")
    }
    func testOrphanedResponseCannotCompleteNewRequest() async throws {
        let broker = TranslationBroker(direction:.japaneseToKorean,protectsNonSourceText:true)
        var release: CheckedContinuation<Void,Never>?
        var batch = 0
        let worker = Task { await broker.run(prepare:{},model:{ values in
            batch += 1
            if batch == 1 { await withCheckedContinuation { release = $0 } }
            return values.map { "batch\(batch):"+$0 }
        }) }
        defer { worker.cancel(); release?.resume(); release = nil }
        try await ready(broker)
        let first = Task { try await broker.translate("日本語") }
        for _ in 0..<1000 {
            if release != nil { break }
            try await Task.sleep(for:.milliseconds(1))
        }
        _ = try XCTUnwrap(release)
        first.cancel()
        do { _ = try await first.value; XCTFail("must cancel") } catch is CancellationError {}
        // Invalidate the in-flight policy before admitting the new waiter.
        broker.setProtectsNonSourceText(false)
        let next = Task { try await broker.translate("日本語") }
        await Task.yield()
        release?.resume(); release = nil
        let value = try await next.value
        XCTAssertEqual(value,"batch2:日本語")
    }
}
#endif
