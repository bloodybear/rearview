import AppKit
import CoreText

struct NativeMirrorRenderedFragment {
    let itemID: UUID
    let text: String
    let rect: CGRect
    let characterOffset: Int
}

private struct NativeMirrorTextLayout {
    let frame: CGRect
    let fontSize: CGFloat
    let lineCount: Int
    let text: String
    let textOriginX: CGFloat
    let horizontalScale: CGFloat
}

private struct NativeMirrorRectKey: Hashable {
    let minX: Int
    let minY: Int
    let maxX: Int
    let maxY: Int

    init(_ rect: CGRect) {
        let scale: CGFloat = 1_000
        minX = Int((rect.minX * scale).rounded())
        minY = Int((rect.minY * scale).rounded())
        maxX = Int((rect.maxX * scale).rounded())
        maxY = Int((rect.maxY * scale).rounded())
    }
}

private struct NativeMirrorTextLine {
    let line: CTLine
    let range: NSRange
    let width: CGFloat
    let ascent: CGFloat
    let descent: CGFloat
    let leading: CGFloat

    var height: CGFloat { ascent + descent + max(0, leading) }
}

private struct NativeMirrorTextMeasurement {
    let width: CGFloat
    let height: CGFloat
    let complete: Bool
}

private struct NativeMirrorArtwork {
    let frameID: UInt64
    let imageSize: CGSize
    let backgroundLayer: CGImage?
    let textLayer: CGImage?
    let textRects: [UUID: CGRect]
    let layouts: [UUID: NativeMirrorTextLayout]
    let fragments: [NativeMirrorRenderedFragment]
}

@MainActor
private final class NativeMirrorRenderer {
    private struct LayoutKey: Hashable {
        let text: String
        let sourceRect: NativeMirrorRectKey
        let oneLineRect: NativeMirrorRectKey
    }

    private var layoutCache: [LayoutKey: NativeMirrorTextLayout] = [:]
    private var artwork: NativeMirrorArtwork?
    private var artworkFingerprint: Int?
    private var compositeImage: CGImage?
    private var compositeFingerprint: Int?
    private var compositeOpacity: CGFloat?

    private(set) var layoutCacheHits = 0
    private(set) var layoutCacheMisses = 0
    private(set) var artworkBuildCount = 0
    private(set) var compositeBuildCount = 0
    private(set) var lastArtworkWasRebuilt = false
    private(set) var lastCompositeWasRebuilt = false

    var image: CGImage? { compositeImage }
    var renderedTextRects: [UUID: CGRect] { artwork?.textRects ?? [:] }
    var renderedFragments: [NativeMirrorRenderedFragment] { artwork?.fragments ?? [] }

    fileprivate func layoutMetrics(for id: UUID) -> (
        frame: CGRect, fontSize: CGFloat, horizontalScale: CGFloat, lineCount: Int, text: String
    )? {
        guard let layout = artwork?.layouts[id] else { return nil }
        return (
            frame: layout.frame,
            fontSize: layout.fontSize,
            horizontalScale: layout.horizontalScale,
            lineCount: layout.lineCount,
            text: layout.text
        )
    }

    func render(frame: MirrorFrame, backgroundOpacity: CGFloat) {
        let fingerprint = fingerprint(for: frame)
        lastArtworkWasRebuilt = false
        lastCompositeWasRebuilt = false
        if artwork == nil || artworkFingerprint != fingerprint {
            artwork = buildArtwork(for: frame)
            artworkFingerprint = fingerprint
            lastArtworkWasRebuilt = true
            compositeImage = nil
            compositeFingerprint = nil
            compositeOpacity = nil
        }
        guard compositeImage == nil
            || compositeFingerprint != fingerprint
            || compositeOpacity != backgroundOpacity else { return }
        compositeImage = compose(
            source: frame.image,
            artwork: artwork,
            backgroundOpacity: backgroundOpacity
        )
        compositeFingerprint = fingerprint
        compositeOpacity = backgroundOpacity
        compositeBuildCount += 1
        lastCompositeWasRebuilt = true
    }

    private func fingerprint(for frame: MirrorFrame) -> Int {
        var hasher = Hasher()
        hasher.combine(frame.frameID)
        hasher.combine(frame.image.width)
        hasher.combine(frame.image.height)
        for item in frame.translatedItems {
            hasher.combine(item.id)
            hasher.combine(item.translatedText)
            hasher.combine(item.isTranslated)
            hasher.combine(item.normalizedRect.minX)
            hasher.combine(item.normalizedRect.minY)
            hasher.combine(item.normalizedRect.width)
            hasher.combine(item.normalizedRect.height)
            hasher.combine(item.background.red)
            hasher.combine(item.background.green)
            hasher.combine(item.background.blue)
            hasher.combine(item.background.alpha)
            hasher.combine(item.foreground.red)
            hasher.combine(item.foreground.green)
            hasher.combine(item.foreground.blue)
            hasher.combine(item.foreground.alpha)
        }
        return hasher.finalize()
    }

    private func makeContext(width: Int, height: Int) -> CGContext? {
        guard width > 0, height > 0 else { return nil }
        return CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    private func buildArtwork(for frame: MirrorFrame) -> NativeMirrorArtwork? {
        artworkBuildCount += 1
        layoutCacheHits = 0
        layoutCacheMisses = 0
        let imageSize = CGSize(width: frame.image.width, height: frame.image.height)
        guard let backgroundContext = makeContext(width: frame.image.width, height: frame.image.height),
              let textContext = makeContext(width: frame.image.width, height: frame.image.height)
        else { return nil }

        let pixelRect = CGRect(origin: .zero, size: imageSize)
        backgroundContext.clear(pixelRect)
        textContext.clear(pixelRect)
        backgroundContext.setAllowsAntialiasing(false)
        backgroundContext.setShouldAntialias(false)
        textContext.setAllowsFontSmoothing(true)
        textContext.setShouldAntialias(true)

        let sourceRects = frame.translatedItems.map { item in
            mirrorPixelAlignedRect(
                mirrorItemRect(normalizedRect: item.normalizedRect, imageRect: pixelRect),
                backingScale: 1
            )
        }
        var textRects: [UUID: CGRect] = [:]
        var layouts: [UUID: NativeMirrorTextLayout] = [:]
        var fragments: [NativeMirrorRenderedFragment] = []
        let sourceIndexByID = Dictionary(
            uniqueKeysWithValues: frame.translatedItems.enumerated().map { ($0.element.id, $0.offset) }
        )
        let orderedIndices = mirrorItemsInReadingOrder(frame.translatedItems).compactMap {
            sourceIndexByID[$0.id]
        }
        var reservedCollisionRects: [CGRect] = []
        for index in orderedIndices {
            let item = frame.translatedItems[index]
            guard item.isTranslated else { continue }
            let sourceRect = sourceRects[index]
            let referenceFontSize = referenceFontSize(
                for: mirrorMaximumTextHeight(for: sourceRect.height)
            )
            let requiredWidth = measuredTextSize(
                item.translatedText,
                fontSize: referenceFontSize,
                width: .greatestFiniteMagnitude,
                lineCount: 1
            ).width
            let oneLineRect = mirrorOneLineTextRect(
                sourceRect: sourceRect,
                requiredWidth: requiredWidth,
                otherRects: sourceRects,
                reservedCollisionRects: reservedCollisionRects,
                inside: pixelRect,
                sourceIndex: index
            )
            let layout = layout(
                for: item,
                sourceRect: sourceRect,
                oneLineRect: oneLineRect
            )
            reservedCollisionRects.append(contentsOf:
                mirrorTextCollisionRects(for: layout.frame, sourceRect: sourceRect)
            )
            backgroundContext.setFillColor(item.background.nsColor.cgColor)
            backgroundContext.fill(layout.frame)
            textRects[item.id] = layout.frame
            layouts[item.id] = layout
            fragments.append(contentsOf: draw(item: item, layout: layout, in: textContext))
        }
        return NativeMirrorArtwork(
            frameID: frame.frameID,
            imageSize: imageSize,
            backgroundLayer: backgroundContext.makeImage(),
            textLayer: textContext.makeImage(),
            textRects: textRects,
            layouts: layouts,
            fragments: fragments
        )
    }

    private func compose(
        source: CGImage, artwork: NativeMirrorArtwork?, backgroundOpacity: CGFloat
    ) -> CGImage? {
        guard let context = makeContext(width: source.width, height: source.height) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: source.width, height: source.height)
        context.setBlendMode(.copy)
        context.draw(source, in: rect)
        context.setBlendMode(.normal)
        guard let artwork else { return context.makeImage() }
        if let backgroundLayer = artwork.backgroundLayer {
            context.saveGState()
            context.setAlpha(MirrorBackgroundOpacity.clamp(backgroundOpacity))
            context.draw(backgroundLayer, in: rect)
            context.restoreGState()
        }
        if let textLayer = artwork.textLayer {
            context.setAlpha(1)
            context.draw(textLayer, in: rect)
        }
        return context.makeImage()
    }

