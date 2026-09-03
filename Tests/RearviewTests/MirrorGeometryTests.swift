import Foundation
import AppKit
import Testing
@testable import Rearview

@Suite
struct MirrorGeometryTests {
    @Test func searchMatcherAndTextAssemblerHandleLiteralRegexAndInvalidQueries() {
        if case .success(let matches) = MirrorSearchMatcher.matches(
            in: "Hello hello 123", query: "hello", caseSensitive: false, regex: false
        ) {
            #expect(matches.count == 2)
        } else {
            Issue.record("literal search failed")
        }
        if case .success(let matches) = MirrorSearchMatcher.matches(
            in: "A12 B7", query: "[A-Z]\\d+", caseSensitive: true, regex: true
        ) {
            #expect(matches.count == 2)
        } else {
            Issue.record("regex search failed")
        }
        if case .failure = MirrorSearchMatcher.matches(
            in: "text", query: "[", caseSensitive: false, regex: true
        ) {
            // Expected invalid regular expression.
        } else {
            Issue.record("invalid regex was accepted")
        }
        let text = MirrorSearchTextAssembler.text(parts: [
            ("번", nil), ("역", nil), ("문", nil), ("원", "\n"), ("문", nil)
        ])
        #expect(text == "번역문\n원문")
        if case .success(let matches) = MirrorSearchMatcher.matches(
            in: text, query: "번역문", caseSensitive: true, regex: false
        ) {
            #expect(matches.count == 1)
        } else {
            Issue.record("contiguous Korean search failed")
        }
    }

    @Test func mirrorItemsAndClipboardPreserveReadingOrder() {
        let translatedLine = testLine("設定", normalizedRect: .zero)
        let preservedLine = testLine("Live 2", confidence: 0.99, normalizedRect: CGRect(x: 0, y: 0.2, width: 0.3, height: 0.1))
        let items = makeMirrorItems(
            frameID: 7,
            recognizedLines: [translatedLine, preservedLine],
            translations: [
                MirrorTranslation(frameID: 7, line: translatedLine, translatedText: "설정"),
                MirrorTranslation(frameID: 6, line: translatedLine, translatedText: "이전 프레임")
            ]
        )
        #expect(items.count == 2)
        #expect(items[0].translatedText == "설정")
        #expect(items[0].presentation == .translated)
        #expect(items[1].translatedText == "Live 2")
        #expect(items[1].presentation == .selectionOnly)

        let untranslated = makeMirrorItems(
            frameID: 7, recognizedLines: [translatedLine], translations: []
        )
        #expect(untranslated[0].translatedText == "設定")
        #expect(untranslated[0].presentation == .selectionOnly)
        #expect(mirrorClipboardText(items: items) == "Live 2\n설정")
        #expect(mirrorClipboardText(items: []) == "")

        let sameLine = [
            MirrorItem(
                id: UUID(), translatedText: "왼쪽", presentation: .selectionOnly,
                normalizedRect: CGRect(x: 0.1, y: 0.6, width: 0.2, height: 0.1),
                background: .lightBackground, foreground: .darkText
            ),
            MirrorItem(
                id: UUID(), translatedText: "오른쪽", presentation: .translated,
                normalizedRect: CGRect(x: 0.4, y: 0.62, width: 0.2, height: 0.1),
                background: .lightBackground, foreground: .darkText
            )
        ]
        #expect(mirrorClipboardText(items: sameLine) == "왼쪽 오른쪽")
    }

