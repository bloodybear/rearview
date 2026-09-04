import AppKit
import CoreText

enum OpacityPopoverMetrics {
    static let width: CGFloat = 344
    static let doubleRowHeight: CGFloat = 110
    static let fiveRowHeight: CGFloat = 176
    static let titleWidth: CGFloat = 128
    static let sliderWidth: CGFloat = 132
    static let valueWidth: CGFloat = 40
    static let edgeInset: CGFloat = 14
    static let rowSpacing: CGFloat = 6
    static let verticalSpacing: CGFloat = 10
}

let opacityControlSymbolName = "slider.horizontal.below.rectangle"

struct MirrorSearchMatch {
    let range: NSRange
}

enum MirrorSearchMatcher {
    static func matches(in text: String, query: String, caseSensitive: Bool, regex: Bool) -> Result<[MirrorSearchMatch], Error> {
        guard !query.isEmpty else { return .success([]) }
        let pattern = regex ? query : NSRegularExpression.escapedPattern(for: query)
        var options: NSRegularExpression.Options = []
        if !caseSensitive { options.insert(.caseInsensitive) }
        do {
            let expression = try NSRegularExpression(pattern: pattern, options: options)
            let range = NSRange(location: 0, length: (text as NSString).length)
            return .success(expression.matches(in: text, range: range).map { MirrorSearchMatch(range: $0.range) })
        } catch {
            return .failure(error)
        }
    }
}

enum MirrorSearchTextAssembler {
    /// Joins contiguous character fragments without manufacturing whitespace.
    static func text(parts: [(text: String, separatorBefore: String?)]) -> String {
        parts.reduce(into: "") { result, part in
            if let separator = part.separatorBefore { result.append(separator) }
            result.append(part.text)
        }
    }
}

func aspectFitRect(
    contentSize: CGSize, inside bounds: CGRect,
    resizingEdge: RegionBorderController.Edge? = nil
) -> CGRect {
    guard contentSize.width > 0, contentSize.height > 0,
          bounds.width > 0, bounds.height > 0 else { return .zero }
    let scale = min(bounds.width / contentSize.width, bounds.height / contentSize.height)
    let size = CGSize(width: contentSize.width * scale, height: contentSize.height * scale)
    var origin = CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2)
    switch resizingEdge {
    case .left, .topLeft, .bottomLeft:
        origin.x = bounds.maxX - size.width
    case .right, .topRight, .bottomRight:
        origin.x = bounds.minX
    case .top, .bottom, nil:
        break
    }
    switch resizingEdge {
    case .top, .topLeft, .topRight:
        origin.y = bounds.minY
    case .bottom, .bottomLeft, .bottomRight:
        origin.y = bounds.maxY - size.height
    case .left, .right, nil:
        break
    }
    return CGRect(origin: origin, size: size)
}

func mirrorContentFitSize(contentSize: CGSize, viewportSize: CGSize) -> CGSize {
    aspectFitRect(
        contentSize: contentSize,
        inside: CGRect(origin: .zero, size: viewportSize)
    ).size
}

func mirrorScaledContentSize(
    previousSelectionSize: CGSize,
    currentViewportSize: CGSize,
    newSelectionSize: CGSize
) -> CGSize {
    guard previousSelectionSize.width > 0, previousSelectionSize.height > 0,
          currentViewportSize.width > 0, currentViewportSize.height > 0,
          newSelectionSize.width > 0, newSelectionSize.height > 0 else {
        return newSelectionSize
    }
    let displayedSize = mirrorContentFitSize(
        contentSize: previousSelectionSize,
        viewportSize: currentViewportSize
    )
    let scale = displayedSize.width / previousSelectionSize.width
    return CGSize(
        width: (newSelectionSize.width * scale).rounded(),
        height: (newSelectionSize.height * scale).rounded()
    )
}

func mirrorFrame(
    resizing currentFrame: CGRect, to newSize: CGSize,
    from edge: RegionBorderController.Edge?
) -> CGRect {
    var newSize = newSize
    // A side drag changes only one selection dimension.  Preserve the other
    // window dimension exactly instead of feeding AppKit's content/frame
    // conversion rounding back into every drag update.
    switch edge {
    case .left, .right:
        newSize.height = currentFrame.height
    case .top, .bottom:
        newSize.width = currentFrame.width
    case .topLeft, .topRight, .bottomLeft, .bottomRight, nil:
        break
    }
    var origin = CGPoint(
        x: currentFrame.midX - newSize.width / 2,
        y: currentFrame.midY - newSize.height / 2
    )
    switch edge {
    case .left, .topLeft, .bottomLeft:
        origin.x = currentFrame.maxX - newSize.width
    case .right, .topRight, .bottomRight:
        origin.x = currentFrame.minX
    case .top, .bottom, nil:
        break
    }
    switch edge {
    case .top, .topLeft, .topRight:
        origin.y = currentFrame.minY
    case .bottom, .bottomLeft, .bottomRight:
        origin.y = currentFrame.maxY - newSize.height
    case .left, .right, nil:
        break
    }
    return CGRect(origin: origin, size: newSize)
}

func defaultMirrorContentFrame(selectionSize: CGSize, visibleFrame: CGRect) -> CGRect {
    let maximum = visibleFrame.size
    let scale = min(1, maximum.width / selectionSize.width, maximum.height / selectionSize.height)
    let size = CGSize(width: selectionSize.width * scale, height: selectionSize.height * scale)
    return CGRect(x: visibleFrame.midX - size.width / 2, y: visibleFrame.midY - size.height / 2,
                  width: min(size.width, visibleFrame.width), height: min(size.height, visibleFrame.height))
}

func mirrorNativeContentSize(imagePixelSize: CGSize, backingScale: CGFloat) -> CGSize {
    let scale = max(1, backingScale)
    return CGSize(width: imagePixelSize.width / scale, height: imagePixelSize.height / scale)
}

func mirrorZoomPercentage(contentWidth: CGFloat, nativeWidth: CGFloat) -> Int {
    guard contentWidth > 0, nativeWidth > 0 else { return 100 }
    return max(1, Int((contentWidth / nativeWidth * 100).rounded()))
}

func mirrorItemRect(normalizedRect: CGRect, imageRect: CGRect) -> CGRect {
    CGRect(
        x: imageRect.minX + normalizedRect.minX * imageRect.width,
        y: imageRect.minY + normalizedRect.minY * imageRect.height,
        width: normalizedRect.width * imageRect.width,
        height: normalizedRect.height * imageRect.height
    )
}

func mirrorPixelAlignedRect(_ rect: CGRect, backingScale: CGFloat) -> CGRect {
    let scale = max(1, backingScale)
    let minX = (rect.minX * scale).rounded() / scale
    let minY = (rect.minY * scale).rounded() / scale
    let maxX = (rect.maxX * scale).rounded() / scale
    let maxY = (rect.maxY * scale).rounded() / scale
    return CGRect(
        x: minX, y: minY,
        width: max(1 / scale, maxX - minX),
        height: max(1 / scale, maxY - minY)
    )
}

func mirrorColorsAreVisuallyEqual(_ lhs: RGBAColor?, _ rhs: RGBAColor, tolerance: CGFloat = 0.03) -> Bool {
    guard let lhs else { return false }
    return abs(lhs.red - rhs.red) <= tolerance
        && abs(lhs.green - rhs.green) <= tolerance
        && abs(lhs.blue - rhs.blue) <= tolerance
        && abs(lhs.alpha - rhs.alpha) <= tolerance
}

func mirrorRectsAreVisuallyEqual(
    _ lhs: CGRect, _ rhs: CGRect, backingScale: CGFloat, tolerancePixels: CGFloat = 1
) -> Bool {
    let tolerance = tolerancePixels / max(1, backingScale)
    return abs(lhs.minX - rhs.minX) <= tolerance
        && abs(lhs.minY - rhs.minY) <= tolerance
        && abs(lhs.maxX - rhs.maxX) <= tolerance
        && abs(lhs.maxY - rhs.maxY) <= tolerance
}

/// NSWindow stores a frame origin at the integral screen-point boundary when
/// a fractional frame is applied. Normalize a prospective window frame the
/// same way before comparing it with the frame AppKit reports back.
func mirrorWindowFrameAsStoredByAppKit(_ frame: CGRect) -> CGRect {
    CGRect(
        x: floor(frame.minX), y: floor(frame.minY),
        width: frame.width, height: frame.height
    )
}

enum MirrorTextLayoutTuning {
    static let maximumTextVerticalScale: CGFloat = 0.98
    static let backgroundVerticalExpansionFactor: CGFloat = 1.03
    static let minimumHorizontalTextScale: CGFloat = 0.75
    static let minimumFontScale: CGFloat = 0.85
    static let fontScaleSearchCount = 2
    static let horizontalExpansionHeightMultiplier: CGFloat = 2
}

func mirrorMaximumTextHeight(for sourceHeight: CGFloat) -> CGFloat {
    max(0, sourceHeight) * MirrorTextLayoutTuning.maximumTextVerticalScale
}

func mirrorHorizontalTextScale(naturalWidth: CGFloat, availableWidth: CGFloat) -> CGFloat {
    guard naturalWidth > 0 else { return 1 }
    let requiredScale = availableWidth / naturalWidth
    return min(
        1,
        max(MirrorTextLayoutTuning.minimumHorizontalTextScale, requiredScale)
    )
}

private func mirrorInitialTextExpansionRect(sourceRect: CGRect) -> CGRect {
    guard sourceRect.width > 0, sourceRect.height > 0 else { return sourceRect }
    let extra = sourceRect.height
        * max(0, MirrorTextLayoutTuning.backgroundVerticalExpansionFactor - 1) / 2
    return CGRect(
        x: sourceRect.minX,
        y: sourceRect.minY - extra,
        width: sourceRect.width,
        height: sourceRect.height + extra * 2
    )
}

func mirrorInitialTextRect(sourceRect: CGRect, inside bounds: CGRect) -> CGRect {
    mirrorInitialTextExpansionRect(sourceRect: sourceRect).intersection(bounds)
}

func mirrorRectsOverlap(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
    lhs.width > 0 && lhs.height > 0 && rhs.width > 0 && rhs.height > 0
        && lhs.minX < rhs.maxX && lhs.maxX > rhs.minX
        && lhs.minY < rhs.maxY && lhs.maxY > rhs.minY
}

func mirrorTextCollisionRects(for frame: CGRect, sourceRect: CGRect) -> [CGRect] {
    guard frame.width > 0, frame.height > 0, sourceRect.height > 0 else { return [frame] }
    let initialRect = mirrorInitialTextExpansionRect(sourceRect: sourceRect)
    var result = [CGRect(
        x: frame.minX, y: sourceRect.minY,
        width: frame.width, height: sourceRect.height
    )]
    if frame.minY < initialRect.minY {
        result.append(CGRect(
            x: frame.minX, y: frame.minY,
            width: frame.width, height: initialRect.minY - frame.minY
        ))
    }
    if frame.maxY > initialRect.maxY {
        result.append(CGRect(
            x: frame.minX, y: initialRect.maxY,
            width: frame.width, height: frame.maxY - initialRect.maxY
        ))
    }
    return result.filter { $0.width > 0 && $0.height > 0 }
}

private func mirrorVerticalOverlap(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
    lhs.minY < rhs.maxY && lhs.maxY > rhs.minY
}

func mirrorOneLineTextRect(
    sourceRect: CGRect, requiredWidth: CGFloat, otherRects: [CGRect],
    reservedCollisionRects: [CGRect], inside bounds: CGRect, sourceIndex: Int
) -> CGRect {
    guard sourceRect.width > 0, sourceRect.height > 0 else { return sourceRect }
    let obstacles = otherRects.enumerated().compactMap { index, rect in
        index == sourceIndex ? nil : rect
    } + reservedCollisionRects
    var rightLimit = bounds.maxX
    var leftLimit = bounds.minX
    for obstacle in obstacles where mirrorVerticalOverlap(obstacle, sourceRect) {
        if obstacle.minX >= sourceRect.maxX {
            rightLimit = min(rightLimit, obstacle.minX)
        } else if obstacle.maxX <= sourceRect.minX {
            leftLimit = max(leftLimit, obstacle.maxX)
        }
    }

    let maximumWidth = sourceRect.width
        + sourceRect.height * MirrorTextLayoutTuning.horizontalExpansionHeightMultiplier
    let targetWidth = min(max(sourceRect.width, requiredWidth), maximumWidth)
    let desiredExtra = max(0, targetWidth - sourceRect.width)
    let availableRight = max(0, rightLimit - sourceRect.maxX)
    let availableLeft = max(0, sourceRect.minX - leftLimit)
    let rightExtra = min(desiredExtra, availableRight)
    let leftExtra = min(desiredExtra - rightExtra, availableLeft)
    return CGRect(
        x: sourceRect.minX - leftExtra,
        y: mirrorInitialTextRect(sourceRect: sourceRect, inside: bounds).minY,
        width: sourceRect.width + leftExtra + rightExtra,
        height: mirrorInitialTextRect(sourceRect: sourceRect, inside: bounds).height
    ).intersection(bounds)
}