    private func layout(
        for item: MirrorItem, sourceRect: CGRect, oneLineRect: CGRect
    ) -> NativeMirrorTextLayout {
        let key = LayoutKey(
            text: item.translatedText,
            sourceRect: NativeMirrorRectKey(sourceRect),
            oneLineRect: NativeMirrorRectKey(oneLineRect)
        )
        if let cached = layoutCache[key] {
            layoutCacheHits += 1
            return cached
        }
        layoutCacheMisses += 1

        let referenceFontSize = referenceFontSize(
            for: mirrorMaximumTextHeight(for: sourceRect.height)
        )
        let requiredWidth = measuredTextSize(
            item.translatedText,
            fontSize: referenceFontSize,
            width: .greatestFiniteMagnitude,
            lineCount: 1
        ).width
        let horizontalScale = mirrorHorizontalTextScale(
            naturalWidth: requiredWidth,
            availableWidth: oneLineRect.width
        )
        if fits(
            item.translatedText,
            fontSize: referenceFontSize,
            size: oneLineRect.size,
            lineCount: 1,
            horizontalScale: horizontalScale
        ) {
            let measured = measuredTextSize(
                item.translatedText,
                fontSize: referenceFontSize,
                width: oneLineRect.width,
                lineCount: 1
            )
            let result = NativeMirrorTextLayout(
                frame: oneLineRect,
                fontSize: referenceFontSize,
                lineCount: 1,
                text: item.translatedText,
                textOriginX: oneLineTextOriginX(
                    sourceRect: sourceRect,
                    frame: oneLineRect,
                    measuredWidth: measured.width * horizontalScale
                ),
                horizontalScale: horizontalScale
            )
            store(result, for: key)
            return result
        }

        if let fontScale = largestFittingScale(
            text: item.translatedText,
            referenceFontSize: referenceFontSize,
            size: oneLineRect.size,
            lineCount: 1,
            horizontalScale: horizontalScale
        ) {
            let fontSize = referenceFontSize * fontScale
            let result = NativeMirrorTextLayout(
                frame: oneLineRect,
                fontSize: fontSize,
                lineCount: 1,
                text: item.translatedText,
                textOriginX: oneLineTextOriginX(
                    sourceRect: sourceRect,
                    frame: oneLineRect,
                    measuredWidth: measuredTextSize(
                        item.translatedText,
                        fontSize: fontSize,
                        width: oneLineRect.width,
                        lineCount: 1
                    ).width * horizontalScale
                ),
                horizontalScale: horizontalScale
            )
            store(result, for: key)
            return result
        }

        let truncated = largestFittingTruncatedText(
            text: item.translatedText,
            referenceFontSize: referenceFontSize,
            size: oneLineRect.size,
            lineCount: 1,
            horizontalScale: horizontalScale
        )
        let result = NativeMirrorTextLayout(
            frame: oneLineRect,
            fontSize: truncated?.fontSize ?? referenceFontSize * MirrorTextLayoutTuning.minimumFontScale,
            lineCount: 1,
            text: truncated?.text ?? "…",
            textOriginX: oneLineTextOriginX(
                sourceRect: sourceRect,
                frame: oneLineRect,
                measuredWidth: measuredTextSize(
                    truncated?.text ?? "…",
                    fontSize: truncated?.fontSize
                        ?? referenceFontSize * MirrorTextLayoutTuning.minimumFontScale,
                    width: oneLineRect.width,
                    lineCount: 1
                ).width * horizontalScale
            ),
            horizontalScale: horizontalScale
        )
        store(result, for: key)
        return result
    }

    private func store(_ layout: NativeMirrorTextLayout, for key: LayoutKey) {
        if layoutCache.count >= 512 {
            for staleKey in layoutCache.keys.prefix(128) { layoutCache[staleKey] = nil }
        }
        layoutCache[key] = layout
    }

    private func referenceFontSize(for targetHeight: CGFloat) -> CGFloat {
        guard targetHeight > 0 else { return 0 }
        let probeFont = systemFont(ofSize: 1)
        let probeHeight = typographicLineHeight(of: probeFont)
        guard probeHeight > 0 else { return 0 }
        return targetHeight / probeHeight
    }

    private func fontScaleCandidates() -> [CGFloat] {
        let lower = min(1, max(0, MirrorTextLayoutTuning.minimumFontScale))
        let searchCount = max(0, MirrorTextLayoutTuning.fontScaleSearchCount)
        guard lower < 1, searchCount > 0 else { return [1] }
        let candidateCount = 1 << min(searchCount, 20)
        guard candidateCount > 1 else { return [1] }
        let step = (1 - lower) / CGFloat(candidateCount - 1)
        return (0..<candidateCount).map { 1 - CGFloat($0) * step }
    }

    private func largestFittingScale(
        text: String, referenceFontSize: CGFloat, size: CGSize, lineCount: Int,
        horizontalScale: CGFloat
    ) -> CGFloat? {
        guard referenceFontSize > 0 else { return nil }
        let candidates = fontScaleCandidates()
        if fits(
            text,
            fontSize: referenceFontSize * candidates[0],
            size: size,
            lineCount: lineCount,
            horizontalScale: horizontalScale
        ) {
            return candidates[0]
        }
        guard candidates.count > 1 else { return nil }
        var low = 1
        var high = candidates.count - 1
        var best: Int?
        while low <= high {
            let midpoint = (low + high) / 2
            if fits(
                text,
                fontSize: referenceFontSize * candidates[midpoint],
                size: size,
                lineCount: lineCount,
                horizontalScale: horizontalScale
            ) {
                best = midpoint
                high = midpoint - 1
            } else {
                low = midpoint + 1
            }
        }
        return best.map { candidates[$0] }
    }

