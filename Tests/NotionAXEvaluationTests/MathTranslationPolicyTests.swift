import XCTest
@testable import NotionAXCore

final class MathTranslationPolicyTests: XCTestCase {
    let parts = [MathContentPart(kind: .text, text: "合計は "), .init(kind: .math, text: nil), .init(kind: .text, text: " で求めます。")]
    func testOnlyDelimiterWhitespaceIsInsignificant() {
        let plan = MathTranslationPolicy.plan(parts)!
        let parsed = MathTranslationPolicy.parse("합계는 ⟦ \nMATH_0\t⟧ 로 구합니다.", plan: plan)
        XCTAssertTrue(parsed.valid)
        XCTAssertEqual(parsed.translations[0], "합계는 ")
        XCTAssertEqual(parsed.translations[2], " 로 구합니다.")
        for text in ["합계", "⟦MATH_00⟧", "⟦MATH_1⟧", "⟦MATH _0⟧", "⟦MATH_0⟧⟦MATH_0⟧", "합계는 ⟦MATH_0⟧"] {
            XCTAssertFalse(MathTranslationPolicy.parse(text, plan: plan).valid, text)
        }
        XCTAssertFalse(MathTranslationPolicy.parse("합계는 ⟦MATH_0⟧ 로 구합니다. ⟦MATH _0⟧", plan: plan).valid)
    }
    func testMarkersCannotReorderDuplicateOrGenerateTextInAnEmptyGap() {
        let plan = MathTranslationPolicy.plan([.init(kind: .math, text: nil), .init(kind: .math, text: nil)])!
        XCTAssertTrue(MathTranslationPolicy.parse("⟦MATH_0⟧⟦MATH_1⟧", plan: plan).valid)
        for text in ["⟦MATH_1⟧⟦MATH_0⟧", "⟦MATH_0⟧⟦MATH_0⟧", "word⟦MATH_0⟧⟦MATH_1⟧", "⟦MATH_0⟧word⟦MATH_1⟧"] {
            XCTAssertFalse(MathTranslationPolicy.parse(text, plan: plan).valid)
        }
    }
    func testLiteralMarkersAndInvisibleCharactersAreNotDeleted() {
        let plan = MathTranslationPolicy.plan([.init(kind: .text, text: "⟦MATH_0⟧ の説明"), .init(kind: .math, text: nil)])!
        XCTAssertEqual(plan.prefix, "MATHX")
        XCTAssertTrue(MathTranslationPolicy.parse("⟦MATH_0⟧ 설명⟦MATHX_0⟧", plan: plan).valid)
        XCTAssertTrue(MathTranslationPolicy.nonrendering(" \u{200B}"))
        XCTAssertFalse(MathTranslationPolicy.nonrendering("👩‍💻"))
        XCTAssertFalse(MathTranslationPolicy.nonrendering("a\u{200B}"))
    }
    @MainActor func testContextFirstWithoutIndependentRequestsWhenSpacingChanges() async throws {
        var calls: [String] = []
        let result = try await MathTranslationPolicy.translate(parts, eligible: { _ in true }) { source in
            calls.append(source); return "합계는 ⟦ MATH_0⟧ 로 구합니다."
        }
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(result.method, "math-placeholder-context")
        XCTAssertEqual(result.segments.map(\.id), [0, 2])
        XCTAssertEqual(result.rawContextTranslation, "합계는 ⟦ MATH_0⟧ 로 구합니다.")
    }
    @MainActor func testInvalidMarkerFallsBackWithoutSendingFormulaOrNonSourceText() async throws {
        let input: [MathContentPart] = [.init(kind: .text, text: "日本語"), .init(kind: .math, text: nil), .init(kind: .text, text: "English")]
        var calls: [String] = []
        let result = try await MathTranslationPolicy.translate(input, eligible: { $0 == "日本語" }) { source in
            calls.append(source); return calls.count == 1 ? "lost marker" : "일본어"
        }
        XCTAssertEqual(calls, ["日本語⟦MATH_0⟧English", "日本語"])
        XCTAssertEqual(result.method, "math-independent-fallback")
        XCTAssertEqual(result.markerValidation, "marker_identity_count_or_order")
        XCTAssertEqual(result.segments.last?.status, "skipped_non_source_language")
    }
    @MainActor func testFallbackFailureIsNotPresentedAsSuccess() async throws {
        let result = try await MathTranslationPolicy.translate(parts, eligible: { _ in true }) { _ in throw NSError(domain: "test unavailable", code: 1) }
        XCTAssertEqual(result.status, "failed")
        XCTAssertNotNil(result.contextError)
        XCTAssertTrue(result.segments.allSatisfy { $0.status == "failed" })
    }
    @MainActor func testContextCancellationNeverFallsBack() async throws {
        var calls = 0
        do {
            _ = try await MathTranslationPolicy.translate(parts, eligible: { _ in true }) { _ in
                calls += 1
                throw CancellationError()
            }
            XCTFail("Cancellation must propagate")
        } catch is CancellationError {
            XCTAssertEqual(calls, 1)
        }
    }
    @MainActor func testFallbackCancellationPropagatesAcrossSubmittedSegments() async throws {
        var calls = 0
        do {
            _ = try await MathTranslationPolicy.translate(parts, eligible: { _ in true }) { _ in
                calls += 1
                if calls == 1 { return "missing markers" }
                throw CancellationError()
            }
            XCTFail("Cancellation must propagate")
        } catch is CancellationError {
            XCTAssertTrue((2...3).contains(calls))
        }
    }
    @MainActor func testHardBreakMarkersContainNoNewlinesAndCoexistWithMath() async throws {
        let values: [MathContentPart] = [.init(kind:.text,text:"日本語"),.init(kind:.hardBreak,text:"\n"),
            .init(kind:.text,text:""),.init(kind:.hardBreak,text:"\n"),.init(kind:.math,text:nil),.init(kind:.text,text:"次")]
        let plan = MathTranslationPolicy.plan(values)!
        XCTAssertFalse(plan.source.contains("\n"))
        let result = try await MathTranslationPolicy.translate(values,eligible:{ _ in true }) { _ in
            "일본어⟦ AXBOUNDARY_0⟧⟦AXBOUNDARY_1 ⟧⟦AXBOUNDARY_2⟧다음"
        }
        XCTAssertEqual(result.markerValidation,"valid")
        XCTAssertEqual(result.segments.map(\.id),[0,2,5])
    }
    @MainActor func testFallbackRequestsStartBeforeEitherCompletes() async throws {
        var started = 0
        let outcome = try await MathTranslationPolicy.translate(parts,eligible:{ _ in true },forceIndependent:true) { source in
            started += 1
            let deadline = Date().addingTimeInterval(2)
            while started < 2 && Date() < deadline { try await Task.sleep(for:.milliseconds(5)) }
            XCTAssertEqual(started,2)
            return source
        }
        XCTAssertEqual(outcome.segments.map(\.id),[0,2])
        XCTAssertEqual(outcome.markerValidation,"forced_independent")
    }
    func testNativeOwnershipSplitsLeavesWithoutGeometry() {
        let rows: [[String: Any]] = [["role": "AXTextArea"], ["role": "AXStaticText", "value": "before"],
            ["role": "AXGroup", "mathOwner": 2], ["role": "AXStaticText", "value": "math", "mathOwner": 2],
            ["role": "AXStaticText", "value": "after"]]
        let result = MathSegments.parts(root: 0, rows: rows, children: [0: [1, 2, 4], 2: [3]])!
        XCTAssertEqual(result.map(\.math), [nil, 2, nil])
        XCTAssertEqual(result.map(\.leaves), [[1], [], [4]])
        XCTAssertNil(MathSegments.parts(root: 1, rows: rows, children: [:]))
    }
}