func mirrorItemsShareLine(_ lhs: MirrorItem, _ rhs: MirrorItem) -> Bool {
    guard lhs.normalizedRect.height > 0, rhs.normalizedRect.height > 0 else { return false }
    let overlap = max(
        0, min(lhs.normalizedRect.maxY, rhs.normalizedRect.maxY)
            - max(lhs.normalizedRect.minY, rhs.normalizedRect.minY)
    )
    return overlap >= min(lhs.normalizedRect.height, rhs.normalizedRect.height) * 0.4
}

func mirrorItemsInReadingOrder(_ items: [MirrorItem]) -> [MirrorItem] {
    var lines: [[MirrorItem]] = []
    for item in items.sorted(by: { $0.normalizedRect.midY > $1.normalizedRect.midY }) {
        if let index = lines.firstIndex(where: { line in
            line.contains(where: { mirrorItemsShareLine($0, item) })
        }) {
            lines[index].append(item)
        } else {
            lines.append([item])
        }
    }
    lines.sort {
        ($0.map(\.normalizedRect.midY).max() ?? 0) > ($1.map(\.normalizedRect.midY).max() ?? 0)
    }
    return lines.flatMap { $0.sorted { $0.normalizedRect.minX < $1.normalizedRect.minX } }
}

func mirrorClipboardText(items: [MirrorItem]) -> String {
    let ordered = mirrorItemsInReadingOrder(items)
    var result = ""
    for (index, item) in ordered.enumerated() {
        if index > 0 { result.append(mirrorItemsShareLine(ordered[index - 1], item) ? " " : "\n") }
        result.append(item.translatedText)
    }
    return result
}

enum MirrorProcessingStatus: Equatable {
    case recognizing
    case translating(completed: Int, total: Int)
    case completed(failures: Int)
    case recognitionFailed

    var title: String {
        switch self {
        case .recognizing:
            L10n.text("텍스트 인식 중")
        case .translating(let completed, let total):
            L10n.format("번역 중 %d/%d", completed, total)
        case .completed(let failures):
            failures == 0
                ? L10n.text("완료")
                : L10n.format("완료 · %d줄 실패", failures)
        case .recognitionFailed:
            L10n.text("텍스트 인식 실패")
        }
    }

    var isProcessing: Bool {
        switch self {
        case .recognizing, .translating: true
        case .completed, .recognitionFailed: false
        }
    }
}

enum MirrorStatusOrigin: Equatable, Sendable {
    case automatic
    case userAction
}

@MainActor
private final class MirrorStatusCapsule: NSVisualEffectView {
    private let spinner = NSProgressIndicator()
    private let resultIcon = NSImageView()
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 9

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        resultIcon.translatesAutoresizingMaskIntoConstraints = false
        resultIcon.contentTintColor = .labelColor
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail

        let stack = NSStackView(views: [spinner, resultIcon, label])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            spinner.widthAnchor.constraint(equalToConstant: 14),
            spinner.heightAnchor.constraint(equalToConstant: 14),
            resultIcon.widthAnchor.constraint(equalToConstant: 14),
            resultIcon.heightAnchor.constraint(equalToConstant: 14),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
            // The save confirmation includes the full default filename
            // (date, time, counter, and extension) and should remain readable.
            widthAnchor.constraint(lessThanOrEqualToConstant: 340)
        ])
        isHidden = true
        alphaValue = 0
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ status: MirrorProcessingStatus) {
        if status.isProcessing {
            show(title: status.title, isProcessing: true)
        } else {
            let symbol = status == .recognitionFailed ? "exclamationmark.circle.fill" : "checkmark.circle.fill"
            show(title: status.title, symbol: symbol)
        }
    }

    func show(title: String, symbol: String) {
        show(title: title, isProcessing: false, symbol: symbol)
    }

    private func show(title: String, isProcessing: Bool, symbol: String? = nil) {
        label.stringValue = title
        spinner.isHidden = !isProcessing
        resultIcon.isHidden = isProcessing
        if isProcessing {
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
            resultIcon.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: title) }
        }
        setAccessibilityLabel(title)
        isHidden = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            animator().alphaValue = 1
        }
    }

    func hide(animated: Bool) {
        spinner.stopAnimation(nil)
        guard animated else {
            alphaValue = 0
            isHidden = true
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in self?.isHidden = true }
        })
    }
}

@MainActor
private final class MirrorSaveRevealButton: NSButton {
    var onReveal: (() -> Void)?
    private var trackingAreaReference: NSTrackingArea?
    private var isPointerInside = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        layer?.borderColor = NSColor.white.withAlphaComponent(0.24).cgColor
        layer?.borderWidth = 1

        let label = L10n.text("Finder에서 파일 보기")
        image = NSImage(systemSymbolName: "folder", accessibilityDescription: label)
        imagePosition = .imageOnly
        isBordered = false
        contentTintColor = .white
        toolTip = label
        setAccessibilityLabel(label)
        target = self
        action = #selector(reveal)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 28).isActive = true
        heightAnchor.constraint(equalToConstant: 28).isActive = true
        isHidden = true
    }

    required init?(coder: NSCoder) { nil }

    override func updateTrackingAreas() {
        if let trackingAreaReference { removeTrackingArea(trackingAreaReference) }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(trackingArea)
        trackingAreaReference = trackingArea
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        isPointerInside = true
        updateHoverAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        isPointerInside = false
        updateHoverAppearance()
    }

    private func updateHoverAppearance() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            layer?.borderColor = NSColor.white.withAlphaComponent(
                isPointerInside ? 0.72 : 0.24
            ).cgColor
            layer?.backgroundColor = NSColor.black.withAlphaComponent(
                isPointerInside ? 0.82 : 0.72
            ).cgColor
        }
    }

    @objc private func reveal() { onReveal?() }
}

@MainActor
private final class OverlayPassThroughContentView: NSView {
    weak var interactiveView: NSView?
    weak var backgroundInteractiveView: NSView?
    var allowsBackgroundInteraction = false

    override func hitTest(_ point: NSPoint) -> NSView? {
        if let interactiveView, !interactiveView.isHidden {
            let pointInTarget = interactiveView.convert(point, from: self)
            if interactiveView.bounds.contains(pointInTarget) {
                return interactiveView
            }
        }
        guard allowsBackgroundInteraction,
              let backgroundInteractiveView,
              !backgroundInteractiveView.isHidden else { return nil }
        let pointInTarget = backgroundInteractiveView.convert(point, from: self)
        return backgroundInteractiveView.hitTest(pointInTarget)
    }
}

@MainActor
private final class MirrorPauseBadge: NSVisualEffectView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: L10n.text("일시정지"))

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 10

        icon.image = NSImage(
            systemSymbolName: "pause.fill",
            accessibilityDescription: L10n.text("일시정지")
        )
        icon.contentTintColor = .systemOrange
        icon.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .labelColor

        let stack = NSStackView(views: [icon, label])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 12),
            icon.heightAnchor.constraint(equalToConstant: 12),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6)
        ])
        setAccessibilityLabel(L10n.text("자동 갱신 일시정지"))
        isHidden = true
    }

    required init?(coder: NSCoder) { nil }

    func refreshLocalization() {
        label.stringValue = L10n.text("일시정지")
        icon.image = NSImage(
            systemSymbolName: "pause.fill",
            accessibilityDescription: L10n.text("일시정지")
        )
        setAccessibilityLabel(L10n.text("자동 갱신 일시정지"))
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
private final class MirrorZoomBadge: NSVisualEffectView {
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 10

        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .labelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 58)
        ])
        isHidden = true
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(percentage: Int) {
        label.stringValue = "\(percentage)%"
        setAccessibilityLabel(L10n.format("미러 확대 비율 %d%%", percentage))
        isHidden = false
    }

    func hide() { isHidden = true }
}

@MainActor
private final class MirrorSearchField: NSSearchField {
    var onEscape: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

@MainActor
private final class MirrorSearchBar: NSVisualEffectView {
    let field = MirrorSearchField()
    let caseSensitiveButton = NSButton(
        checkboxWithTitle: L10n.text("대소문자"), target: nil, action: nil
    )
    let regexButton = NSButton(checkboxWithTitle: "Regex", target: nil, action: nil)
    let countLabel = NSTextField(labelWithString: "")
    let closeButton = NSButton(title: "", target: nil, action: nil)
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .hudWindow; blendingMode = .withinWindow; state = .active
        wantsLayer = true; layer?.cornerRadius = 8
        field.placeholderString = L10n.text("미러 텍스트 검색")
        closeButton.image = NSImage(
            systemSymbolName: "xmark",
            accessibilityDescription: L10n.text("검색 닫기")
        )
        closeButton.isBordered = false
        countLabel.textColor = .secondaryLabelColor
        countLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        let stack = NSStackView(views: [field, caseSensitiveButton, regexButton, countLabel, closeButton])
        stack.orientation = .horizontal; stack.alignment = .centerY; stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        [field, caseSensitiveButton, regexButton, countLabel, closeButton].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
            closeButton.widthAnchor.constraint(equalToConstant: 22)
        ])
        isHidden = true
    }
    required init?(coder: NSCoder) { nil }

    func refreshLocalization() {
        caseSensitiveButton.title = L10n.text("대소문자")
        field.placeholderString = L10n.text("미러 텍스트 검색")
        closeButton.image = NSImage(
            systemSymbolName: "xmark",
            accessibilityDescription: L10n.text("검색 닫기")
        )
    }
}

@MainActor
private final class OverlaySearchPanel: NSPanel {
    let searchBar = MirrorSearchBar()
    private var selectionFrame: CGRect
    private var visibleFrame: CGRect

    init(selection: CGRect) {
        selectionFrame = selection
        visibleFrame = NSScreen.screens.first(where: { $0.frame.intersects(selection) })?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? selection
        super.init(
            contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false
        )
        level = RegionWindowLevel.controlBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        collectionBehavior = [.fullScreenAuxiliary, .stationary]
        searchBar.translatesAutoresizingMaskIntoConstraints = false
        contentView = NSView()
        contentView?.addSubview(searchBar)
        NSLayoutConstraint.activate([
            searchBar.leadingAnchor.constraint(equalTo: contentView!.leadingAnchor),
            searchBar.trailingAnchor.constraint(equalTo: contentView!.trailingAnchor),
            searchBar.topAnchor.constraint(equalTo: contentView!.topAnchor),
            searchBar.bottomAnchor.constraint(equalTo: contentView!.bottomAnchor)
        ])
        updateFrame(display: false)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func show() {
        updateFrame(display: false)
        orderFrontRegardless()
    }

    func hide() { orderOut(nil) }

    func setSelectionFrame(_ rect: CGRect) {
        selectionFrame = rect
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(rect) }) {
            visibleFrame = screen.visibleFrame
        }
        updateFrame(display: isVisible)
    }

    private func updateFrame(display: Bool) {
        let horizontalMargin: CGFloat = 8
        let verticalMargin: CGFloat = 10
        let size = CGSize(
            width: min(440, max(1, visibleFrame.width - horizontalMargin * 2)), height: 36
        )
        let x = min(
            max(selectionFrame.midX - size.width / 2, visibleFrame.minX + horizontalMargin),
            visibleFrame.maxX - size.width - horizontalMargin
        )
        let y = min(
            max(selectionFrame.maxY - size.height - verticalMargin, visibleFrame.minY + horizontalMargin),
            visibleFrame.maxY - size.height - horizontalMargin
        )
        setFrame(NSRect(origin: CGPoint(x: x, y: y), size: size), display: display)
    }
}

@MainActor
final class TranslationOverlayPanel: NSPanel {
    let translationView = NativeTranslationMirrorView()
    private let statusCapsule = MirrorStatusCapsule()
    private let statusStack = NSStackView()
    private let saveRevealButton = MirrorSaveRevealButton()
    private let pauseBadge = MirrorPauseBadge()
    private let container = OverlayPassThroughContentView()
    private var selectionModeEnabled = false
    private var ignoresSelectionMouseEvents: Bool
    private var mouseGestureActive = false
    private var inactiveOpacity: CGFloat
    private var activeOpacity: CGFloat

    var onSelectionSessionBegin: (() -> Void)?
    var onCopy: (() -> Void)?