    private func largestFittingTruncatedText(
        text: String, referenceFontSize: CGFloat, size: CGSize, lineCount: Int,
        horizontalScale: CGFloat
    ) -> (text: String, fontSize: CGFloat)? {
        guard referenceFontSize > 0 else { return nil }
        for scale in fontScaleCandidates() {
            let fontSize = referenceFontSize * scale
            if let text = longestFittingPrefix(
                text: text,
                fontSize: fontSize,
                size: size,
                lineCount: lineCount,
                horizontalScale: horizontalScale
            ) {
                return (text, fontSize)
            }
        }
        return nil
    }

    private func longestFittingPrefix(
        text: String, fontSize: CGFloat, size: CGSize, lineCount: Int,
        horizontalScale: CGFloat
    ) -> String? {
        let characters = Array(text)
        var low = 0
        var high = characters.count
        var best: String?
        while low <= high {
            let midpoint = (low + high) / 2
            let candidate = String(characters.prefix(midpoint)) + "…"
            if fits(
                candidate,
                fontSize: fontSize,
                size: size,
                lineCount: lineCount,
                horizontalScale: horizontalScale
            ) {
                best = candidate
                low = midpoint + 1
            } else {
                high = midpoint - 1
            }
        }
        return best
    }

    private func oneLineTextOriginX(
        sourceRect: CGRect, frame: CGRect, measuredWidth: CGFloat
    ) -> CGFloat {
        let sourceOrigin = sourceRect.minX
        if sourceOrigin + measuredWidth <= frame.maxX + 0.5 {
            return sourceOrigin
        }
        return frame.maxX - measuredWidth
    }

    private func fits(
        _ text: String, fontSize: CGFloat, size: CGSize, lineCount: Int,
        horizontalScale: CGFloat = 1
    ) -> Bool {
        let measured = measuredTextSize(
            text, fontSize: fontSize, width: size.width, lineCount: lineCount
        )
        return measured.complete
            && measured.width * horizontalScale <= size.width + 0.5
            && measured.height <= size.height + 0.5
    }

    private func systemFont(ofSize size: CGFloat) -> CTFont {
        CTFontCreateUIFontForLanguage(.system, size, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
    }

    private func typographicLineHeight(of font: CTFont) -> CGFloat {
        CGFloat(CTFontGetAscent(font) + CTFontGetDescent(font) + max(0, CTFontGetLeading(font)))
    }

    private func textLines(
        _ text: String, fontSize: CGFloat, width: CGFloat, lineCount: Int,
        foregroundColor: CGColor? = nil
    ) -> [NativeMirrorTextLine] {
        var attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): systemFont(ofSize: fontSize)
        ]
        if let foregroundColor {
            attributes[NSAttributedString.Key(kCTForegroundColorAttributeName as String)] = foregroundColor
        }
        let attributedString = NSAttributedString(
            string: text,
            attributes: attributes
        )
        let typesetter = CTTypesetterCreateWithAttributedString(attributedString)
        let length = attributedString.length
        guard length > 0 else { return [] }
        let maximumLines = max(1, lineCount)
        var lines: [NativeMirrorTextLine] = []
        var location = 0
        while location < length && lines.count < maximumLines {
            let lineLength: Int
            if maximumLines == 1 {
                lineLength = length - location
            } else {
                let suggested = CTTypesetterSuggestLineBreak(
                    typesetter, location, max(1, width)
                )
                lineLength = max(1, min(suggested, length - location))
            }
            let line = CTTypesetterCreateLine(
                typesetter, CFRange(location: location, length: lineLength)
            )
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            let lineWidth = CGFloat(
                CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
            )
            lines.append(NativeMirrorTextLine(
                line: line,
                range: NSRange(location: location, length: lineLength),
                width: lineWidth,
                ascent: ascent,
                descent: descent,
                leading: leading
            ))
            location += lineLength
        }
        return lines
    }

    private func measuredTextSize(
        _ text: String, fontSize: CGFloat, width: CGFloat, lineCount: Int
    ) -> NativeMirrorTextMeasurement {
        let lines = textLines(text, fontSize: fontSize, width: width, lineCount: lineCount)
        guard !lines.isEmpty else {
            return NativeMirrorTextMeasurement(width: 0, height: 0, complete: true)
        }
        let lineHeight = lines.map(\.height).max() ?? fontSize
        let complete = NSMaxRange(lines.last?.range ?? NSRange()) >= (text as NSString).length
        return NativeMirrorTextMeasurement(
            width: lines.map(\.width).max() ?? 0,
            height: lineHeight * CGFloat(lines.count),
            complete: complete
        )
    }

    private func draw(
        item: MirrorItem, layout: NativeMirrorTextLayout, in context: CGContext
    ) -> [NativeMirrorRenderedFragment] {
        let lines = textLines(
            layout.text,
            fontSize: layout.fontSize,
            width: layout.frame.width,
            lineCount: layout.lineCount,
            foregroundColor: item.foreground.nsColor.cgColor
        )
        guard !lines.isEmpty else { return [] }
        let lineHeight = lines.map(\.height).max() ?? layout.fontSize
        let totalHeight = lineHeight * CGFloat(lines.count)
        var baseline = layout.frame.midY + totalHeight / 2
        var fragments: [NativeMirrorRenderedFragment] = []
        context.saveGState()
        context.addRect(layout.frame)
        context.clip()
        context.concatenate(CGAffineTransform(
            a: layout.horizontalScale,
            b: 0,
            c: 0,
            d: 1,
            tx: layout.textOriginX * (1 - layout.horizontalScale),
            ty: 0
        ))
        for entry in lines {
            baseline -= entry.ascent
            context.textPosition = CGPoint(x: layout.textOriginX, y: baseline)
            CTLineDraw(entry.line, context)
            let lowerY = baseline - entry.descent
            var offset = entry.range.location
            let string = layout.text as NSString
            while offset < NSMaxRange(entry.range) {
                let characterRange = string.rangeOfComposedCharacterSequence(at: offset)
                let localStart = characterRange.location - entry.range.location
                let localEnd = NSMaxRange(characterRange) - entry.range.location
                let startX = CTLineGetOffsetForStringIndex(entry.line, localStart, nil)
                let endX = CTLineGetOffsetForStringIndex(entry.line, localEnd, nil)
                fragments.append(NativeMirrorRenderedFragment(
                    itemID: item.id,
                    text: string.substring(with: characterRange),
                    rect: CGRect(
                        x: layout.textOriginX + min(startX, endX) * layout.horizontalScale,
                        y: lowerY,
                        width: max(0.5, abs(endX - startX) * layout.horizontalScale),
                        height: entry.ascent + entry.descent
                    ),
                    characterOffset: fragments.count
                ))
                offset = NSMaxRange(characterRange)
            }
            baseline -= lineHeight - entry.ascent
        }
        context.restoreGState()
        return fragments
    }
}

@MainActor
final class NativeTranslationMirrorView: NSView, NSMenuItemValidation {
    var onSelectionSessionBegin: (() -> Void)?
    var onSelectionSessionEnd: (() -> Void)?
    var onCopy: (() -> Void)?
    var onMouseGestureActiveChange: ((Bool) -> Void)?
    var onOCRDebugSelection: ((OCRDebugItem) -> Void)?
    var onSearchCountChange: ((Int, String?) -> Void)?
    var ocrDebugOverlayEnabled = false
    var showsCapturedImage = true
    var fillsBackgroundOutsideImage = true
    private let renderer = NativeMirrorRenderer()
    private var renderTask: Task<Void, Never>?
    private var renderingActive = false
    private var interactiveTransform: InteractiveTransform?
    private var transformReferenceBounds: CGRect = .zero
    private var transformReferenceImageRect: CGRect = .zero
    private var transformFinished = false
    private var needsCompositeAfterLiveResize = false
    private enum InteractiveTransform {
        case resize(RegionBorderController.Edge)
        case move(CGPoint)
    }