    @Test func contentFitScalingAndResizePreserveAnchors() {
        let fitted = aspectFitRect(
            contentSize: CGSize(width: 1600, height: 900),
            inside: CGRect(x: 0, y: 0, width: 800, height: 800)
        )
        #expect(expectApproximatelyEqual(fitted.width, 800))
        #expect(expectApproximatelyEqual(fitted.height, 450))
        let fittedSize = mirrorContentFitSize(
            contentSize: CGSize(width: 1600, height: 900), viewportSize: CGSize(width: 1000, height: 1000)
        )
        #expect(expectApproximatelyEqual(fittedSize.width, 1000))
        #expect(expectApproximatelyEqual(fittedSize.height, 562.5))
        #expect(mirrorScaledContentSize(
            previousSelectionSize: CGSize(width: 200, height: 100),
            currentViewportSize: CGSize(width: 200, height: 100),
            newSelectionSize: CGSize(width: 400, height: 200)
        ) == CGSize(width: 400, height: 200))
        #expect(mirrorScaledContentSize(
            previousSelectionSize: CGSize(width: 100, height: 100),
            currentViewportSize: CGSize(width: 150, height: 150),
            newSelectionSize: CGSize(width: 200, height: 100)
        ) == CGSize(width: 300, height: 150))
        #expect(aspectFitRect(
            contentSize: CGSize(width: 400, height: 200),
            inside: CGRect(x: 0, y: 0, width: 600, height: 250), resizingEdge: .left
        ) == CGRect(x: 100, y: 0, width: 500, height: 250))
        #expect(aspectFitRect(
            contentSize: CGSize(width: 400, height: 200),
            inside: CGRect(x: 0, y: 0, width: 500, height: 300), resizingEdge: .bottom
        ) == CGRect(x: 0, y: 50, width: 500, height: 250))
        #expect(mirrorFrame(
            resizing: CGRect(x: 100, y: 200, width: 400, height: 300),
            to: CGSize(width: 500, height: 299.5), from: .right
        ) == CGRect(x: 100, y: 200, width: 500, height: 300))
        #expect(mirrorFrame(
            resizing: CGRect(x: 100, y: 200, width: 400, height: 300),
            to: CGSize(width: 399.5, height: 250), from: .top
        ) == CGRect(x: 100, y: 200, width: 400, height: 250))
        #expect(mirrorFrame(
            resizing: CGRect(x: 100, y: 200, width: 400, height: 300),
            to: CGSize(width: 500, height: 350), from: .bottomLeft
        ) == CGRect(x: 0, y: 150, width: 500, height: 350))
    }

    @Test func imageAndTextGeometryUsesPixelAlignment() {
        #expect(defaultMirrorContentFrame(
            selectionSize: CGSize(width: 1600, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 800)
        ) == CGRect(x: 0, y: 118.75, width: 1000, height: 562.5))
        #expect(mirrorNativeContentSize(
            imagePixelSize: CGSize(width: 1316, height: 878), backingScale: 2
        ) == CGSize(width: 658, height: 439))
        #expect(mirrorZoomPercentage(contentWidth: 100, nativeWidth: 100) == 100)
        #expect(mirrorZoomPercentage(contentWidth: 110, nativeWidth: 100) == 110)
        #expect(mirrorZoomPercentage(contentWidth: 0, nativeWidth: 100) == 100)
        #expect(mirrorItemRect(
            normalizedRect: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
            imageRect: CGRect(x: 20, y: 30, width: 200, height: 100)
        ) == CGRect(x: 40, y: 50, width: 60, height: 40))
        #expect(mirrorPixelAlignedRect(
            CGRect(x: 10.24, y: 20.26, width: 100.49, height: 50.48), backingScale: 2
        ) == CGRect(x: 10, y: 20.5, width: 100.5, height: 50))
        #expect(mirrorColorsAreVisuallyEqual(
            RGBAColor(red: 0.10, green: 0.20, blue: 0.30, alpha: 1),
            RGBAColor(red: 0.12, green: 0.18, blue: 0.32, alpha: 1)
        ))
        #expect(!mirrorColorsAreVisuallyEqual(
            RGBAColor(red: 0.10, green: 0.20, blue: 0.30, alpha: 1),
            RGBAColor(red: 0.20, green: 0.20, blue: 0.30, alpha: 1)
        ))
        #expect(mirrorRectsAreVisuallyEqual(
            CGRect(x: 10, y: 20, width: 100, height: 30),
            CGRect(x: 10.5, y: 19.5, width: 100, height: 30.5), backingScale: 2
        ))
        #expect(!mirrorRectsAreVisuallyEqual(
            CGRect(x: 10, y: 20, width: 100, height: 30),
            CGRect(x: 11, y: 20, width: 100, height: 30), backingScale: 2
        ))
        let prospectiveWindowFrame = CGRect(
            x: 1057.8616333007812, y: 565.3880004882812,
            width: 668, height: 160
        )
        let storedWindowFrame = CGRect(x: 1057, y: 565, width: 668, height: 160)
        #expect(mirrorWindowFrameAsStoredByAppKit(prospectiveWindowFrame) == storedWindowFrame)
    }

    @Test func translationLayoutUsesConfiguredExpansionAndCompressionRules() {
        let source = CGRect(x: 20, y: 40, width: 100, height: 20)
        let bounds = CGRect(x: 0, y: 0, width: 200, height: 100)

        #expect(MirrorTextLayoutTuning.maximumTextVerticalScale > 0)
        #expect(MirrorTextLayoutTuning.maximumTextVerticalScale <= 1)
        #expect(MirrorTextLayoutTuning.backgroundVerticalExpansionFactor >= 1)
        #expect(MirrorTextLayoutTuning.minimumHorizontalTextScale > 0)
        #expect(MirrorTextLayoutTuning.minimumHorizontalTextScale <= 1)
        #expect(MirrorTextLayoutTuning.minimumFontScale > 0)
        #expect(MirrorTextLayoutTuning.minimumFontScale <= 1)
        #expect(MirrorTextLayoutTuning.fontScaleSearchCount >= 0)
        #expect(MirrorTextLayoutTuning.horizontalExpansionHeightMultiplier >= 0)
        guard MirrorTextLayoutTuning.maximumTextVerticalScale > 0,
              MirrorTextLayoutTuning.maximumTextVerticalScale <= 1,
              MirrorTextLayoutTuning.backgroundVerticalExpansionFactor >= 1,
              MirrorTextLayoutTuning.minimumHorizontalTextScale > 0,
              MirrorTextLayoutTuning.minimumHorizontalTextScale <= 1,
              MirrorTextLayoutTuning.minimumFontScale > 0,
              MirrorTextLayoutTuning.minimumFontScale <= 1,
              MirrorTextLayoutTuning.fontScaleSearchCount >= 0,
              MirrorTextLayoutTuning.horizontalExpansionHeightMultiplier >= 0 else {
            return
        }

        let initial = mirrorInitialTextRect(sourceRect: source, inside: bounds)
        let initialExtra = source.height
            * (MirrorTextLayoutTuning.backgroundVerticalExpansionFactor - 1) / 2
        let expectedInitial = CGRect(
            x: source.minX,
            y: source.minY - initialExtra,
            width: source.width,
            height: source.height + initialExtra * 2
        ).intersection(bounds)
        #expect(initial == expectedInitial)

        let initialCollision = mirrorTextCollisionRects(for: initial, sourceRect: source)
        #expect(initialCollision == [source])
        #expect(expectApproximatelyEqual(
            mirrorMaximumTextHeight(for: source.height),
            source.height * MirrorTextLayoutTuning.maximumTextVerticalScale
        ))

        let maximumWidth = source.width
            + source.height * MirrorTextLayoutTuning.horizontalExpansionHeightMultiplier
        let targetWidth = min(max(source.width, 140), maximumWidth)
        let expanded = mirrorOneLineTextRect(
            sourceRect: source,
            requiredWidth: 140,
            otherRects: [source],
            reservedCollisionRects: [],
            inside: bounds,
            sourceIndex: 0
        )
        #expect(expanded == CGRect(
            x: source.minX,
            y: initial.minY,
            width: targetWidth,
            height: initial.height
        ).intersection(bounds))

        let blockedOnRight = mirrorOneLineTextRect(
            sourceRect: source,
            requiredWidth: 180,
            otherRects: [source, CGRect(x: 140, y: 40, width: 20, height: 20)],
            reservedCollisionRects: [],
            inside: bounds,
            sourceIndex: 0
        )
        let desiredExtra = max(0, targetWidth - source.width)
        let rightExtra = min(desiredExtra, 20)
        let leftExtra = min(desiredExtra - rightExtra, 20)
        #expect(blockedOnRight == CGRect(
            x: source.minX - leftExtra,
            y: initial.minY,
            width: source.width + leftExtra + rightExtra,
            height: initial.height
        ).intersection(bounds))

        #expect(expectApproximatelyEqual(
            mirrorHorizontalTextScale(naturalWidth: 120, availableWidth: 140), 1
        ))
        #expect(expectApproximatelyEqual(
            mirrorHorizontalTextScale(naturalWidth: 200, availableWidth: 180), 0.9
        ))
        #expect(expectApproximatelyEqual(
            mirrorHorizontalTextScale(naturalWidth: 200, availableWidth: 100),
            MirrorTextLayoutTuning.minimumHorizontalTextScale
        ))

        let reserved = CGRect(x: 140, y: 40, width: 20, height: 20)
        let reservedExpansion = mirrorOneLineTextRect(
            sourceRect: source,
            requiredWidth: 180,
            otherRects: [source],
            reservedCollisionRects: [reserved],
            inside: bounds,
            sourceIndex: 0
        )
        #expect(reservedExpansion == blockedOnRight)
    }

    @Test func processingStatusTitlesAndStateAreStable() {
        #expect(MirrorProcessingStatus.recognizing.title == "텍스트 인식 중")
        #expect(MirrorProcessingStatus.translating(completed: 2, total: 5).title == "번역 중 2/5")
        #expect(MirrorProcessingStatus.completed(failures: 0).title == "완료")
        #expect(MirrorProcessingStatus.completed(failures: 1).title == "완료 · 1줄 실패")
        #expect(MirrorProcessingStatus.recognizing.isProcessing)
        #expect(MirrorProcessingStatus.translating(completed: 1, total: 2).isProcessing)
        #expect(!MirrorProcessingStatus.completed(failures: 0).isProcessing)
    }

}