    init(
        selection: CGRect, inactiveOpacity: CGFloat, activeOpacity: CGFloat,
        ignoresMouseEvents: Bool
    ) {
        ignoresSelectionMouseEvents = ignoresMouseEvents
        self.inactiveOpacity = OverlayOpacity.clamp(inactiveOpacity)
        self.activeOpacity = OverlayActiveOpacity.clamp(activeOpacity)
        super.init(
            contentRect: selection, styleMask: [.borderless],
            backing: .buffered, defer: false
        )
        // RegionBorderController's always-interactive edge panels stay above
        // the overlay so its borders can resize the selected region directly.
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        collectionBehavior = [.fullScreenAuxiliary, .stationary]
        self.ignoresMouseEvents = true
        alphaValue = NSApp.isActive ? self.activeOpacity : self.inactiveOpacity

        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor
        translationView.showsCapturedImage = true
        translationView.fillsBackgroundOutsideImage = false
        translationView.backgroundOpacity = 1
        translationView.translatesAutoresizingMaskIntoConstraints = false
        statusCapsule.translatesAutoresizingMaskIntoConstraints = false
        pauseBadge.translatesAutoresizingMaskIntoConstraints = false
        statusStack.orientation = .horizontal
        statusStack.alignment = .centerY
        statusStack.spacing = 4
        statusStack.translatesAutoresizingMaskIntoConstraints = false
        statusStack.addArrangedSubview(statusCapsule)
        statusStack.addArrangedSubview(saveRevealButton)
        container.interactiveView = saveRevealButton
        container.backgroundInteractiveView = translationView
        container.addSubview(translationView)
        container.addSubview(statusStack)
        container.addSubview(pauseBadge)
        NSLayoutConstraint.activate([
            translationView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            translationView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            translationView.topAnchor.constraint(equalTo: container.topAnchor),
            translationView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            statusStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
            statusStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            pauseBadge.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
            pauseBadge.centerXAnchor.constraint(equalTo: container.centerXAnchor)
        ])
        contentView = container
        translationView.onSelectionSessionBegin = { [weak self] in self?.onSelectionSessionBegin?() }
        translationView.onCopy = { [weak self] in self?.onCopy?() }
        translationView.onMouseGestureActiveChange = { [weak self] active in
            self?.mouseGestureActive = active
            self?.updateInteraction()
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(updateOpacityForApplicationState),
            name: NSApplication.didBecomeActiveNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(updateOpacityForApplicationState),
            name: NSApplication.didResignActiveNotification, object: nil
        )
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func refreshInteractionState() {
        updateInteraction()
    }

    func resetInteractionState() {
        mouseGestureActive = false
        container.allowsBackgroundInteraction = false
        ignoresMouseEvents = true
    }

    func setSelectionModeEnabled(_ enabled: Bool) {
        selectionModeEnabled = enabled
        updateInteraction()
    }

    func setIgnoresSelectionMouseEvents(_ enabled: Bool) {
        ignoresSelectionMouseEvents = enabled
        updateInteraction()
    }

    func setOverlayOpacities(inactive: CGFloat, active: CGFloat) {
        inactiveOpacity = OverlayOpacity.clamp(inactive)
        activeOpacity = OverlayActiveOpacity.clamp(active)
        updateOpacityForApplicationState()
    }

    @objc private func updateOpacityForApplicationState() {
        alphaValue = NSApp.isActive ? activeOpacity : inactiveOpacity
    }

    func setSelectionFrame(_ selection: CGRect) {
        setFrame(selection, display: true)
    }


    func display(_ frame: MirrorFrame) {
        translationView.frameSnapshot = frame
        translationView.needsDisplay = true
    }

    func showStatus(_ status: MirrorProcessingStatus) { statusCapsule.show(status) }
    func showStatus(title: String, symbol: String) { statusCapsule.show(title: title, symbol: symbol) }
    func hideStatus(animated: Bool) { statusCapsule.hide(animated: animated) }
    func showSaveRevealButton(_ visible: Bool, onReveal: (() -> Void)? = nil) {
        saveRevealButton.onReveal = onReveal
        saveRevealButton.isHidden = !visible
        updateInteraction()
    }
    func setPaused(_ paused: Bool) { pauseBadge.isHidden = !paused }

    func refreshLocalization() { pauseBadge.refreshLocalization() }

    private func updateInteraction() {
        let allowsTranslationInteraction = mouseGestureActive || overlayAcceptsMouseEvents(
            selectionModeEnabled: selectionModeEnabled,
            ignoresMouseEvents: ignoresSelectionMouseEvents
        )
        container.allowsBackgroundInteraction = allowsTranslationInteraction
        ignoresMouseEvents = !(saveRevealButton.isHidden == false || allowsTranslationInteraction)

    }
}

#if DEBUG
@_spi(Testing)
@MainActor
public enum OverlayPanelTesting {
    public static func verifiesInteractionRouting() -> Bool {
        let panel = TranslationOverlayPanel(
            selection: CGRect(x: 0, y: 0, width: 320, height: 180),
            inactiveOpacity: 1,
            activeOpacity: 1,
            ignoresMouseEvents: true
        )
        defer { panel.close() }
        guard let contentView = panel.contentView else { return false }
        contentView.layoutSubtreeIfNeeded()
        let center = CGPoint(x: contentView.bounds.midX, y: contentView.bounds.midY)

        guard panel.ignoresMouseEvents,
              contentView.hitTest(center) == nil else { return false }

        panel.setIgnoresSelectionMouseEvents(false)
        contentView.layoutSubtreeIfNeeded()
        guard !panel.ignoresMouseEvents,
              contentView.hitTest(center) === panel.translationView else { return false }

        panel.setIgnoresSelectionMouseEvents(true)
        panel.showStatus(title: "Saved", symbol: "checkmark.circle.fill")
        panel.showSaveRevealButton(true)
        contentView.layoutSubtreeIfNeeded()
        guard !panel.ignoresMouseEvents,
              contentView.hitTest(center) == nil else { return false }

        let buttonPoint = CGPoint(x: contentView.bounds.maxX - 26, y: 26)
        guard let hit = contentView.hitTest(buttonPoint),
              let button = hit as? NSButton,
              button.acceptsFirstMouse(for: nil) else { return false }
        var didReveal = false
        panel.showSaveRevealButton(true) { didReveal = true }
        button.performClick(nil)
        return didReveal
    }
}
#endif

@MainActor
fileprivate final class MirrorDockPreviewPanel: NSPanel {
    private let previewView = MirrorDockPreviewView()
    private var hideGeneration = 0
    private var hideCompletionTimer: Timer?

    init() {
        super.init(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        level = RegionWindowLevel.visual
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        collectionBehavior = [.fullScreenAuxiliary, .stationary]
        contentView = previewView
    }

    required init?(coder: NSCoder) { nil }

    /// Shows the ghost of the mirror window at the placement it will dock to,
    /// connected to the selection by the same seam the docked window uses.
    /// The ghost is drawn as a solid target in the region border color.
    func show(
        placement: CGRect, state: MirrorDockingState, selection: CGRect,
        color: NSColor, borderOutset: CGFloat, borderShadowReach: CGFloat,
        chromeHeight: CGFloat, bottomChromeHeight: CGFloat = 0
    ) {
        hideGeneration += 1
        hideCompletionTimer?.invalidate()
        hideCompletionTimer = nil
        let wasVisible = isVisible
        let padding = RegionBorderTuning.moveHandleShadowPadding
        var content = placement
        if let seam = mirrorDockingSeamRect(
            placement: placement, state: state, selection: selection,
            borderOutset: borderOutset, borderShadowReach: borderShadowReach,
            chromeHeight: chromeHeight, bottomChromeHeight: bottomChromeHeight
        ) {
            content = content.union(seam)
        }
        let panelFrame = content.insetBy(dx: -padding, dy: -padding)
        previewView.placement = placement.offsetBy(dx: -panelFrame.minX, dy: -panelFrame.minY)
        previewView.selection = selection.offsetBy(dx: -panelFrame.minX, dy: -panelFrame.minY)
        previewView.dockingState = state
        previewView.color = color
        previewView.borderOutset = borderOutset
        previewView.borderShadowReach = borderShadowReach
        previewView.chromeHeight = chromeHeight
        previewView.bottomChromeHeight = bottomChromeHeight
        setFrame(panelFrame, display: true)
        if wasVisible {
            // A hide animation may still be running when the pointer quickly
            // re-enters the docking zone. Cancel that transition and restore
            // the preview immediately instead of leaving an invisible panel
            // whose stale hide completion can no longer order it out.
            alphaValue = 1
            orderFrontRegardless()
            return
        }
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            animator().alphaValue = 1
        }
    }

    func hide() {
        hideGeneration += 1
        let generation = hideGeneration
        hideCompletionTimer?.invalidate()
        hideCompletionTimer = nil
        guard isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            animator().alphaValue = 0
        })
        // AppKit may skip a second animation completion after an interrupted
        // alpha transition, so complete the visibility transition from the
        // main run loop as well as the visual animation.
        let timer = Timer(
            timeInterval: 0.12, target: self,
            selector: #selector(completeHide(_:)),
            userInfo: generation, repeats: false
        )
        hideCompletionTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func completeHide(_ timer: Timer) {
        guard let generation = timer.userInfo as? Int,
              hideGeneration == generation else { return }
        hideCompletionTimer = nil
        orderOut(nil)
        alphaValue = 1
    }
}

#if DEBUG
@_spi(Testing)
@MainActor
public enum MirrorDockPreviewTesting {
    public static func verifiesRapidReentry() -> Bool {
        let panel = MirrorDockPreviewPanel()
        defer {
            panel.orderOut(nil)
            panel.close()
        }

        let placement = CGRect(x: 305, y: 100, width: 100, height: 100)
        let selection = CGRect(x: 100, y: 100, width: 200, height: 100)
        let parameters = (
            placement: placement,
            state: MirrorDockingState.right,
            selection: selection,
            color: NSColor.systemBlue,
            borderOutset: CGFloat(0),
            borderShadowReach: CGFloat(0),
            chromeHeight: CGFloat(40)
        )

        panel.show(
            placement: parameters.placement, state: parameters.state,
            selection: parameters.selection, color: parameters.color,
            borderOutset: parameters.borderOutset,
            borderShadowReach: parameters.borderShadowReach,
            chromeHeight: parameters.chromeHeight
        )
        guard panel.isVisible else { return false }

        panel.hide()
        guard panel.isVisible else { return false }

        panel.show(
            placement: parameters.placement, state: parameters.state,
            selection: parameters.selection, color: parameters.color,
            borderOutset: parameters.borderOutset,
            borderShadowReach: parameters.borderShadowReach,
            chromeHeight: parameters.chromeHeight
        )
        guard panel.isVisible, panel.alphaValue > 0.99 else { return false }

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        guard panel.isVisible, panel.alphaValue > 0.99 else { return false }

        panel.hide()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        return !panel.isVisible
    }
}
#endif

@MainActor
private final class MirrorDockPreviewView: NSView {
    var placement: CGRect = .zero { didSet { needsDisplay = true } }
    var selection: CGRect = .zero { didSet { needsDisplay = true } }
    var dockingState: MirrorDockingState = .undocked { didSet { needsDisplay = true } }
    var color: NSColor = .controlAccentColor { didSet { needsDisplay = true } }
    var borderOutset: CGFloat = 0 { didSet { needsDisplay = true } }
    var borderShadowReach: CGFloat = 0 { didSet { needsDisplay = true } }
    var chromeHeight: CGFloat = 0 { didSet { needsDisplay = true } }
    var bottomChromeHeight: CGFloat = 0 { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        guard placement.width > 0, placement.height > 0 else { return }
        RegionBorderDrawing.drawSolidGhost(frame: placement, color: color, in: bounds)
        if let seam = mirrorDockingSeamRect(
            placement: placement, state: dockingState, selection: selection,
            borderOutset: borderOutset, borderShadowReach: borderShadowReach,
            chromeHeight: chromeHeight, bottomChromeHeight: bottomChromeHeight
        ) {
            RegionBorderDrawing.drawSeam(
                band: seam, direction: dockingState,
                color: color,
                bandAlpha: RegionBorderTuning.seamBandAlpha,
                lineAlpha: RegionBorderTuning.seamLineAlpha
            )
        }
    }
}

@MainActor
final class TranslationMirrorWindow: NSPanel, NSWindowDelegate {
    private let mirrorView = NativeTranslationMirrorView()
    private let overlayPanel: TranslationOverlayPanel
    private let overlaySearchPanel: OverlaySearchPanel
    private let overlayControlBar: OverlayControlBarController
    private let mirrorControlBar: OverlayControlBarController
    private let statusCapsule = MirrorStatusCapsule()
    private let statusStack = NSStackView()
    private let saveRevealButton = MirrorSaveRevealButton()
    private let pauseBadge = MirrorPauseBadge()
    private let zoomBadge = MirrorZoomBadge()
    private let searchBar = MirrorSearchBar()
    private let ocrInspector = NSTextField(wrappingLabelWithString: "")
    private lazy var mirrorControlBarAccessory = MirrorControlBarAccessoryController(
        controlBar: mirrorControlBar, window: self
    )
    private var controlBars: [OverlayControlBarController] {
        [overlayControlBar, mirrorControlBar]
    }
    private var originalContentSize: CGSize
    private var latestImagePixelSize: CGSize?
    private var hasAppliedNativeContentSize = false
    private var statusFrameID: UInt64?
    private var statusDismissal: Task<Void, Never>?
    private var transientStatusDismissal: Task<Void, Never>?
    private var zoomBadgeDismissal: Task<Void, Never>?
    private var currentProcessingStatus: MirrorProcessingStatus?
    private var isProcessingStatusVisible = false
    private var isTransientStatusVisible = false
    private var transientStatusTitle = L10n.text("복사됨")
    private var transientSavedURL: URL?
    private var displayMode: TranslationDisplayMode
    private var translationDirection = TranslationDirection.load()
    private var selectionModeActive = false
    private var overlaySettings: OverlayPresentationSettings
    private var overlayOpacity: CGFloat { overlaySettings.inactiveContentOpacity }
    private var activeOverlayOpacity: CGFloat { overlaySettings.activeContentOpacity }
    private var selectionFrame: CGRect
    private var dockingState: MirrorDockingState
    private var dockingAnchor: MirrorDockingAnchor?
    private var isApplyingDockingFrame = false
    private let dockPreview = MirrorDockPreviewPanel()
    private var wasDraggingWindow = false
    private var dragReleaseTimer: Timer?
    /// The drag-time dock preview follows the region border color, which
    /// varies with the refresh mode and pause state.
    private var dockPreviewColor: NSColor = regionPresentationColor(for: .automatic)