    var frameSnapshot: MirrorFrame? {
        didSet {
            if transformFinished {
                interactiveTransform = nil
                transformReferenceBounds = .zero
                transformReferenceImageRect = .zero
                transformFinished = false
            }
            selectionAnchor = nil
            selectionFocus = nil
            if renderingActive {
                if window?.inLiveResize == true {
                    needsCompositeAfterLiveResize = true
                } else {
                    renderCurrentFrame()
                }
            }
            selectionGeometryDirty = true
            needsLayout = true
            needsDisplay = true
        }
    }

    var backgroundOpacity = MirrorBackgroundOpacity.defaultValue {
        didSet {
            guard oldValue != backgroundOpacity else { return }
            scheduleCompositeRender()
        }
    }

    private var selectionModeActive = false
    private struct SelectionFragment {
        let itemID: UUID
        let text: String
        let rect: CGRect
        let characterOffset: Int
    }
    private var selectionFragments: [SelectionFragment] = []
    private var separatorBeforeItem: [UUID: String] = [:]
    private var selectionGeometryDirty = true
    private var selectionAnchor: Int?
    private var selectionFocus: Int?
    private var pendingSelectionAnchor: Int?
    private var selectionDragStart: CGPoint?
    private var selectionExistedAtMouseDown = false
    private var selectionDragActivated = false
    private var searchQuery = ""
    private var searchCaseSensitive = false
    private var searchRegex = false
    private var searchHighlights: [CGRect] = []
    private var liveResizeCompositeImage: CGImage?