    private struct DockedFramePlacement {
        let frame: CGRect
        let anchor: MirrorDockingAnchor
    }

    var onUserClose: (() -> Void)?
    var onDockingStateChange: ((MirrorDockingState) -> Void)?
    var onDockingGeometryChange: ((MirrorDockingState, CGRect?) -> Void)?
    var onBackgroundOpacityChange: ((CGFloat) -> Void)?
    var onOverlayPresentationChange: ((OverlayPresentationSettings) -> Void)?
    var onDisplayModeChange: ((TranslationDisplayMode) -> Void)?
    var onTranslationDirectionChange: ((TranslationDirection) -> Void)?
    var onNonSourceTextProtectionChange: ((Bool) -> Void)?
    var onFollowSelectionSizeChange: ((Bool) -> Void)?
    var onApplicationCaptureChange: ((CaptureApplication?) -> Void)?
    var onApplicationListRequest: (() -> Void)?
    var onRefreshModeChange: ((RefreshMode) -> Void)?
    var onPauseChange: ((Bool) -> Void)?
    var onImmediateTranslation: (() -> Void)?
    var onOverlaySelectionDrag: ((CGRect, NSScreen, RegionBorderController.Change, Bool) -> Void)?
    var onOverlayControlBarGeometryChange: ((CGRect?, OverlayControlBarDocking?) -> Void)? {
        didSet {
            if displayMode == .overlay {
                onOverlayControlBarGeometryChange?(
                    overlayControlBar.frame, overlayControlBar.currentDocking
                )
            } else {
                onOverlayControlBarGeometryChange?(nil, nil)
            }
        }
    }
    var onTextSelectionBegin: (() -> Void)?
    var onOpenSettings: (() -> Void)?

    init(
        selection: CGRect, screen: NSScreen, backgroundOpacity: CGFloat,
        displayMode: TranslationDisplayMode,
        overlaySettings: OverlayPresentationSettings,
        initialDockingState: MirrorDockingState = .undocked
    ) {
        originalContentSize = selection.size
        selectionFrame = selection
        self.displayMode = displayMode
        self.overlaySettings = overlaySettings.normalized()
        dockingState = initialDockingState
        dockingAnchor = initialDockingState == .undocked
            ? nil
            : .alignment(MirrorDockAlignment.shortcutDefault(for: initialDockingState))
        overlayPanel = TranslationOverlayPanel(
            selection: selection,
            inactiveOpacity: self.overlaySettings.inactiveContentOpacity,
            activeOpacity: self.overlaySettings.activeContentOpacity,
            ignoresMouseEvents: self.overlaySettings.ignoresMouseEvents
        )
        overlaySearchPanel = OverlaySearchPanel(selection: selection)
        overlayControlBar = OverlayControlBarController(
            selection: selection,
            screen: screen,
            displayMode: displayMode,
            overlayOpacity: self.overlaySettings.inactiveContentOpacity,
            translationBackgroundOpacity: backgroundOpacity,
            controlBarOpacity: self.overlaySettings.inactiveControlBarOpacity,
            activeOverlayOpacity: self.overlaySettings.activeContentOpacity,
            activeControlBarOpacity: self.overlaySettings.activeControlBarOpacity,
            regionBorderOpacity: self.overlaySettings.regionBorderOpacity,
            ignoresMouseEvents: self.overlaySettings.ignoresMouseEvents
        )
        mirrorControlBar = OverlayControlBarController(
            selection: selection,
            screen: screen,
            displayMode: displayMode,
            overlayOpacity: self.overlaySettings.inactiveContentOpacity,
            translationBackgroundOpacity: backgroundOpacity,
            controlBarOpacity: self.overlaySettings.inactiveControlBarOpacity,
            activeOverlayOpacity: self.overlaySettings.activeContentOpacity,
            activeControlBarOpacity: self.overlaySettings.activeControlBarOpacity,
            regionBorderOpacity: self.overlaySettings.regionBorderOpacity,
            ignoresMouseEvents: self.overlaySettings.ignoresMouseEvents,
            hosting: .mirrorToolbar
        )
        let contentFrame = defaultMirrorContentFrame(
            selectionSize: selection.size, visibleFrame: screen.visibleFrame
        )
        super.init(
            contentRect: contentFrame,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        title = L10n.text("번역 미러")
        titleVisibility = .hidden
        titlebarAppearsTransparent = false
        toolbarStyle = .unifiedCompact
        level = .floating
        isFloatingPanel = true
        hidesOnDeactivate = false
        isOpaque = true
        backgroundColor = .windowBackgroundColor
        collectionBehavior = [.fullScreenAuxiliary]
        // Keep AppKit's live-resize transaction on the cached native composite.
        preservesContentDuringLiveResize = true
        let contentContainer = NSView()
        mirrorView.translatesAutoresizingMaskIntoConstraints = false
        statusCapsule.translatesAutoresizingMaskIntoConstraints = false
        statusStack.orientation = .horizontal
        statusStack.alignment = .centerY
        statusStack.spacing = 4
        statusStack.translatesAutoresizingMaskIntoConstraints = false
        statusStack.addArrangedSubview(statusCapsule)
        statusStack.addArrangedSubview(saveRevealButton)
        pauseBadge.translatesAutoresizingMaskIntoConstraints = false
        zoomBadge.translatesAutoresizingMaskIntoConstraints = false
        searchBar.translatesAutoresizingMaskIntoConstraints = false
        ocrInspector.translatesAutoresizingMaskIntoConstraints = false
        ocrInspector.isHidden = true
        ocrInspector.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.94)
        ocrInspector.drawsBackground = true
        ocrInspector.isBezeled = true
        ocrInspector.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        ocrInspector.maximumNumberOfLines = 0
        contentContainer.addSubview(mirrorView)
        contentContainer.addSubview(statusStack)
        contentContainer.addSubview(searchBar)
        contentContainer.addSubview(ocrInspector)
        contentContainer.addSubview(pauseBadge)
        contentContainer.addSubview(zoomBadge)
        NSLayoutConstraint.activate([
            mirrorView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            mirrorView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            mirrorView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            mirrorView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            statusStack.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor, constant: -12),
            statusStack.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor, constant: -12)
            ,pauseBadge.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor, constant: -12)
            ,pauseBadge.centerXAnchor.constraint(equalTo: contentContainer.centerXAnchor)
            ,zoomBadge.topAnchor.constraint(equalTo: contentContainer.topAnchor, constant: 12)
            ,zoomBadge.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor, constant: -12)
            ,searchBar.topAnchor.constraint(equalTo: contentContainer.topAnchor, constant: 10)
            ,searchBar.centerXAnchor.constraint(equalTo: contentContainer.centerXAnchor)
            ,searchBar.widthAnchor.constraint(equalToConstant: 440)
            ,ocrInspector.topAnchor.constraint(equalTo: contentContainer.topAnchor, constant: 12)
            ,ocrInspector.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor, constant: -12)
            ,ocrInspector.widthAnchor.constraint(equalToConstant: 270)
        ])
        contentView = contentContainer
        mirrorView.onSelectionSessionBegin = { [weak self] in self?.selectionSessionDidBegin() }
        mirrorView.onSelectionSessionEnd = { [weak self] in self?.selectionSessionDidEnd() }
        mirrorView.onCopy = { [weak self] in self?.showCopyConfirmation() }
        overlayPanel.onSelectionSessionBegin = { [weak self] in self?.selectionSessionDidBegin() }
        overlayPanel.translationView.onSelectionSessionEnd = {
            [weak self] in self?.selectionSessionDidEnd()
        }
        overlayPanel.onCopy = { [weak self] in self?.showCopyConfirmation() }
        saveRevealButton.onReveal = { [weak self] in self?.revealSavedFile() }
        overlayPanel.showSaveRevealButton(false) { [weak self] in self?.revealSavedFile() }
        overlayControlBar.onSelectionDrag = { [weak self] rect, screen, delta, finished in
            self?.onOverlaySelectionDrag?(
                rect, screen, .move(delta: delta), finished
            )
        }
        overlayControlBar.onGeometryChange = { [weak self] frame, docking in
            guard self?.displayMode == .overlay else { return }
            self?.onOverlayControlBarGeometryChange?(frame, docking)
        }
        for controlBar in controlBars {
        controlBar.onDisplayModeChange = { [weak self] mode in
            self?.displayModeDidChange(mode)
        }
        controlBar.onTranslationDirectionChange = { [weak self] direction in
            self?.translationDirectionDidChange(direction)
        }
        controlBar.onNonSourceTextProtectionToggle = { [weak self] in
            self?.nonSourceTextProtectionDidChange()
        }
        controlBar.onApplicationCaptureChange = { [weak self] application in
            self?.applicationCaptureDidChange(application)
        }
        controlBar.onApplicationListRequest = { [weak self] in
            self?.requestApplicationList()
        }
        controlBar.onRefreshModeChange = { [weak self] mode in
            self?.refreshModeDidChange(mode)
        }
        controlBar.onPauseChange = { [weak self] paused in
            self?.pauseDidChange(paused)
        }
        controlBar.onImmediateTranslation = { [weak self] in
            self?.translateImmediately()
        }
        controlBar.onCopyAll = { [weak self] in self?.copyAllText() }
        controlBar.onCopyImage = { [weak self] in self?.copyImage() }
        controlBar.onSaveImage = { [weak self] in self?.saveImage() }
        controlBar.onSearch = { [weak self] in self?.showSearch(selectQuery: true) }
        controlBar.onSelectionModeToggle = { [weak self] in
            _ = self?.toggleSelectionMode()
        }
        controlBar.onMouseEventIgnoringToggle = { [weak self] in
            guard let self else { return }
            self.requestOverlayPresentationChange {
                $0.ignoresMouseEvents.toggle()
            }
        }
        controlBar.onAlwaysOnTopToggle = { [weak self] in
            let enabled = !MirrorAlwaysOnTop.load()
            MirrorAlwaysOnTop.save(enabled)
            self?.setAlwaysOnTop(enabled)
        }
        controlBar.onZoomOut = { [weak self] in self?.scaleContent(by: 1 / 1.1) }
        controlBar.onZoomActual = { [weak self] in self?.restoreOriginalSize() }
        controlBar.onZoomIn = { [weak self] in self?.scaleContent(by: 1.1) }
        controlBar.onFitWindowToContent = { [weak self] in
            self?.fitWindowToDisplayedContent()
        }
        controlBar.onFollowSelectionSizeToggle = { [weak self] in
            guard let self else { return }
            let enabled = !MirrorFollowsSelectionSize.load()
            self.setFollowSelectionSize(enabled)
            self.onFollowSelectionSizeChange?(enabled)
        }
        controlBar.onDockingChange = { [weak self] state in
            self?.setDocking(state, restoreUndockedFrame: state == .undocked, notify: true)
        }
        controlBar.onOverlayOpacityChange = { [weak self] opacity in
            self?.requestOverlayPresentationChange {
                $0.inactiveContentOpacity = opacity
            }
        }
        controlBar.onActiveOverlayOpacityChange = { [weak self] opacity in
            self?.requestOverlayPresentationChange {
                $0.activeContentOpacity = opacity
            }
        }
        controlBar.onTranslationBackgroundOpacityChange = { [weak self] opacity in
            self?.setBackgroundOpacity(opacity)
        }
        controlBar.onControlBarOpacityChange = { [weak self] opacity in
            self?.requestOverlayPresentationChange {
                $0.inactiveControlBarOpacity = opacity
            }
        }
        controlBar.onActiveControlBarOpacityChange = { [weak self] opacity in
            self?.requestOverlayPresentationChange {
                $0.activeControlBarOpacity = opacity
            }
        }
        controlBar.onRegionBorderOpacityChange = { [weak self] opacity in
            self?.requestOverlayPresentationChange {
                $0.regionBorderOpacity = opacity
            }
        }
        controlBar.onOCRDebugOverlayToggle = { [weak self] in
            self?.toggleOCRDebugOverlay()
        }
        controlBar.onClose = { [weak self] in
            self?.close()
        }
        }
        mirrorView.onOCRDebugSelection = { [weak self] item in
            let rawText = item.rawText ?? "—"
            let confidence = item.confidence.map { String(format: "%.4f", $0) } ?? "—"
            let candidate = item.rawText == nil ? "Missing" : "Present"
            let language = item.status == .nonJapanese ? "Non-Japanese" : (item.rawText == nil ? "Unknown" : "Japanese")
            let recognitionLanguages = item.recognitionLanguages.isEmpty
                ? "Unavailable"
                : item.recognitionLanguages.joined(separator: ", ")
            let translation: String
            switch item.status {
            case .success: translation = "Success"
            case .translationPending: translation = "Pending"
            case .translationFailed: translation = "Failed"
            default: translation = "Not Applicable"
            }
            let translatedText = item.translatedText ?? "—"
            self?.ocrInspector.stringValue = [
                L10n.format("상태              %@", item.status.title),
                L10n.format("원문              %@", rawText),
                L10n.format("신뢰도            %@", confidence),
                L10n.format("후보              %@", candidate),
                L10n.format("언어              %@", language),
                L10n.format("Vision 인식 언어  %@", recognitionLanguages),
                L10n.format("번역              %@", translation),
                L10n.format("번역문            %@", translatedText)
            ].joined(separator: "\n")
            self?.ocrInspector.isHidden = false
        }
        for bar in searchBars {
            bar.field.target = self
            bar.field.action = #selector(searchFieldChanged(_:))
            bar.field.isContinuous = true
            bar.caseSensitiveButton.target = self
            bar.caseSensitiveButton.action = #selector(searchOptionsChanged(_:))
            bar.regexButton.target = self
            bar.regexButton.action = #selector(searchOptionsChanged(_:))
            bar.closeButton.target = self
            bar.closeButton.action = #selector(closeSearch(_:))
            bar.field.onEscape = { [weak self] in self?.closeSearch() }
        }
        let updateSearchCount: (Int, String?) -> Void = { [weak self] count, error in
            for bar in self?.searchBars ?? [] {
                bar.countLabel.stringValue = error ?? (count == 0 ? "" : L10n.format("%d개", count))
                bar.countLabel.textColor = error == nil ? .secondaryLabelColor : .systemRed
            }
        }
        mirrorView.onSearchCountChange = updateSearchCount
        overlayPanel.translationView.onSearchCountChange = updateSearchCount
        mirrorView.backgroundOpacity = MirrorBackgroundOpacity.clamp(backgroundOpacity)
        overlayPanel.translationView.backgroundOpacity =
            MirrorBackgroundOpacity.clamp(backgroundOpacity)
        setAlwaysOnTop(MirrorAlwaysOnTop.load())
        let toolbar = NSToolbar(identifier: "TranslationMirrorChromeToolbar")
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        self.toolbar = toolbar
        addTitlebarAccessoryViewController(mirrorControlBarAccessory)
        mirrorControlBarAccessory.setEmbedded(true)
        delegate = self
        setContentSize(contentFrame.size)
        center()
        constrainToAvailableScreen()
        if dockingState == .undocked {
            // A fresh session places the window from the current selection
            // (centered, fitted to the visible frame) so it matches the
            // selection preview. The persisted undocked frame is only
            // restored by the undock toggle (setDocking), not at session
            // start: reusing its size here made the window appear at a
            // stale size and then snap to the native content size when the
            // first frame arrived.
            let restored = mirrorUndockedFrame(
                savedFrame: nil, defaultFrame: frame,
                visibleFrames: NSScreen.screens.map(\.visibleFrame)
            )
            setFrame(restored, display: false)
        } else {
            if !applyDockingFrame(for: dockingState, notifyFailure: false) {
                dockingState = .undocked
                dockingAnchor = nil
            }
        }
        controlBars.forEach { $0.setMirrorDocking(dockingState) }
        orderFrontRegardless()
        applyDisplayMode(displayMode, notify: false)
    }

    private var closingForSessionStop = false
    private var auxiliaryWindowsClosed = false

    func closeForSessionStop() {
        closingForSessionStop = true
        close()
    }

    private func closeAuxiliaryWindows() {
        guard !auxiliaryWindowsClosed else { return }
        auxiliaryWindowsClosed = true
        stopDragReleasePolling()
        dockPreview.close()
        overlayPanel.resetInteractionState()
        overlayPanel.close()
        overlaySearchPanel.close()
        overlayControlBar.closeForSessionStop()
        mirrorControlBar.closeForSessionStop()
    }

    func windowWillClose(_ notification: Notification) {
        closeAuxiliaryWindows()
        guard !closingForSessionStop else { return }
        onUserClose?()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        // The window callback is the reliable boundary for the cached
        // composite used during live resize.
        mirrorView.finishLiveResize()
        dockPreview.hide()
        if dockingState == .undocked { MirrorDockingState.saveUndockedFrame(frame) }
        else {
            // Check the raw frame produced by the resize before any docking
            // placement correction. Otherwise the correction can hide a
            // resize that moved the window outside the docking candidate.
            guard resizedFrameStillMatchesDockingCandidate(),
                  let placement = dockedPlacementForCurrentPosition(state: dockingState),
                  mirrorDockingCandidateMatches(
                      windowFrame: placement.frame, selection: selectionFrame,
                      state: dockingState, chromeHeight: mirrorChromeHeight
                  ) else {
                MirrorDockingState.saveUndockedFrame(frame)
                setDocking(.undocked, restoreUndockedFrame: false, notify: true)
                return
            }
            applyWindowFrame(placement.frame)
            dockingAnchor = placement.anchor
        }
    }

    func windowDidResize(_ notification: Notification) {
        mirrorControlBarAccessory.updateWidth()
        guard !isApplyingDockingFrame else { return }
        if inLiveResize {
            // Check the raw resize result before calculating the final docked
            // placement. The placement calculation intentionally clamps the
            // along-edge position, so checking it first could turn an invalid
            // resize into an apparently valid dock.
            guard dockingState != .undocked else { return }
            guard resizedFrameStillMatchesDockingCandidate(),
                  let placement = dockedPlacementForCurrentPosition(state: dockingState),
                  mirrorDockingCandidateMatches(
                      windowFrame: placement.frame, selection: selectionFrame,
                      state: dockingState, chromeHeight: mirrorChromeHeight
                  ) else {
                dockPreview.hide()
                onDockingGeometryChange?(dockingState, nil)
                return
            }
            // Show a ghost only when releasing would move the window;
            // otherwise show the persistent seam.
            let presentation = mirrorDockPreviewPresentation(
                for: .resize(
                    placementMatchesCurrentFrame: dockedPlacementMatchesCurrentFrame(placement.frame)
                )
            )
            if presentation == .seamOnly {
                dockPreview.hide()
                showPersistentSeam(at: placement.frame, state: dockingState)
            } else {
                showDockPreview(placement: placement.frame, state: dockingState)
                onDockingGeometryChange?(dockingState, nil)
            }
            return
        }
        guard dockingState != .undocked else { return }
        _ = applyDockingFrame(for: dockingState, notifyFailure: false)
    }

    func windowWillMove(_ notification: Notification) {
        // Programmatic moves that re-apply a docked frame (selection move or
        // resize follow) are wrapped in isApplyingDockingFrame; only moves
        // that follow the cursor directly are user window drags.
        guard !isApplyingDockingFrame,
              NSEvent.pressedMouseButtons & 1 != 0 else { return }
        if !wasDraggingWindow { beginWindowDragSession() }
    }

    func windowDidMove(_ notification: Notification) {
        guard !isApplyingDockingFrame else { return }
        let dragging = NSEvent.pressedMouseButtons & 1 != 0
        if dragging {
            // The window follows the cursor freely; preview the dock
            // position while a dock zone is near.
            if !wasDraggingWindow { beginWindowDragSession() }
            updateDockPreview()
            return
        }
        guard wasDraggingWindow else {
            // Non-drag move (resize follow, selection sync, programmatic):
            // keep a docked window aligned on its docked frame.
            if dockingState != .undocked {
                _ = applyDockingFrame(for: dockingState, notifyFailure: false)
            }
            return
        }
        // The final position update after release reports the button up:
        // decide the dock state immediately.
        wasDraggingWindow = false
        stopDragReleasePolling()
        finalizeWindowDrag()
    }

    private func beginWindowDragSession() {
        wasDraggingWindow = true
        startDragReleasePolling()
    }

    /// Whether the `pressedMouseButtons` polling fallback for closing a
    /// window drag is enabled. Server-side window drags (see
    /// `performWindowDrag(with:)`) may deliver neither the release mouse-up
    /// nor a trailing move notification, and this timer covers that case:
    /// the primary release signal is the button-state transition observed in
    /// `windowDidMove`, and the timer closes the drag session even when that
    /// trailing notification never arrives. The fallback was validated in
    /// real use after the primary signal alone was observed to leave the
    /// dock preview visible and skip the dock on release, so keep it on.
    private static let dragReleasePollingEnabled = true

    private func startDragReleasePolling() {
        guard Self.dragReleasePollingEnabled else { return }
        guard dragReleaseTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.wasDraggingWindow else { return }
                guard NSEvent.pressedMouseButtons & 1 == 0 else { return }
                self.wasDraggingWindow = false
                self.stopDragReleasePolling()
                self.finalizeWindowDrag()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        dragReleaseTimer = timer
    }

    private func stopDragReleasePolling() {
        dragReleaseTimer?.invalidate()
        dragReleaseTimer = nil
    }

    private func updateDockPreview() {
        guard let candidate = mirrorFreeDockCandidate(
            windowFrame: frame, selection: selectionFrame,
            chromeHeight: mirrorChromeHeight
        ) else {
            dockPreview.hide()
            onDockingGeometryChange?(dockingState, nil)
            return
        }
        guard let placement = dockedPlacementForCurrentPosition(state: candidate) else {
            dockPreview.hide()
            onDockingGeometryChange?(dockingState, nil)
            return
        }
        // Movement previews always show the docking target, including when
        // the target currently overlaps the mirror window.
        let presentation = mirrorDockPreviewPresentation(for: .move)
        if presentation == .seamOnly {
            dockPreview.hide()
            showPersistentSeam(at: placement.frame, state: candidate)
        } else {
            showDockPreview(placement: placement.frame, state: candidate)
            onDockingGeometryChange?(dockingState, nil)
        }
    }

    private func resizedFrameStillMatchesDockingCandidate() -> Bool {
        guard dockingState != .undocked else { return false }
        return mirrorDockingCandidateMatches(
            windowFrame: frame, selection: selectionFrame, state: dockingState,
            chromeHeight: mirrorChromeHeight
        )
    }

    private func dockedPlacementMatchesCurrentFrame(_ placement: CGRect) -> Bool {
        mirrorRectsAreVisuallyEqual(
            mirrorWindowFrameAsStoredByAppKit(placement), frame,
            backingScale: screen?.backingScaleFactor ?? backingScaleFactor
        )
    }

    /// The placement a drag-docked window would land on at the current
    /// position: the free placement keeps the window's position along the
    /// edge (aligned to the standard offset), and snaps to the nearest of
    /// the three content-based alignments (start/center/end) when the
    /// along-edge position is within `magneticSnapDistance` of it.
    private func dockedPlacementForCurrentPosition(state: MirrorDockingState) -> DockedFramePlacement? {
        let offset = RegionBorderTuning.borderOutset + MirrorDockingState.dockedGap
        var free = frame
        switch state {
        case .top: free.origin.y = selectionFrame.maxY + offset
        case .bottom: free.origin.y = selectionFrame.minY - offset - free.height
        case .left: free.origin.x = selectionFrame.minX - offset - free.width
        case .right: free.origin.x = selectionFrame.maxX + offset
        case .undocked: break
        }
        // Magnetic snap: pick the nearest content-based alignment.
        let snapped: (frame: CGRect, distance: CGFloat, alignment: MirrorDockAlignment)? = MirrorDockAlignment.allCases
            .compactMap { alignment -> (CGRect, CGFloat, MirrorDockAlignment)? in
                guard let standard = mirrorDockedFrame(
                    selection: selectionFrame, windowSize: frame.size, state: state,
                    visibleFrames: NSScreen.screens.map(\.visibleFrame),
                    chromeHeight: mirrorChromeHeight,
                    borderOutset: RegionBorderTuning.borderOutset,
                    alignment: alignment
                ) else { return nil }
                return (
                    standard.frame,
                    alongEdgeDistance(from: free, to: standard.frame, state: state),
                    alignment
                )
            }
            .min { $0.1 < $1.1 }
        if let snapped, snapped.distance <= MirrorDockingState.magneticSnapDistance {
            return DockedFramePlacement(
                frame: snapped.frame, anchor: .alignment(snapped.alignment)
            )
        }
        // A free along-edge position still has to produce a placement that
        // fits the same visible-screen contract as shortcut docking. Reuse
        // mirrorDockedFrame so the existing 50% minimum scale and multi-
        // display coverage logic apply to drag docking as well.
        let freeAnchor = mirrorDockingAnchor(
            frame: free, selection: selectionFrame, state: state,
            chromeHeight: mirrorChromeHeight
        )
        guard let fitted = mirrorDockedFrame(
            selection: selectionFrame, windowSize: frame.size, state: state,
            visibleFrames: NSScreen.screens.map(\.visibleFrame),
            chromeHeight: mirrorChromeHeight,
            borderOutset: RegionBorderTuning.borderOutset,
            alignment: MirrorDockAlignment.shortcutDefault(for: state),
            anchor: freeAnchor
        ) else {
            return nil
        }
        return DockedFramePlacement(
            frame: fitted.frame,
            anchor: mirrorDockingAnchor(
                frame: fitted.frame, selection: selectionFrame, state: state,
                chromeHeight: mirrorChromeHeight
            )
        )
    }

    private func alongEdgeDistance(from current: CGRect, to target: CGRect, state: MirrorDockingState) -> CGFloat {
        switch state {
        case .top, .bottom: abs(current.minX - target.minX)
        case .left, .right: abs(current.minY - target.minY)
        case .undocked: 0
        }
    }

    private func showPersistentSeam(at placement: CGRect, state: MirrorDockingState) {
        let seam = mirrorDockingSeamRect(
            placement: placement, state: state, selection: selectionFrame,
            borderOutset: RegionBorderTuning.borderOutset,
            borderShadowReach: RegionBorderTuning.borderShadowReach,
            chromeHeight: mirrorChromeHeight
        )
        onDockingGeometryChange?(state, seam)
    }

    /// The preview is drawn at the visual level — above the mirror window —
    /// so the ghost and its seam stay fully visible while the window is
    /// dragged, never hidden behind the mirror itself.
    private func showDockPreview(placement: CGRect, state: MirrorDockingState) {
        dockPreview.level = RegionWindowLevel.visual
        dockPreview.show(
            placement: placement, state: state, selection: selectionFrame,
            color: dockPreviewColor,
            borderOutset: RegionBorderTuning.borderOutset,
            borderShadowReach: RegionBorderTuning.borderShadowReach,
            chromeHeight: mirrorChromeHeight
        )
    }

    /// Keeps the drag-time dock preview in the same color as the region
    /// border (refresh mode / pause state dependent).
    func setDockPreviewColor(_ color: NSColor) {
        dockPreviewColor = color
    }

    private func finalizeWindowDrag() {
        stopDragReleasePolling()
        dockPreview.hide()
        // Drag docking attaches at the current position along the edge
        // (free placement), snapping to the nearest content-based alignment
        // when near one.
        if let candidate = mirrorFreeDockCandidate(
            windowFrame: frame, selection: selectionFrame,
            chromeHeight: mirrorChromeHeight
        ) {
            if let placement = dockedPlacementForCurrentPosition(state: candidate) {
                setDocking(
                    candidate, restoreUndockedFrame: false, notify: true,
                    placement: placement.frame, anchor: placement.anchor
                )
                return
            }
        }
        if dockingState == .undocked {
            // Keep a manually dragged undocked window's latest position as
            // the fallback used by a later menu/shortcut undock.
            MirrorDockingState.saveUndockedFrame(frame)
            return
        }
        // A docked drag that no longer satisfies the same candidate rule as
        // an undocked-to-docked drag is an undock, regardless of which axis
        // moved away from the selection.
        MirrorDockingState.saveUndockedFrame(frame)
        setDocking(.undocked, restoreUndockedFrame: false, notify: true)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    private var searchBars: [MirrorSearchBar] { [searchBar, overlaySearchPanel.searchBar] }
    private var isSearchVisible: Bool {
        searchBars.contains { !$0.isHidden }
    }

    func ownsTranslationSessionWindow(_ window: NSWindow?) -> Bool {
        window === self
            || window === overlayPanel
            || window === overlaySearchPanel
            || overlayControlBar.ownsTranslationSessionWindow(window)
            || mirrorControlBar.ownsTranslationSessionWindow(window)
            || mirrorControlBarAccessory.ownsTranslationSessionWindow(window)
    }

    func performTranslationTextShortcut(_ character: String) -> Bool {
        switch character {
        case "a":
            activeTranslationView.selectAll(nil)
        case "c":
            activeTranslationView.copy(nil)
        case "x":
            activeTranslationView.copyAndClearSelection()
        case "f":
            showSearch(selectQuery: true)
        default:
            return false
        }
        return true
    }

    func showSearch(selectQuery: Bool = false) {
        let bar = displayMode == .overlay ? overlaySearchPanel.searchBar : searchBar
        bar.isHidden = false
        if displayMode == .overlay {
            searchBar.isHidden = true
            overlaySearchPanel.show()
            overlaySearchPanel.makeKeyAndOrderFront(nil)
            overlaySearchPanel.makeFirstResponder(bar.field)
        } else {
            overlaySearchPanel.searchBar.isHidden = true
            overlaySearchPanel.hide()
            makeKeyAndOrderFront(nil)
            makeFirstResponder(bar.field)
        }
        if selectQuery { bar.field.currentEditor()?.selectAll(nil) }
    }

    func activateFromGlobalHotKey() {
        NSApp.activate(ignoringOtherApps: true)
        if displayMode == .overlay {
            orderOut(nil)
            overlayPanel.orderFrontRegardless()
            overlayControlBar.show()
            overlayPanel.makeKey()
            overlayPanel.makeFirstResponder(overlayPanel.translationView)
        } else {
            overlayControlBar.hide()
            orderFrontRegardless()
            makeKeyAndOrderFront(nil)
            makeFirstResponder(mirrorView)
        }
    }

    private func closeSearch() {
        searchBars.forEach { $0.isHidden = true }
        overlaySearchPanel.hide()
        mirrorView.clearSearch()
        overlayPanel.translationView.clearSearch()
        if displayMode == .overlay { overlayPanel.makeFirstResponder(overlayPanel.translationView) }
        else { makeFirstResponder(mirrorView) }
    }

    @objc private func closeSearch(_ sender: Any?) { closeSearch() }
    @objc private func searchFieldChanged(_ sender: NSSearchField) {
        searchBars.filter { $0.field !== sender }.forEach { $0.field.stringValue = sender.stringValue }
        updateSearch()
    }
    @objc private func searchOptionsChanged(_ sender: NSButton) {
        let changesCaseSensitive = searchBars.contains { $0.caseSensitiveButton === sender }
        let caseSensitive = changesCaseSensitive ? sender.state : searchBar.caseSensitiveButton.state
        let regex = changesCaseSensitive ? searchBar.regexButton.state : sender.state
        for bar in searchBars {
            bar.caseSensitiveButton.state = caseSensitive
            bar.regexButton.state = regex
        }
        updateSearch()
    }
    private func updateSearch() {
        let query = searchBar.field.stringValue
        let caseSensitive = searchBar.caseSensitiveButton.state == .on
        let regex = searchBar.regexButton.state == .on
        mirrorView.setSearch(query: query, caseSensitive: caseSensitive, regex: regex)
        overlayPanel.translationView.setSearch(query: query, caseSensitive: caseSensitive, regex: regex)
    }

    func showProcessingStatus(
        _ status: MirrorProcessingStatus, frameID: UInt64,
        origin: MirrorStatusOrigin = .automatic
    ) {
        if origin == .userAction, isTransientStatusVisible {
            transientStatusDismissal?.cancel()
            transientStatusDismissal = nil
            isTransientStatusVisible = false
            transientSavedURL = nil
            saveRevealButton.isHidden = true
            overlayPanel.showSaveRevealButton(false)
        }
        currentProcessingStatus = status
        if status.isProcessing {
            statusFrameID = frameID
            isProcessingStatusVisible = true
            statusDismissal?.cancel()
            statusDismissal = nil
        } else {
            guard statusFrameID == frameID else { return }
            isProcessingStatusVisible = false
        }
        if !isTransientStatusVisible { showStatusOnActiveSurface(status) }
        guard !status.isProcessing else { return }
        statusDismissal?.cancel()
        statusDismissal = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(status == .recognitionFailed ? 1500 : 500))
            guard !Task.isCancelled, self?.statusFrameID == frameID,
                  self?.isTransientStatusVisible == false else { return }
            self?.hideStatusOnAllSurfaces(animated: true)
            self?.statusFrameID = nil
            self?.currentProcessingStatus = nil
        }
    }

    func cancelProcessingStatus() {
        statusFrameID = nil
        currentProcessingStatus = nil
        isProcessingStatusVisible = false
        statusDismissal?.cancel()
        statusDismissal = nil
        if !isTransientStatusVisible { hideStatusOnAllSurfaces(animated: false) }
    }

    func display(_ frame: MirrorFrame) {
        let update = PerformanceProfiler.shared.begin(
            .mirrorUpdate, frameID: frame.frameID, itemCount: frame.translatedItems.count
        )
        apply(frame)
        PerformanceProfiler.shared.end(update)
    }

    private func apply(_ frame: MirrorFrame) {
        latestImagePixelSize = CGSize(width: frame.image.width, height: frame.image.height)
        if !hasAppliedNativeContentSize {
            hasAppliedNativeContentSize = true
            if displayMode == .mirror {
                resizeContent(to: nativeContentSize())
            }
        }
        mirrorView.frameSnapshot = frame
        if displayMode == .overlay { overlayPanel.display(frame) }
        mirrorView.needsDisplay = true
        let copyEnabled = !frame.translatedItems.isEmpty
        controlBars.forEach {
            $0.setCopyAllEnabled(copyEnabled)
            $0.setCopyImageEnabled(true)
        }
    }

    func copyAllText() {
        let text = mirrorClipboardText(items: activeTranslationView.frameSnapshot?.translatedItems ?? [])
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        showCopyConfirmation()
    }

    func copyImage() {
        guard let image = activeTranslationView.compositedImage(),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
        pasteboard.setData(tiff, forType: .tiff)
        showCopyConfirmation(title: L10n.text("이미지 복사됨"))
    }

    func saveImage() {
        guard let image = activeTranslationView.compositedImage() else {
            showCopyConfirmation(title: L10n.text("이미지 저장 실패"))
            return
        }
        do {
            let url = try ImageSaveService.save(
                image: image,
                directory: ImageSaveSettings.directoryURL(),
                filenameTemplate: ImageSaveSettings.filenameTemplate()
            )
            showSaveConfirmation(url: url)
        } catch {
            showCopyConfirmation(title: L10n.format("이미지 저장 실패: %@", error.localizedDescription))
        }
    }

    private func showCopyConfirmation(title: String = L10n.text("복사됨")) {
        transientStatusDismissal?.cancel()
        isTransientStatusVisible = true
        transientStatusTitle = title
        transientSavedURL = nil
        saveRevealButton.isHidden = true
        overlayPanel.showSaveRevealButton(false)
        showStatusOnActiveSurface(title: title, symbol: "checkmark.circle.fill")
        transientStatusDismissal = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled, let self else { return }
            self.isTransientStatusVisible = false
            self.transientStatusDismissal = nil
            if self.isProcessingStatusVisible, let status = self.currentProcessingStatus {
                self.showStatusOnActiveSurface(status)
            } else {
                self.hideStatusOnAllSurfaces(animated: true)
                self.statusFrameID = nil
                self.currentProcessingStatus = nil
            }
        }
    }

    private func showSaveConfirmation(url: URL) {
        transientStatusDismissal?.cancel()
        isTransientStatusVisible = true
        transientStatusTitle = L10n.format("저장됨 · %@", url.lastPathComponent)
        transientSavedURL = url
        saveRevealButton.isHidden = false
        overlayPanel.showSaveRevealButton(true) { [weak self] in self?.revealSavedFile() }
        showSaveStatusOnActiveSurface()
        transientStatusDismissal = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, let self else { return }
            self.isTransientStatusVisible = false
            self.transientStatusDismissal = nil
            self.transientSavedURL = nil
            self.saveRevealButton.isHidden = true
            self.overlayPanel.showSaveRevealButton(false)
            if self.isProcessingStatusVisible, let status = self.currentProcessingStatus {
                self.showStatusOnActiveSurface(status)
            } else {
                self.hideStatusOnAllSurfaces(animated: true)
                self.statusFrameID = nil
                self.currentProcessingStatus = nil
            }
        }
    }

    private func revealSavedFile() {
        guard let url = transientSavedURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func setBackgroundOpacity(_ opacity: CGFloat) {
        let value = displayMode == .overlay ? 1 : MirrorBackgroundOpacity.clamp(opacity)
        mirrorView.backgroundOpacity = value
        overlayPanel.translationView.backgroundOpacity = value
        controlBars.forEach { $0.setTranslationBackgroundOpacity(value) }
        mirrorView.needsDisplay = true
        overlayPanel.translationView.needsDisplay = true
        onBackgroundOpacityChange?(value)
    }

    func setOverlayOpacity(_ opacity: CGFloat) {
        requestOverlayPresentationChange { $0.inactiveContentOpacity = opacity }
    }

    func setActiveOverlayOpacity(_ opacity: CGFloat) {
        requestOverlayPresentationChange { $0.activeContentOpacity = opacity }
    }

    func setOverlayControlBarOpacity(_ opacity: CGFloat) {
        requestOverlayPresentationChange { $0.inactiveControlBarOpacity = opacity }
    }

    func setActiveOverlayControlBarOpacity(_ opacity: CGFloat) {
        requestOverlayPresentationChange { $0.activeControlBarOpacity = opacity }
    }

    func setOverlayIgnoresMouseEvents(_ enabled: Bool) {
        requestOverlayPresentationChange { $0.ignoresMouseEvents = enabled }
    }

    func setRegionBorderOpacity(_ opacity: CGFloat) {
        requestOverlayPresentationChange { $0.regionBorderOpacity = opacity }
    }

    func setOverlayPresentationSettings(_ settings: OverlayPresentationSettings) {
        overlaySettings = settings.normalized()
        overlayPanel.setOverlayOpacities(
            inactive: overlaySettings.inactiveContentOpacity,
            active: overlaySettings.activeContentOpacity
        )
        overlayPanel.setIgnoresSelectionMouseEvents(overlaySettings.ignoresMouseEvents)
        controlBars.forEach {
            $0.setOverlayOpacity(overlaySettings.inactiveContentOpacity)
            $0.setActiveOverlayOpacity(overlaySettings.activeContentOpacity)
            $0.setControlBarOpacity(overlaySettings.inactiveControlBarOpacity)
            $0.setActiveControlBarOpacity(overlaySettings.activeControlBarOpacity)
            $0.setRegionBorderOpacity(overlaySettings.regionBorderOpacity)
            $0.setIgnoresSelectionMouseEvents(overlaySettings.ignoresMouseEvents)
        }
    }

    private func requestOverlayPresentationChange(
        _ update: (inout OverlayPresentationSettings) -> Void
    ) {
        var settings = overlaySettings
        update(&settings)
        setOverlayPresentationSettings(settings)
        onOverlayPresentationChange?(overlaySettings)
    }

    func refreshShortcutToolTips() {
        controlBars.forEach { $0.refreshShortcutToolTips() }
    }

    func refreshLocalization() {
        title = L10n.text("번역 미러")
        pauseBadge.refreshLocalization()
        searchBars.forEach { $0.refreshLocalization() }
        overlayPanel.refreshLocalization()
        controlBars.forEach { $0.refreshLocalization() }
        transientStatusTitle = L10n.text("복사됨")
        if isProcessingStatusVisible, let currentProcessingStatus {
            showStatusOnActiveSurface(currentProcessingStatus)
        }
    }

    func toolbarContractViolationsForSelfTest() -> [String] {
        var violations: [String] = []
        if titlebarAppearsTransparent {
            violations.append("mirror titlebar background must occlude translated content")
        }
        if toolbar == nil {
            violations.append("mirror must retain the empty unified toolbar chrome")
        } else if toolbar?.items.isEmpty == false {
            violations.append("mirror chrome toolbar must not contain control items")
        }
        if titlebarAccessoryViewControllers.count != 1 {
            violations.append("mirror must install exactly one control bar titlebar accessory")
        }
        if overlayControlBar === mirrorControlBar {
            violations.append("mirror and overlay must use distinct control bar instances")
        }
        if !mirrorControlBar.isEmbeddedInMirrorToolbarForSelfTest {
            violations.append("mirror control bar must remain hosted by the titlebar accessory")
        }
        if overlayControlBar.isEmbeddedInMirrorToolbarForSelfTest
            || !overlayControlBar.ownsPanelContentForSelfTest {
            violations.append("overlay control bar must remain owned by its panel")
        }
        if let contentView {
            let chromeHeight = frame.height - contentView.frame.height
            if abs(chromeHeight - OverlayControlBarMetrics.height) > 0.5 {
                violations.append("mirror unified titlebar must remain 40pt high")
            }
        }
        violations.append(contentsOf: mirrorControlBarAccessory.contractViolationsForSelfTest())
        return violations
    }

    func controlBarModeTransitionContractViolationsForSelfTest() -> [String] {
        var violations: [String] = []
        setDisplayMode(.overlay)
        if !mirrorControlBar.isEmbeddedInMirrorToolbarForSelfTest
            || overlayControlBar.isEmbeddedInMirrorToolbarForSelfTest {
            violations.append("control bar ownership changed while entering overlay mode")
        }
        setDisplayMode(.mirror)
        if !mirrorControlBar.isEmbeddedInMirrorToolbarForSelfTest
            || overlayControlBar.isEmbeddedInMirrorToolbarForSelfTest {
            violations.append("control bar ownership changed while returning to mirror mode")
        }
        return violations
    }

    func setDisplayMode(
        _ mode: TranslationDisplayMode,
        focusBehavior: DisplayModeFocusBehavior = .preserveKeyWindow
    ) {
        let shouldTransferFocus = focusBehavior.shouldTransferFocus(
            isDisplayKeyWindow: isTranslationDisplayKeyWindow
        )
        applyDisplayMode(mode, notify: false)
        if shouldTransferFocus { focusActiveTranslationDisplay() }
    }

    func setTranslationDirection(_ direction: TranslationDirection) {
        translationDirection = direction
        controlBars.forEach { $0.setTranslationDirection(direction) }
    }

    func translationDirectionDidChange(_ direction: TranslationDirection) {
        setTranslationDirection(direction)
        onTranslationDirectionChange?(direction)
    }

    func setProtectsNonSourceText(_ enabled: Bool) {
        controlBars.forEach { $0.setProtectsNonSourceText(enabled) }
    }

    private func nonSourceTextProtectionDidChange() {
        let enabled = !TranslationTextProtection.load()
        onNonSourceTextProtectionChange?(enabled)
    }

    func displayModeDidChange(_ mode: TranslationDisplayMode) {
        let shouldTransferFocus = isTranslationDisplayKeyWindow
        applyDisplayMode(mode, notify: true)
        if shouldTransferFocus { focusActiveTranslationDisplay() }
    }

    func toggleSelectionMode() -> Bool {
        setSelectionModeActive(!selectionModeActive, notifySelectionBegin: true)
        return selectionModeActive
    }

    private func selectionSessionDidBegin() {
        setSelectionModeActive(true, notifySelectionBegin: true)
    }

    private func selectionSessionDidEnd() {
        setSelectionModeActive(false, notifySelectionBegin: false)
    }

    private func setSelectionModeActive(_ active: Bool, notifySelectionBegin: Bool) {
        let changed = selectionModeActive != active
        selectionModeActive = active
        mirrorView.setSelectionModeActive(active)
        overlayPanel.translationView.setSelectionModeActive(active)
        overlayPanel.setSelectionModeEnabled(active)
        controlBars.forEach { $0.setSelectionMode(active) }
        if changed, active, notifySelectionBegin {
            onTextSelectionBegin?()
        }
    }

    func setOCRDebugOverlay(_ enabled: Bool) {
        mirrorView.ocrDebugOverlayEnabled = enabled
        overlayPanel.translationView.ocrDebugOverlayEnabled = enabled
        controlBars.forEach { $0.setOCRDebugOverlay(enabled) }
        if !enabled { ocrInspector.isHidden = true }
        mirrorView.needsDisplay = true
        overlayPanel.translationView.needsDisplay = true
    }

    func toggleOCRDebugOverlay() { setOCRDebugOverlay(!mirrorView.ocrDebugOverlayEnabled) }

    func setDebugFeaturesEnabled(_ enabled: Bool) {
        controlBars.forEach { $0.setDebugFeaturesEnabled(enabled) }
    }

    func scaleContent(by factor: CGFloat) {
        let current = contentLayoutRect.size
        resizeContent(to: CGSize(width: current.width * factor, height: current.height * factor))
        showZoomBadge()
    }

    func restoreOriginalSize() {
        resizeContent(to: nativeContentSize())
        showZoomBadge()
    }

    func fitWindowToDisplayedContent() {
        let targetSize = mirrorContentFitSize(
            contentSize: latestImagePixelSize ?? originalContentSize,
            viewportSize: mirrorView.bounds.size
        )
        guard targetSize.width > 0, targetSize.height > 0 else { return }
        resizeContent(to: targetSize)
        showZoomBadge()
    }

    private func showZoomBadge() {
        guard displayMode == .mirror else { return }
        let native = nativeContentSize()
        guard native.width > 0 else { return }
        let percentage = mirrorZoomPercentage(
            contentWidth: contentLayoutRect.width, nativeWidth: native.width
        )
        zoomBadge.show(percentage: percentage)
        zoomBadgeDismissal?.cancel()
        zoomBadgeDismissal = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.zoomBadge.hide()
        }
    }

    func setAlwaysOnTop(_ enabled: Bool) {
        let overlay = displayMode == .overlay
        level = overlay || enabled ? .floating : .normal
        isFloatingPanel = overlay || enabled
        controlBars.forEach { $0.setAlwaysOnTop(enabled) }
    }

    func selectionSizeDidChange(
        _ size: CGSize, resizing edge: RegionBorderController.Edge? = nil,
        followsSelectionSize: Bool = true
    ) {
        if let edge { activeTranslationView.beginResize(edge: edge) }
        guard size != originalContentSize else { return }
        let oldSelectionSize = originalContentSize
        originalContentSize = size
        if displayMode == .mirror, followsSelectionSize {
            let targetSize = mirrorScaledContentSize(
                previousSelectionSize: oldSelectionSize,
                currentViewportSize: contentLayoutRect.size,
                newSelectionSize: size
            )
            resizeContent(to: targetSize, resizing: edge)
        }
    }

    func selectionDidMove(_ delta: CGPoint) {
        activeTranslationView.moveImage(by: delta)
    }

    func setSelectionFrame(_ rect: CGRect) {
        selectionFrame = rect
        overlayPanel.setSelectionFrame(rect)
        overlaySearchPanel.setSelectionFrame(rect)
        controlBars.forEach { $0.setSelectionFrame(rect) }
        if displayMode == .mirror, dockingState != .undocked {
            _ = applyDockingFrame(for: dockingState, notifyFailure: false)
        }
    }

    func finishSelectionTransform() {
        activeTranslationView.finishInteractiveTransform()
    }

    func setFollowSelectionSize(_ enabled: Bool) {
        controlBars.forEach { $0.setFollowSelectionSize(enabled) }
    }

    func toggleFollowSelectionSize() -> Bool {
        let enabled = !MirrorFollowsSelectionSize.load()
        onFollowSelectionSizeChange?(enabled)
        return enabled
    }

    func setApplicationCapture(applications: [CaptureApplication], selected: CaptureApplication?) {
        controlBars.forEach {
            $0.setApplicationCapture(applications: applications, selected: selected)
        }
    }

    func applicationCaptureDidChange(_ application: CaptureApplication?) {
        onApplicationCaptureChange?(application)
    }

    func showApplicationCapturePopup() {
        requestApplicationList()
        if displayMode == .overlay {
            overlayControlBar.showApplicationCapturePopup()
        } else {
            mirrorControlBar.showApplicationCapturePopup()
        }
    }

    func requestApplicationList() { onApplicationListRequest?() }
    func setRefreshMode(_ mode: RefreshMode) {
        controlBars.forEach { $0.setRefreshMode(mode) }
    }
    func refreshModeDidChange(_ mode: RefreshMode) { onRefreshModeChange?(mode) }
    func setPaused(_ paused: Bool) {
        if !paused {
            mirrorView.clearSelection(nil)
            overlayPanel.translationView.clearSelection(nil)
        }
        pauseBadge.isHidden = !paused
        overlayPanel.setPaused(paused)
        controlBars.forEach { $0.setPaused(paused) }
    }
    func pauseDidChange(_ paused: Bool) { onPauseChange?(paused) }
    func translateImmediately() { onImmediateTranslation?() }

    var currentDisplayMode: TranslationDisplayMode { displayMode }
    var currentOverlayPresentationSettings: OverlayPresentationSettings {
        overlaySettings
    }
    var currentBackgroundOpacity: CGFloat { mirrorView.backgroundOpacity }
    var currentOverlayOpacity: CGFloat { overlayOpacity }
    var currentOpacity: CGFloat {
        displayMode == .overlay ? overlayOpacity : mirrorView.backgroundOpacity
    }

    func setCurrentOpacity(_ opacity: CGFloat) {
        if displayMode == .overlay {
            setOverlayOpacity(opacity)
        } else {
            setBackgroundOpacity(opacity)
        }
    }

    private var activeTranslationView: NativeTranslationMirrorView {
        displayMode == .overlay ? overlayPanel.translationView : mirrorView
    }

    private var isTranslationDisplayKeyWindow: Bool {
        let keyWindow = NSApp.keyWindow
        return keyWindow === self || keyWindow === overlayPanel || keyWindow === overlayControlBar
    }

    private func focusActiveTranslationDisplay() {
        if displayMode == .overlay {
            overlayPanel.makeKey()
            overlayPanel.makeFirstResponder(overlayPanel.translationView)
        } else {
            makeKeyAndOrderFront(nil)
            makeFirstResponder(mirrorView)
        }
    }

    private func applyDisplayMode(_ mode: TranslationDisplayMode, notify: Bool) {
        let searchWasVisible = isSearchVisible
        setSelectionModeActive(false, notifySelectionBegin: false)
        let changed = displayMode != mode
        displayMode = mode
        setAlwaysOnTop(MirrorAlwaysOnTop.load())
        controlBars.forEach { $0.setDisplayMode(mode) }

        if mode == .overlay {
            mirrorView.setRenderingActive(false)
            overlayPanel.translationView.backgroundOpacity = 1
            overlayPanel.translationView.setRenderingActive(true)
            dockPreview.hide()
            if let snapshot = mirrorView.frameSnapshot { overlayPanel.display(snapshot) }
            overlayPanel.setSelectionFrame(selectionFrame)
            overlayPanel.setOverlayOpacities(
                inactive: overlayOpacity, active: activeOverlayOpacity
            )
            mirrorView.backgroundOpacity = 1
            overlayPanel.translationView.backgroundOpacity = 1
            controlBars.forEach { $0.setTranslationBackgroundOpacity(1) }
            overlayPanel.orderFrontRegardless()
            overlayPanel.refreshInteractionState()
            orderOut(nil)
            overlayControlBar.show()
            onOverlayControlBarGeometryChange?(
                overlayControlBar.frame, overlayControlBar.currentDocking
            )
        } else {
            overlayPanel.translationView.setRenderingActive(false)
            mirrorView.backgroundOpacity = MirrorBackgroundOpacity.load()
            mirrorView.setRenderingActive(true)
            onOverlayControlBarGeometryChange?(nil, nil)
            overlayControlBar.hide()
            overlayPanel.resetInteractionState()
            overlayPanel.orderOut(nil)
            orderFrontRegardless()
            setBackgroundOpacity(MirrorBackgroundOpacity.load())
            if dockingState != .undocked {
                _ = applyDockingFrame(for: dockingState, notifyFailure: false)
            }
        }
        updateSearchPresentation(isVisible: searchWasVisible)
        hideStatusOnAllSurfaces(animated: false)
        if isTransientStatusVisible {
            if transientSavedURL != nil {
                showSaveStatusOnActiveSurface()
            } else {
                showStatusOnActiveSurface(title: transientStatusTitle, symbol: "checkmark.circle.fill")
            }
        } else if let currentProcessingStatus {
            showStatusOnActiveSurface(currentProcessingStatus)
        }
        if changed, notify { onDisplayModeChange?(mode) }
        onDockingGeometryChange?(
            dockingState, mode == .mirror ? dockingSeamFrame : nil
        )
    }

    private func updateSearchPresentation(isVisible: Bool) {
        guard isVisible else {
            searchBars.forEach { $0.isHidden = true }
            overlaySearchPanel.hide()
            return
        }
        if displayMode == .overlay {
            searchBar.isHidden = true
            overlaySearchPanel.searchBar.isHidden = false
            overlaySearchPanel.show()
        } else {
            overlaySearchPanel.searchBar.isHidden = true
            overlaySearchPanel.hide()
            searchBar.isHidden = false
        }
    }

    private func showStatusOnActiveSurface(_ status: MirrorProcessingStatus) {
        if displayMode == .overlay {
            overlayPanel.showStatus(status)
        } else {
            statusCapsule.show(status)
        }
    }

    private func showStatusOnActiveSurface(title: String, symbol: String) {
        if displayMode == .overlay {
            overlayPanel.showStatus(title: title, symbol: symbol)
        } else {
            statusCapsule.show(title: title, symbol: symbol)
        }
    }

    private func showSaveStatusOnActiveSurface() {
        if displayMode == .overlay {
            overlayPanel.showStatus(title: transientStatusTitle, symbol: "checkmark.circle.fill")
            overlayPanel.showSaveRevealButton(true) { [weak self] in self?.revealSavedFile() }
        } else {
            statusCapsule.show(title: transientStatusTitle, symbol: "checkmark.circle.fill")
            saveRevealButton.isHidden = false
        }
    }

    private func hideStatusOnAllSurfaces(animated: Bool) {
        statusCapsule.hide(animated: animated)
        overlayPanel.hideStatus(animated: animated)
        saveRevealButton.isHidden = true
        overlayPanel.showSaveRevealButton(false)
    }

    private func resizeContent(
        to requestedSize: CGSize, resizing edge: RegionBorderController.Edge? = nil
    ) {
        guard let visibleFrame = screen?.visibleFrame ?? NSScreen.main?.visibleFrame else { return }
        let scale = min(1, visibleFrame.width / requestedSize.width, visibleFrame.height / requestedSize.height)
        let fitted = CGSize(width: requestedSize.width * scale, height: requestedSize.height * scale)
        let targetSize = frameRect(forContentRect: CGRect(origin: .zero, size: fitted)).size
        setFrame(mirrorFrame(resizing: frame, to: targetSize, from: edge), display: true)
        constrainToAvailableScreen()
    }

    private func nativeContentSize() -> CGSize {
        guard let latestImagePixelSize else { return originalContentSize }
        return mirrorNativeContentSize(
            imagePixelSize: latestImagePixelSize,
            backingScale: screen?.backingScaleFactor ?? backingScaleFactor
        )
    }

    private func constrainToAvailableScreen() {
        let availableScreens = NSScreen.screens
        guard !availableScreens.contains(where: { $0.visibleFrame.intersects(frame) }),
              let target = NSScreen.main ?? availableScreens.first else { return }
        setFrame(frame.intersection(target.visibleFrame).isNull
                 ? defaultMirrorContentFrame(
                    selectionSize: latestImagePixelSize ?? originalContentSize,
                    visibleFrame: target.visibleFrame
                 )
                 : frame, display: false)
    }

    var dockingSeamFrame: CGRect? {
        guard displayMode == .mirror, dockingState != .undocked else { return nil }
        return mirrorDockingSeamRect(
            placement: frame, state: dockingState, selection: selectionFrame,
            borderOutset: RegionBorderTuning.borderOutset,
            borderShadowReach: RegionBorderTuning.borderShadowReach,
            chromeHeight: mirrorChromeHeight
        )
    }

    var currentDockingState: MirrorDockingState { dockingState }

    func toggleDocking(_ requested: MirrorDockingState) {
        let target = dockingState.toggled(with: requested)
        setDocking(target, restoreUndockedFrame: target == .undocked, notify: true)
    }

    private func setDocking(
        _ state: MirrorDockingState, restoreUndockedFrame: Bool, notify: Bool
    ) {
        setDocking(
            state, restoreUndockedFrame: restoreUndockedFrame, notify: notify,
            placement: nil, anchor: nil
        )
    }

    /// `placement` overrides the standard docked alignment: drag docking
    /// attaches at the given (free or magnetically snapped) placement.
    private func setDocking(
        _ state: MirrorDockingState, restoreUndockedFrame: Bool, notify: Bool,
        placement: CGRect?, anchor: MirrorDockingAnchor? = nil
    ) {
        let previousState = dockingState
        let previousFrame = frame
        let previousAnchor = dockingAnchor
        if previousState == .undocked, state == .undocked {
            return
        }
        if previousState == .undocked, state != .undocked {
            MirrorDockingState.saveUndockedFrame(frame)
        }
        dockingState = state
        dockingAnchor = state == .undocked
            ? nil
            : (anchor ?? .alignment(MirrorDockAlignment.shortcutDefault(for: state)))
        let succeeded: Bool
        if state == .undocked {
            succeeded = true
            if restoreUndockedFrame {
                let restored = mirrorUndockedFrame(
                    savedFrame: MirrorDockingState.loadUndockedFrame(),
                    defaultFrame: centeredDefaultUndockedFrame(),
                    visibleFrames: NSScreen.screens.map(\.visibleFrame)
                )
                applyWindowFrame(restored)
            }
        } else if let placement {
            applyWindowFrame(placement)
            succeeded = true
        } else {
            succeeded = applyDockingFrame(for: state, notifyFailure: true)
        }
        guard succeeded else {
            dockingState = previousState
            dockingAnchor = previousAnchor
            applyWindowFrame(previousFrame)
            return
        }
        controlBars.forEach { $0.setMirrorDocking(state) }
        if notify { onDockingStateChange?(state) }
    }

    /// Matches the centered frame used immediately after the initial region
    /// selection. It is the fallback when no undocked frame was saved.
    private func centeredDefaultUndockedFrame() -> CGRect {
        let visibleFrame = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let contentFrame = defaultMirrorContentFrame(
            selectionSize: originalContentSize, visibleFrame: visibleFrame
        )
        let windowSize = frameRect(
            forContentRect: CGRect(origin: .zero, size: contentFrame.size)
        ).size
        return CGRect(
            x: visibleFrame.midX - windowSize.width / 2,
            y: visibleFrame.midY - windowSize.height / 2,
            width: windowSize.width, height: windowSize.height
        )
    }

    @discardableResult
    private func applyDockingFrame(
        for state: MirrorDockingState, notifyFailure: Bool
    ) -> Bool {
        let anchor = dockingAnchor ?? .alignment(MirrorDockAlignment.shortcutDefault(for: state))
        guard let placement = mirrorDockedFrame(
            selection: selectionFrame, windowSize: frame.size, state: state,
            visibleFrames: NSScreen.screens.map(\.visibleFrame),
            chromeHeight: mirrorChromeHeight,
            borderOutset: RegionBorderTuning.borderOutset,
            alignment: MirrorDockAlignment.shortcutDefault(for: state),
            anchor: anchor
        ) else {
            if notifyFailure { showCopyConfirmation(title: L10n.text("도킹할 공간이 부족합니다")) }
            return false
        }
        applyWindowFrame(placement.frame)
        return true
    }

    /// Height of the unified titlebar chrome, used to align side-docked
    /// placement against the content area instead of the whole window.
    private var mirrorChromeHeight: CGFloat {
        guard let contentView else { return OverlayControlBarMetrics.height }
        return max(0, frame.height - contentView.frame.height)
    }

    private func applyWindowFrame(_ frame: CGRect) {
        isApplyingDockingFrame = true
        setFrame(frame, display: true)
        isApplyingDockingFrame = false
        onDockingGeometryChange?(dockingState, dockingSeamFrame)
    }

}