    var hasActiveSelection: Bool { selectedRange != nil }
    var isSelectionEmphasisActive: Bool { selectionModeActive }
    fileprivate var selectableFragmentCount: Int {
        rebuildSelectionFragments()
        return selectionFragments.count
    }
    fileprivate var hasNativeCompositeForTesting: Bool { renderer.image != nil }
    fileprivate var artworkBuildCountForTesting: Int { renderer.artworkBuildCount }
    fileprivate var compositeBuildCountForTesting: Int { renderer.compositeBuildCount }
    fileprivate func renderedTextRectForTesting(_ id: UUID) -> CGRect? {
        renderer.renderedTextRects[id]
    }
    fileprivate func layoutMetricsForTesting(_ id: UUID) -> (
        frame: CGRect, fontSize: CGFloat, horizontalScale: CGFloat, lineCount: Int, text: String
    )? {
        renderer.layoutMetrics(for: id)
    }
    fileprivate func renderedFragmentsForTesting(_ id: UUID) -> [NativeMirrorRenderedFragment] {
        renderer.renderedFragments.filter { $0.itemID == id }
    }
    fileprivate func selectionFragmentRectsForTesting() -> [CGRect] {
        rebuildSelectionFragments()
        return selectionFragments.map(\.rect)
    }
    fileprivate var isPresentingLiveResizeComposite: Bool { liveResizeCompositeImage != nil }
    override var isFlipped: Bool { false }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        window is TranslationOverlayPanel
    }

    func setRenderingActive(_ active: Bool) {
        guard renderingActive != active else { return }
        renderingActive = active
        if active { renderCurrentFrame() }
    }

    func beginResize(edge: RegionBorderController.Edge) {
        if case let .resize(current)? = interactiveTransform, current == edge { return }
        transformReferenceBounds = bounds
        transformReferenceImageRect = currentImageRect()
        interactiveTransform = .resize(edge)
        transformFinished = false
        selectionGeometryDirty = true
        needsDisplay = true
    }

    func moveImage(by delta: CGPoint) {
        if case .move? = interactiveTransform {
            interactiveTransform = .move(delta)
        } else {
            transformReferenceBounds = bounds
            transformReferenceImageRect = currentImageRect()
            interactiveTransform = .move(delta)
        }
        transformFinished = false
        selectionGeometryDirty = true
        needsDisplay = true
    }

    func finishInteractiveTransform() { transformFinished = true }

    func setSelectionModeActive(_ active: Bool) {
        selectionModeActive = active
        if !active {
            selectionAnchor = nil
            selectionFocus = nil
            pendingSelectionAnchor = nil
            selectionDragStart = nil
            selectionExistedAtMouseDown = false
            selectionDragActivated = false
        }
        needsDisplay = true
    }

    private func currentImageRect() -> CGRect {
        guard let frameSnapshot else { return .zero }
        return imageRect(for: CGSize(width: frameSnapshot.image.width, height: frameSnapshot.image.height))
    }

    private func imageRect(for imageSize: CGSize) -> CGRect {
        guard let transform = interactiveTransform, transformReferenceImageRect.width > 0 else {
            return aspectFitRect(contentSize: imageSize, inside: bounds)
        }
        switch transform {
        case let .move(delta):
            return transformReferenceImageRect.offsetBy(dx: -delta.x, dy: -delta.y)
        case let .resize(edge):
            let size = transformReferenceImageRect.size
            var origin = transformReferenceImageRect.origin
            switch edge {
            case .left, .topLeft, .bottomLeft: origin.x = bounds.maxX - size.width
            case .right, .topRight, .bottomRight: origin.x = bounds.minX
            case .top, .bottom: origin.x = transformReferenceBounds.midX - size.width / 2
            }
            switch edge {
            case .top, .topLeft, .topRight: origin.y = bounds.minY
            case .bottom, .bottomLeft, .bottomRight: origin.y = bounds.maxY - size.height
            case .left, .right: origin.y = transformReferenceBounds.midY - size.height / 2
            }
            return CGRect(origin: origin, size: size)
        }
    }

    override func layout() {
        super.layout()
        guard frameSnapshot != nil else { return }
        selectionGeometryDirty = true
        if selectionAnchor != nil { rebuildSelectionFragments() }
        rebuildSearchHighlights()
    }

    override func draw(_ dirtyRect: NSRect) {
        let token = PerformanceProfiler.shared.begin(
            .mirrorDraw, frameID: frameSnapshot?.frameID,
            itemCount: frameSnapshot?.translatedItems.count
        )
        defer { PerformanceProfiler.shared.end(token) }
        if showsCapturedImage && fillsBackgroundOutsideImage {
            NSColor.windowBackgroundColor.setFill()
            dirtyRect.fill()
        } else {
            NSColor.clear.setFill()
            dirtyRect.fill(using: .copy)
        }
        guard let snapshot = frameSnapshot else { return }
        let imageRect = imageRect(for: CGSize(width: snapshot.image.width, height: snapshot.image.height))
        guard imageRect.width > 0, imageRect.height > 0 else { return }
        let imageToDraw = window?.inLiveResize == true ? liveResizeCompositeImage : renderer.image
        if showsCapturedImage, let imageToDraw {
            NSImage(cgImage: imageToDraw, size: imageRect.size).draw(
                in: imageRect, from: .zero, operation: .copy, fraction: 1
            )
        }
        if ocrDebugOverlayEnabled {
            for item in snapshot.ocrDebugItems {
                let rect = mirrorItemRect(
                    normalizedRect: item.normalizedRect, imageRect: imageRect
                ).insetBy(dx: -2, dy: -1)
                ocrDebugColor(for: item.status).setStroke()
                let path = NSBezierPath(rect: rect)
                path.lineWidth = 2
                path.stroke()
            }
        }
        drawSelectionModeDim(for: snapshot, in: imageRect)
        drawSelectionHighlight()
        drawSearchHighlight()
    }

    func compositedImage() -> NSImage? {
        renderCurrentFrame()
        guard let image = renderer.image, let snapshot = frameSnapshot else { return nil }
        return NSImage(
            cgImage: image,
            size: CGSize(width: snapshot.image.width, height: snapshot.image.height)
        )
    }

    private func renderCurrentFrame() {
        guard renderingActive, let snapshot = frameSnapshot else { return }
        let token = PerformanceProfiler.shared.begin(
            .mirrorComposite, frameID: snapshot.frameID,
            itemCount: snapshot.translatedItems.count
        )
        renderer.render(frame: snapshot, backgroundOpacity: backgroundOpacity)
        PerformanceProfiler.shared.end(token)
        PerformanceProfiler.shared.increment(
            renderer.lastArtworkWasRebuilt
                ? "mirror.artworkCacheMiss" : "mirror.artworkCacheHit"
        )
        PerformanceProfiler.shared.increment("mirror.artworkLayoutCacheHit", by: renderer.layoutCacheHits)
        PerformanceProfiler.shared.increment("mirror.artworkLayoutCacheMiss", by: renderer.layoutCacheMisses)
        PerformanceProfiler.shared.increment(
            renderer.lastCompositeWasRebuilt
                ? "mirror.compositeBuild" : "mirror.compositeCacheHit"
        )
        selectionGeometryDirty = true
        needsDisplay = true
    }

    private func scheduleCompositeRender() {
        guard renderingActive, frameSnapshot != nil else { return }
        if renderTask != nil {
            PerformanceProfiler.shared.increment("mirror.compositeCoalesced")
        }
        renderTask?.cancel()
        renderTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            guard !Task.isCancelled else {
                self.renderTask = nil
                return
            }
            if self.window?.inLiveResize == true {
                self.needsCompositeAfterLiveResize = true
            } else {
                self.renderCurrentFrame()
            }
            self.renderTask = nil
        }
    }

    private func drawSelectionModeDim(for snapshot: MirrorFrame, in imageRect: CGRect) {
        guard showsCapturedImage, isSelectionEmphasisActive else { return }
        let path = NSBezierPath(rect: imageRect)
        let textRects = displayedTextRects(in: imageRect)
        for item in snapshot.translatedItems {
            let sourceRect = mirrorItemRect(normalizedRect: item.normalizedRect, imageRect: imageRect)
            let rect = item.isTranslated ? textRects[item.id] ?? sourceRect : sourceRect
            path.append(NSBezierPath(
                roundedRect: rect.insetBy(dx: -2, dy: -1), xRadius: 4, yRadius: 4
            ))
        }
        path.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.45).setFill()
        path.fill()
    }

    private func displayedTextRects(in imageRect: CGRect) -> [UUID: CGRect] {
        guard let snapshot = frameSnapshot else { return [:] }
        let nativeSize = CGSize(width: snapshot.image.width, height: snapshot.image.height)
        guard nativeSize.width > 0, nativeSize.height > 0 else { return [:] }
        return renderer.renderedTextRects.mapValues { rect in
            CGRect(
                x: imageRect.minX + rect.minX / nativeSize.width * imageRect.width,
                y: imageRect.minY + rect.minY / nativeSize.height * imageRect.height,
                width: rect.width / nativeSize.width * imageRect.width,
                height: rect.height / nativeSize.height * imageRect.height
            )
        }
    }

    private func ocrDebugColor(for status: OCRDebugStatus) -> NSColor {
        switch status {
        case .noCandidate: .systemRed
        case .lowConfidence: .systemOrange
        case .nonJapanese: .systemYellow
        case .translationPending, .translationFailed: .systemBlue
        case .success: .systemGreen
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? { makeContextMenu() }

    private func makeContextMenu(defaults: UserDefaults = .standard) -> NSMenu {
        let menu = NSMenu(title: L10n.text("미러 텍스트"))
        let selectAllItem = menu.addItem(withTitle: L10n.text("전체 선택"), action: #selector(selectAll(_:)), keyEquivalent: "")
        applyMenuShortcut(ToolbarHotKey.load(action: .selectAll, from: defaults), to: selectAllItem)
        let copyItem = menu.addItem(withTitle: L10n.text("복사"), action: #selector(copy(_:)), keyEquivalent: "")
        applyMenuShortcut(ToolbarHotKey.load(action: .copySelection, from: defaults), to: copyItem)
        let copyAndClearItem = menu.addItem(
            withTitle: L10n.text("복사 후 선택 해제"),
            action: #selector(copyAndClearSelectionFromMenu(_:)), keyEquivalent: ""
        )
        applyMenuShortcut(ToolbarHotKey.load(action: .copyAndClearSelection, from: defaults), to: copyAndClearItem)
        menu.addItem(.separator())
        let copyAllItem = menu.addItem(withTitle: L10n.text("전체 복사"), action: #selector(copyAll(_:)), keyEquivalent: "")
        applyMenuShortcut(ToolbarHotKey.load(action: .copyAll, from: defaults), to: copyAllItem)
        let clearSelectionItem = menu.addItem(withTitle: L10n.text("선택 해제"), action: #selector(clearSelection(_:)), keyEquivalent: "")
        clearSelectionItem.keyEquivalentModifierMask = []
        for item in menu.items where !item.isSeparatorItem { item.target = self }
        return menu
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(copy(_:)), #selector(copyAndClearSelectionFromMenu(_:)), #selector(clearSelection(_:)):
            return selectedRange != nil
        case #selector(selectAll(_:)), #selector(copyAll(_:)):
            return !(frameSnapshot?.translatedItems.isEmpty ?? true)
        default:
            return true
        }
    }

    private func appendSourceSelectionFragments(
        for item: MirrorItem, sourceRect: CGRect, imageRect: CGRect
    ) {
        let sourceFragments = item.sourceSelectionFragments.isEmpty
            ? item.selectionGeometrySource?.fragments() ?? []
            : item.sourceSelectionFragments
        let fragments = sourceFragments.isEmpty
            ? proportionalFragments(itemID: item.id, text: item.translatedText, in: sourceRect)
            : sourceFragments.enumerated().map { offset, fragment in
                SelectionFragment(
                    itemID: item.id, text: fragment.text,
                    rect: mirrorItemRect(normalizedRect: fragment.normalizedRect, imageRect: imageRect),
                    characterOffset: offset
                )
            }
        selectionFragments.append(contentsOf: fragments)
    }

    private func appendRenderedSelectionFragments(for item: MirrorItem, imageRect: CGRect) {
        guard let snapshot = frameSnapshot else { return }
        let nativeSize = CGSize(width: snapshot.image.width, height: snapshot.image.height)
        guard nativeSize.width > 0, nativeSize.height > 0 else { return }
        let fragments = renderer.renderedFragments.filter { $0.itemID == item.id }.map { fragment in
            SelectionFragment(
                itemID: fragment.itemID,
                text: fragment.text,
                rect: CGRect(
                    x: imageRect.minX + fragment.rect.minX / nativeSize.width * imageRect.width,
                    y: imageRect.minY + fragment.rect.minY / nativeSize.height * imageRect.height,
                    width: fragment.rect.width / nativeSize.width * imageRect.width,
                    height: fragment.rect.height / nativeSize.height * imageRect.height
                ),
                characterOffset: fragment.characterOffset
            )
        }
        selectionFragments.append(contentsOf: fragments)
    }

    private func proportionalFragments(itemID: UUID, text: String, in rect: CGRect) -> [SelectionFragment] {
        let characters = text.map(String.init)
        return characters.enumerated().map { offset, character in
            SelectionFragment(
                itemID: itemID, text: character,
                rect: proportionalCharacterRect(offset: offset, count: characters.count, in: rect),
                characterOffset: offset
            )
        }
    }

    private func proportionalCharacterRect(offset: Int, count: Int, in rect: CGRect) -> CGRect {
        let width = rect.width / CGFloat(max(1, count))
        return CGRect(x: rect.minX + CGFloat(offset) * width, y: rect.minY, width: width, height: rect.height)
    }

    private func sortSelectionFragments(using items: [MirrorItem]) {
        for index in items.indices.dropFirst() {
            let previous = items[items.index(before: index)]
            let current = items[index]
            separatorBeforeItem[current.id] = mirrorItemsShareLine(previous, current) ? " " : "\n"
        }
    }

    private func rebuildSelectionFragments() {
        guard selectionGeometryDirty, let snapshot = frameSnapshot else { return }
        selectionFragments.removeAll(keepingCapacity: true)
        separatorBeforeItem.removeAll(keepingCapacity: true)
        let imageSize = CGSize(width: snapshot.image.width, height: snapshot.image.height)
        let imageRect = imageRect(for: imageSize)
        let orderedItems = mirrorItemsInReadingOrder(snapshot.translatedItems)
        let selectableItems = showsCapturedImage ? orderedItems : orderedItems.filter(\.isTranslated)
        for item in selectableItems {
            if item.isTranslated {
                appendRenderedSelectionFragments(for: item, imageRect: imageRect)
            } else if showsCapturedImage {
                let sourceRect = mirrorPixelAlignedRect(
                    mirrorItemRect(normalizedRect: item.normalizedRect, imageRect: imageRect),
                    backingScale: window?.backingScaleFactor ?? 1
                )
                appendSourceSelectionFragments(for: item, sourceRect: sourceRect, imageRect: imageRect)
            }
        }
        sortSelectionFragments(using: selectableItems)
        selectionGeometryDirty = false
    }

    private var selectedRange: ClosedRange<Int>? {
        guard let anchor = selectionAnchor, let focus = selectionFocus, !selectionFragments.isEmpty else { return nil }
        return min(anchor, focus)...max(anchor, focus)
    }

    private func nearestFragmentIndex(to point: CGPoint) -> Int? {
        selectionFragments.indices.min { lhs, rhs in
            squaredDistance(from: point, to: selectionFragments[lhs].rect)
                < squaredDistance(from: point, to: selectionFragments[rhs].rect)
        }
    }

    private func squaredDistance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return dx * dx + dy * dy
    }

    override func mouseDown(with event: NSEvent) {
        if ocrDebugOverlayEnabled, let snapshot = frameSnapshot {
            let point = convert(event.locationInWindow, from: nil)
            let imageRect = imageRect(for: CGSize(width: snapshot.image.width, height: snapshot.image.height))
            if let item = snapshot.ocrDebugItems.reversed().first(where: {
                mirrorItemRect(normalizedRect: $0.normalizedRect, imageRect: imageRect).contains(point)
            }) {
                onOCRDebugSelection?(item)
                return
            }
        }
        window?.makeFirstResponder(self)
        rebuildSelectionFragments()
        let point = convert(event.locationInWindow, from: nil)
        selectionExistedAtMouseDown = hasActiveSelection
        selectionDragActivated = false
        pendingSelectionAnchor = nearestFragmentIndex(to: point)
        selectionDragStart = point
        onMouseGestureActiveChange?(true)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if !selectionDragActivated,
           let start = selectionDragStart,
           hypot(point.x - start.x, point.y - start.y) >= 12,
           let pendingSelectionAnchor {
            selectionAnchor = pendingSelectionAnchor
            selectionFocus = nearestFragmentIndex(to: point)
            self.pendingSelectionAnchor = nil
            selectionDragActivated = true
            if !selectionExistedAtMouseDown { beginSelectionSession() }
        } else if selectionDragActivated {
            selectionFocus = nearestFragmentIndex(to: point)
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        onMouseGestureActiveChange?(false)
        if selectionExistedAtMouseDown && !selectionDragActivated { endSelectionSession() }
        pendingSelectionAnchor = nil
        selectionDragStart = nil
        selectionExistedAtMouseDown = false
        selectionDragActivated = false
        super.mouseUp(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { clearSelection(nil) } else { super.keyDown(with: event) }
    }

    @objc override func selectAll(_ sender: Any?) {
        rebuildSelectionFragments()
        guard !selectionFragments.isEmpty else { return }
        let wasInactive = selectionAnchor == nil
        selectionAnchor = selectionFragments.startIndex
        selectionFocus = selectionFragments.index(before: selectionFragments.endIndex)
        if wasInactive { beginSelectionSession() }
        needsDisplay = true
    }

    @objc func copy(_ sender: Any?) {
        guard let text = selectedText(), !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        onCopy?()
    }

    @objc private func copyAndClearSelectionFromMenu(_ sender: Any?) { copyAndClearSelection() }
    func copyAndClearSelection() { copy(nil); clearSelection(nil) }

    @objc private func copyAll(_ sender: Any?) {
        let text = mirrorClipboardText(items: frameSnapshot?.translatedItems ?? [])
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        onCopy?()
    }

    @objc func clearSelection(_ sender: Any?) { endSelectionSession() }

    private func endSelectionSession() {
        let wasActive = selectionModeActive
        selectionModeActive = false
        selectionAnchor = nil
        selectionFocus = nil
        pendingSelectionAnchor = nil
        selectionDragStart = nil
        selectionExistedAtMouseDown = false
        selectionDragActivated = false
        needsDisplay = true
        if wasActive { onSelectionSessionEnd?() }
    }

    private func beginSelectionSession() {
        guard !selectionModeActive else { return }
        selectionModeActive = true
        needsDisplay = true
        onSelectionSessionBegin?()
    }

    private func selectedText() -> String? {
        guard let selectedRange else { return nil }
        var result = ""
        var previousItemID: UUID?
        for fragment in selectionFragments[selectedRange] {
            if let previousItemID, previousItemID != fragment.itemID {
                result.append(separatorBeforeItem[fragment.itemID] ?? "\n")
            }
            result.append(fragment.text)
            previousItemID = fragment.itemID
        }
        return result
    }

    fileprivate func selectAllTextForTesting() -> String? { selectAll(nil); return selectedText() }

    fileprivate func contextMenuStateForTesting(defaults: UserDefaults = .standard) -> [(String, Bool)] {
        makeContextMenu(defaults: defaults).items.filter { !$0.isSeparatorItem }.map {
            ($0.title, validateMenuItem($0))
        }
    }

    fileprivate func contextMenuShortcutStateForTesting(defaults: UserDefaults = .standard) -> [(String, String, NSEvent.ModifierFlags)] {
        makeContextMenu(defaults: defaults).items.filter { !$0.isSeparatorItem }.map {
            ($0.title, $0.keyEquivalent, $0.keyEquivalentModifierMask)
        }
    }

    fileprivate func finishSelectionSession() {
        guard isSelectionEmphasisActive else { return }
        endSelectionSession()
    }

    private func drawSelectionHighlight() {
        guard let selectedRange else { return }
        NSColor.selectedTextBackgroundColor.withAlphaComponent(0.62).setFill()
        for fragment in selectionFragments[selectedRange] where !fragment.text.allSatisfy(\.isWhitespace) {
            NSBezierPath(roundedRect: fragment.rect.insetBy(dx: -0.5, dy: 0), xRadius: 1, yRadius: 1).fill()
        }
    }

    func setSearch(query: String, caseSensitive: Bool, regex: Bool) {
        searchQuery = query
        searchCaseSensitive = caseSensitive
        searchRegex = regex
        rebuildSearchHighlights()
        needsDisplay = true
    }

    func clearSearch() {
        searchQuery = ""
        searchHighlights.removeAll()
        onSearchCountChange?(0, nil)
        needsDisplay = true
    }

    private func rebuildSearchHighlights() {
        guard !searchQuery.isEmpty else {
            searchHighlights.removeAll()
            onSearchCountChange?(0, nil)
            return
        }
        rebuildSelectionFragments()
        var ranges: [(range: NSRange, fragment: SelectionFragment)] = []
        let parts = selectionFragments.indices.map { index -> (text: String, separatorBefore: String?) in
            let fragment = selectionFragments[index]
            let separator = index > selectionFragments.startIndex
                && selectionFragments[index - 1].itemID != fragment.itemID
                ? (separatorBeforeItem[fragment.itemID] ?? "\n") : nil
            return (fragment.text, separator)
        }
        let text = MirrorSearchTextAssembler.text(parts: parts)
        var offset = 0
        for index in selectionFragments.indices {
            let fragment = selectionFragments[index]
            if let separator = parts[index].separatorBefore { offset += (separator as NSString).length }
            let start = offset
            offset += (fragment.text as NSString).length
            ranges.append((NSRange(location: start, length: offset - start), fragment))
        }
        switch MirrorSearchMatcher.matches(
            in: text, query: searchQuery, caseSensitive: searchCaseSensitive, regex: searchRegex
        ) {
        case .failure(let error):
            searchHighlights.removeAll()
            onSearchCountChange?(0, error.localizedDescription)
        case .success(let matches):
            searchHighlights = matches.flatMap { match in
                ranges.compactMap { entry in
                    guard NSIntersectionRange(match.range, entry.range).length > 0 else { return nil }
                    return entry.fragment.rect
                }
            }
            onSearchCountChange?(matches.count, nil)
        }
    }

    private func drawSearchHighlight() {
        guard !searchHighlights.isEmpty else { return }
        NSColor.systemYellow.withAlphaComponent(0.42).setFill()
        for rect in searchHighlights {
            NSBezierPath(roundedRect: rect.insetBy(dx: -1, dy: 0), xRadius: 1, yRadius: 1).fill()
        }
    }

    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        liveResizeCompositeImage = renderer.image
        needsDisplay = true
    }

    func finishLiveResize() {
        guard window?.inLiveResize != true else { return }
        let shouldRender = liveResizeCompositeImage != nil || needsCompositeAfterLiveResize
        liveResizeCompositeImage = nil
        needsCompositeAfterLiveResize = false
        if shouldRender { renderCurrentFrame() }
        needsDisplay = true
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        finishLiveResize()
    }
}

@MainActor
enum NativeMirrorCompositeBenchmark {
    static let defaultIterations = 120

    struct Result {
        let reportURL: URL
        let compositeP50Milliseconds: Double
        let compositeP95Milliseconds: Double
        let opacityP50Milliseconds: Double
        let opacityP95Milliseconds: Double
    }

    static func run(lineCount: Int, iterations: Int = defaultIterations) throws -> Result {
        let width = 1000
        let height = 700
        guard lineCount > 0, iterations > 0,
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            throw NSError(
                domain: "NativeMirrorCompositeBenchmark", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "네이티브 합성 벤치마크 입력 생성 실패"]
            )
        }
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else {
            throw NSError(
                domain: "NativeMirrorCompositeBenchmark", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "네이티브 합성 벤치마크 이미지 생성 실패"]
            )
        }
        let view = NativeTranslationMirrorView(
            frame: CGRect(x: 0, y: 0, width: width, height: height)
        )
        view.setRenderingActive(true)
        for iteration in 0..<8 {
            view.frameSnapshot = frame(image: image, frameID: UInt64(iteration), lineCount: lineCount)
        }

        let profiler = PerformanceProfiler.shared
        profiler.start(benchmark: true)
        profiler.setCounter("composite.benchmark.lines", value: lineCount)
        profiler.setCounter("composite.benchmark.iterations", value: iterations)
        for iteration in 0..<iterations {
            autoreleasepool {
                view.frameSnapshot = frame(
                    image: image, frameID: UInt64(iteration + 8), lineCount: lineCount
                )
            }
        }
        guard let report = profiler.stop(),
              let composite = report.stages.first(where: { $0.stage == .mirrorComposite }),
              composite.count == iterations else {
            throw NSError(
                domain: "NativeMirrorCompositeBenchmark", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "네이티브 합성 stage 반복 횟수 검증 실패"]
            )
        }
        let artworkBuildsBeforeOpacity = view.artworkBuildCountForTesting
        var opacityDurations: [Double] = []
        opacityDurations.reserveCapacity(iterations)
        for iteration in 0..<iterations {
            let started = DispatchTime.now().uptimeNanoseconds
            view.backgroundOpacity = CGFloat(iteration % 101) / 100
            _ = view.compositedImage()
            let elapsed = DispatchTime.now().uptimeNanoseconds &- started
            opacityDurations.append(Double(elapsed) / 1_000_000)
        }
        guard view.artworkBuildCountForTesting == artworkBuildsBeforeOpacity else {
            throw NSError(
                domain: "NativeMirrorCompositeBenchmark", code: 4,
                userInfo: [NSLocalizedDescriptionKey: "opacity 조작 중 artwork 재생성 검증 실패"]
            )
        }
        let reportURL = try ProfileReportWriter.save(report).json
        return Result(
            reportURL: reportURL,
            compositeP50Milliseconds: composite.p50Milliseconds,
            compositeP95Milliseconds: composite.p95Milliseconds,
            opacityP50Milliseconds: percentile(opacityDurations, 0.5),
            opacityP95Milliseconds: percentile(opacityDurations, 0.95)
        )
    }

    private static func percentile(_ values: [Double], _ percentile: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = min(
            sorted.count - 1,
            max(0, Int(ceil(Double(sorted.count) * percentile)) - 1)
        )
        return sorted[index]
    }

    private static func frame(image: CGImage, frameID: UInt64, lineCount: Int) -> MirrorFrame {
        let columns = 4
        let columnWidth = 0.235
        let horizontalGap = 0.015
        let lineHeight = 10.0 / 700.0
        let lineStep = 13.0 / 700.0
        let topInset = 10.0 / 700.0
        let items = (0..<lineCount).map { index in
            let column = index % columns
            let row = index / columns
            let x = 0.015 + CGFloat(column) * (columnWidth + horizontalGap)
            let y = 1 - topInset - CGFloat(row + 1) * lineStep
            let translated = index.isMultiple(of: 2)
            return MirrorItem(
                id: UUID(),
                translatedText: translated
                    ? "고밀도 번역문 \(index) 합성 가독성 확인"
                    : "한국어 원문 \(index)",
                presentation: translated ? .translated : .selectionOnly,
                normalizedRect: CGRect(x: x, y: y, width: columnWidth, height: lineHeight),
                background: .lightBackground, foreground: .darkText
            )
        }
        return MirrorFrame(image: image, translatedItems: items, frameID: frameID)
    }
}