@MainActor
private final class MirrorControlBarAccessoryController: NSTitlebarAccessoryViewController {
    private weak var controlBar: OverlayControlBarController?
    private weak var mirrorWindow: NSWindow?
    private weak var hostedView: NSView?
    private var widthConstraint: NSLayoutConstraint?
    private var embedded = false

    init(controlBar: OverlayControlBarController, window: NSWindow) {
        self.controlBar = controlBar
        mirrorWindow = window
        super.init(nibName: nil, bundle: nil)
        layoutAttribute = .left
        view = NSView(frame: .zero)
        preferredContentSize = .zero
    }

    required init?(coder: NSCoder) { nil }

    func setEmbedded(_ value: Bool) {
        guard embedded != value else {
            if value { updateWidth() }
            return
        }
        embedded = value
        guard let controlBar else { return }
        widthConstraint?.isActive = false
        widthConstraint = nil
        if value {
            let hostedView = controlBar.takeContentViewForMirrorToolbar(width: availableWidth)
            hostedView.translatesAutoresizingMaskIntoConstraints = false
            let widthConstraint = hostedView.widthAnchor.constraint(
                equalToConstant: availableWidth
            )
            widthConstraint.isActive = true
            self.widthConstraint = widthConstraint
            self.hostedView = hostedView
            view = hostedView
            preferredContentSize = CGSize(
                width: availableWidth, height: OverlayControlBarMetrics.height
            )
            updateWidth()
        } else {
            hostedView = nil
            view = NSView(frame: .zero)
            preferredContentSize = .zero
            controlBar.releaseContentViewFromMirrorToolbar()
        }
    }