#if DEBUG
@_spi(Testing)
@MainActor
public enum NativeMirrorViewTesting {
    public static func verifiesNativeCompositeAndSelection() -> Bool {
        let width = 400
        let height = 200
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let image = context.makeImage() else { return false }
        let sourceID = UUID()
        let translatedID = UUID()
        let view = NativeTranslationMirrorView(frame: CGRect(x: 0, y: 0, width: width, height: height))
        view.setRenderingActive(true)
        view.frameSnapshot = MirrorFrame(
            image: image,
            translatedItems: [
                MirrorItem(
                    id: sourceID, translatedText: "한국어", presentation: .selectionOnly,
                    normalizedRect: CGRect(x: 0.1, y: 0.65, width: 0.3, height: 0.12),
                    background: .lightBackground, foreground: .darkText,
                    sourceSelectionFragments: [
                        RecognizedTextFragment(text: "한", normalizedRect: CGRect(x: 0.1, y: 0.65, width: 0.1, height: 0.12)),
                        RecognizedTextFragment(text: "국", normalizedRect: CGRect(x: 0.2, y: 0.65, width: 0.1, height: 0.12)),
                        RecognizedTextFragment(text: "어", normalizedRect: CGRect(x: 0.3, y: 0.65, width: 0.1, height: 0.12))
                    ]
                ),
                MirrorItem(
                    id: translatedID, translatedText: "번역문", presentation: .translated,
                    normalizedRect: CGRect(x: 0.1, y: 0.4, width: 0.3, height: 0.12),
                    background: .lightBackground, foreground: .darkText
                )
            ],
            frameID: 1
        )
        let sourceRect = mirrorPixelAlignedRect(
            mirrorItemRect(
                normalizedRect: CGRect(x: 0.1, y: 0.4, width: 0.3, height: 0.12),
                imageRect: CGRect(x: 0, y: 0, width: width, height: height)
            ),
            backingScale: 1
        )
        guard view.hasNativeCompositeForTesting,
              let renderedTextRect = view.renderedTextRectForTesting(translatedID),
              renderedTextRect.height > sourceRect.height,
              view.selectableFragmentCount == 6 else { return false }
        guard view.selectAllTextForTesting() == "한국어\n번역문" else { return false }
        var searchCount = -1
        view.onSearchCountChange = { count, _ in searchCount = count }
        view.setSearch(query: "번역문", caseSensitive: true, regex: false)
        guard searchCount == 1, view.hasActiveSelection else { return false }
        let artworkBuildsBeforeOpacity = view.artworkBuildCountForTesting
        let compositesBeforeOpacity = view.compositeBuildCountForTesting
        view.backgroundOpacity = 0.4
        _ = view.compositedImage()
        return view.hasActiveSelection
            && view.hasNativeCompositeForTesting
            && view.artworkBuildCountForTesting == artworkBuildsBeforeOpacity
            && view.compositeBuildCountForTesting > compositesBeforeOpacity
    }