    func updateWidth() {
        guard embedded, let controlBar else { return }
        let width = availableWidth
        widthConstraint?.constant = width
        preferredContentSize = CGSize(
            width: width, height: OverlayControlBarMetrics.height
        )
        controlBar.updateMirrorToolbarWidth(width)
    }

    func ownsTranslationSessionWindow(_ candidate: NSWindow?) -> Bool {
        hostedView?.window === candidate
    }

    func contractViolationsForSelfTest() -> [String] {
        var violations: [String] = []
        if embedded, hostedView == nil || preferredContentSize.height != OverlayControlBarMetrics.height {
            violations.append("mirror control bar must fill the titlebar accessory row")
        }
        if layoutAttribute != .left {
            violations.append("mirror control bar accessory must share the traffic-light row")
        }
        if let hostedView, let mirrorWindow {
            hostedView.superview?.layoutSubtreeIfNeeded()
            let hostedFrame = hostedView.convert(hostedView.bounds, to: nil)
            if hostedFrame.maxX > mirrorWindow.frame.width + 0.5 {
                violations.append("mirror control bar exceeds the titlebar trailing edge")
            }
            if let zoomButton = mirrorWindow.standardWindowButton(.zoomButton),
               let buttonSuperview = zoomButton.superview {
                let buttonFrame = buttonSuperview.convert(zoomButton.frame, to: nil)
                if hostedFrame.minX < buttonFrame.maxX - 0.5 {
                    violations.append("mirror control bar overlaps the traffic-light buttons")
                }
            }
        }
        return violations
    }