    public static func verifiesHorizontalCompressionAndFontScaling() -> Bool {
        let width = 1_200
        let height = 300
        let sourceHeight: CGFloat = 40
        let text = "가나다라마바사아자차카타파하거너더러머버서"
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let image = context.makeImage(),
        let probeFont = CTFontCreateUIFontForLanguage(.system, 1, nil),
        let textFont = CTFontCreateUIFontForLanguage(.system, 1, nil) else { return false }

        let probeHeight = CGFloat(
            CTFontGetAscent(probeFont)
                + CTFontGetDescent(probeFont)
                + max(0, CTFontGetLeading(probeFont))
        )
        guard probeHeight > 0 else { return false }
        let maximumFontSize = sourceHeight
            * MirrorTextLayoutTuning.maximumTextVerticalScale / probeHeight
        let scaledTextFont = CTFontCreateCopyWithAttributes(
            textFont, maximumFontSize, nil, nil
        )
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): scaledTextFont
        ]
        let attributedText = NSAttributedString(string: text, attributes: attributes)
        let line = CTLineCreateWithAttributedString(attributedText)
        let naturalWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let sourceWidth = floor(
            naturalWidth * 0.75
                - sourceHeight * MirrorTextLayoutTuning.horizontalExpansionHeightMultiplier
        )
        guard naturalWidth > 0, sourceWidth > 0 else { return false }

        let itemID = UUID()
        let item = MirrorItem(
            id: itemID,
            translatedText: text,
            presentation: .translated,
            normalizedRect: CGRect(
                x: 40 / CGFloat(width), y: 100 / CGFloat(height),
                width: sourceWidth / CGFloat(width), height: sourceHeight / CGFloat(height)
            ),
            background: .lightBackground,
            foreground: .darkText
        )
        let view = NativeTranslationMirrorView(
            frame: CGRect(x: 0, y: 0, width: width, height: height)
        )
        view.setRenderingActive(true)
        view.frameSnapshot = MirrorFrame(image: image, translatedItems: [item], frameID: 1)
        let renderedFragments = view.renderedFragmentsForTesting(itemID)
        guard let metrics = view.layoutMetricsForTesting(itemID),
              !renderedFragments.isEmpty,
              metrics.lineCount == 1,
              metrics.text == text,
              abs(metrics.horizontalScale - MirrorTextLayoutTuning.minimumHorizontalTextScale) < 0.000_001,
              metrics.fontSize < maximumFontSize - 0.1,
              renderedFragments.allSatisfy({ $0.rect.maxX <= metrics.frame.maxX + 0.5 }),
              view.selectAllTextForTesting() == text else { return false }

        let selectionRects = view.selectionFragmentRectsForTesting()
        guard selectionRects.count == renderedFragments.count else { return false }
        return zip(selectionRects, renderedFragments).allSatisfy { selectionRect, fragment in
            mirrorRectsAreVisuallyEqual(selectionRect, fragment.rect, backingScale: 1)
        }
    }

    public static func verifiesLiveResizeKeepsNativeComposite() -> Bool {
        let width = 320
        let height = 180
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let image = context.makeImage() else { return false }
        let view = NativeTranslationMirrorView(frame: CGRect(x: 0, y: 0, width: width, height: height))
        view.setRenderingActive(true)
        view.frameSnapshot = MirrorFrame(image: image, translatedItems: [], frameID: 1)
        guard view.hasNativeCompositeForTesting else { return false }
        view.viewWillStartLiveResize()
        guard view.isPresentingLiveResizeComposite else { return false }
        view.frame = CGRect(x: 0, y: 0, width: 160, height: 90)
        view.layout()
        guard view.isPresentingLiveResizeComposite, view.hasNativeCompositeForTesting else { return false }
        view.finishLiveResize()
        return !view.isPresentingLiveResizeComposite
    }
}
#endif