    private var availableWidth: CGFloat {
        guard let mirrorWindow else { return 480 }
        let trailingInset: CGFloat = 8
        let fallbackLeadingInset: CGFloat = 84
        let leadingInset: CGFloat
        if let zoomButton = mirrorWindow.standardWindowButton(.zoomButton),
           let buttonSuperview = zoomButton.superview {
            let buttonFrame = buttonSuperview.convert(zoomButton.frame, to: nil)
            leadingInset = buttonFrame.maxX + 8
        } else {
            leadingInset = fallbackLeadingInset
        }
        return max(1, mirrorWindow.frame.width - leadingInset - trailingInset)
    }
}

@MainActor
func mirrorToolbarContractViolationsForSelfTest() -> [String] {
    guard let screen = NSScreen.main ?? NSScreen.screens.first else {
        return ["mirror toolbar: no screen is available for verification"]
    }
    let selection = CGRect(
        x: screen.frame.midX - 320, y: screen.frame.midY - 180,
        width: 640, height: 360
    )
    let window = TranslationMirrorWindow(
        selection: selection,
        screen: screen,
        backgroundOpacity: MirrorBackgroundOpacity.defaultValue,
        displayMode: .mirror,
        overlaySettings: OverlayPresentationSettings.load()
    )
    defer { window.closeForSessionStop() }
    return window.toolbarContractViolationsForSelfTest()
        + window.controlBarModeTransitionContractViolationsForSelfTest()
}
