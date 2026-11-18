import AppKit
import CoreText
import NotionAXCore

struct AXRenderDiagnostic: Codable, Sendable {
    let node: Int
    let segment: Int?
    let status: String
    let box: CGRect
    var logicalIndex: Int?
    var sourceRangeStart: Int?
    var sourceRangeLength: Int?
    var fontSize: Double = 0
    var commonScale: Double = 1
    var lineScales: [Double] = []
    var hiddenWrapSpaceOffsets: [Int] = []
    var clipped = false
    var lineBoxes: [CGRect] = []
    var originalLineBoxes: [CGRect]?
    var heightRatio: Double = 1
    var selectedFontHeight: Double?
    var fontHeightDecisions: [AXFontHeight.Decision]?
    var backgroundColor, foregroundColor: [Double]?
    var backgroundSample: AXRenderColors.BackgroundSample?
    var foregroundSource: String?
    var foregroundContrast: Double?
}

struct AXRenderArtwork: @unchecked Sendable {
    let identity = UUID()
    let background: CGImage?
    let text: CGImage?
    let debug: CGImage?
    let items: [MirrorItem]
    let fragments: [NativeMirrorRenderedFragment]
    let clipRects: [CGRect]
    let diagnostics: [AXRenderDiagnostic]
    let elapsed: Double
    var selectionClipRects: [CGRect] = []
    var itemNodes: [UUID:Int] = [:]
    var bodyReuseSeconds: Double = 0
    var fullTextHover: [AXFullTextHover] = []
}

// No AX handles or UI objects cross this queue. Native geometry stays immutable;
// plain text blocks may provide a wider, separately recorded layout capacity.
private final class AXLayoutCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func cancel() { lock.lock(); value = true; lock.unlock() }
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
}
private struct AXLogicalRenderPart {
    let segment: Int?
    let text: String
    let lines: [AXLine]
    let fontLines: [AXLine]
    let source: String
    let logical: AXLogicalTranslation?
    let itemID: UUID
    let itemText: String
    let offset: Int
    var code: AXCodeSegment? = nil
}
struct AXFullTextHover: Codable, Sendable {
    let itemID: UUID
    let text: String
    let boxes: [CGRect]
    static func isClipped(_ box: CGRect, by clips: [CGRect]) -> Bool {
        let inner = box.insetBy(dx:min(0.5,box.width/4),dy:min(0.5,box.height/4))
        if clips.contains(where: { $0.contains(inner) }) { return false }
        return !clips.reduce([inner]) { rest, clip in rest.flatMap { AXBodyRetention.subtract($0,clip) } }.isEmpty
    }
}
enum AXLineRendering {
    static func layoutBox(_ box: CGRect, expansionRight: Double?) -> CGRect {
        guard let right = expansionRight, right.isFinite else { return box }
        return CGRect(x:box.minX,y:box.minY,width:max(box.width,CGFloat(right)-box.minX),height:box.height)
    }

    private static let queue = DispatchQueue(label: "Rearview.ax.layout", qos: .userInitiated)
    static func render(_ value: SessionCoordinator.AXTranslatedFrame) async -> AXRenderArtwork {
        let cancellation = AXLayoutCancellation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async {
                    let built=build(value,isCancelled:{ cancellation.cancelled })
                    continuation.resume(returning:built.adding(value.retainedBody,size:CGSize(width:value.frame.image.width,height:value.frame.image.height)))
                }
            }
        } onCancel: { cancellation.cancel() }
    }
    static func build(_ value: SessionCoordinator.AXTranslatedFrame, isCancelled: () -> Bool = { false }) -> AXRenderArtwork {
        let start = CFAbsoluteTimeGetCurrent()
        let image = value.frame.image, width = image.width, height = image.height
        func context() -> CGContext? {
            CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:0,
                space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)
        }
        let bg = context(), fg = context(), debug = context()
        var selectionClips: [CGRect] = []
        var clipRects: [CGRect] = []
        var diagnostics: [AXRenderDiagnostic] = [], items: [MirrorItem] = [], fragments: [NativeMirrorRenderedFragment] = []
        let observations = Dictionary(uniqueKeysWithValues:value.frame.snapshot.observations.map { ($0.id,$0) })
        let metadata = (try? JSONSerialization.jsonObject(with:value.frame.snapshot.metadata)) as? [String:Any]
        let selection = metadata?["selectionRegion"] as? [String:Double] ?? [:]
        let region = CGRect(x:selection["x"] ?? 0,y:selection["y"] ?? 0,
            width:selection["width"] ?? Double(width),height:selection["height"] ?? Double(height))
        let sx = CGFloat(width) / max(1,region.width), sy = CGFloat(height) / max(1,region.height)
        let bounds = CGRect(x:0,y:0,width:width,height:height)
        func pixel(_ r: CGRect) -> CGRect {
            CGRect(x:(r.minX-region.minX)*sx,y:CGFloat(height)-(r.maxY-region.minY)*sy,width:r.width*sx,height:r.height*sy)
        }
        func normalized(_ r: CGRect) -> CGRect {
            CGRect(x:r.minX/CGFloat(width),y:r.minY/CGFloat(height),width:r.width/CGFloat(width),height:r.height/CGFloat(height))
        }
        func newline(_ text: String) -> Bool { text.rangeOfCharacter(from:.newlines) != nil }
        func isCut(_ box: CGRect, _ clips: [CGRect]) -> Bool {
            AXFullTextHover.isClipped(box,by:clips)
        }
        var hover: [AXFullTextHover] = []
        var itemNodes: [UUID:Int] = [:]
        for paragraph in value.frame.snapshot.paragraphUnits {
            let firstItem=items.count
            let firstHover=hover.count
            defer {
                for item in items.dropFirst(firstItem) { itemNodes[item.id]=paragraph.node }
                if !paragraph.isCodeBlock, hover.count > firstHover {
                    let entry = value.entries.first { $0.node == paragraph.node }
                    let full: String
                    if let content = paragraph.inlineContent {
                        full = content.map { part in
                            if part.kind != "text" { return part.text ?? "" }
                            if let logical = entry?.logicalSegments {
                                return logical.filter { $0.sourcePart == part.id }.map { ($0.translation ?? $0.source)+$0.delimiter }.joined()
                            }
                            return entry?.segments?.first { $0.id == part.id }?.translation ?? part.text ?? ""
                        }.joined()
                    } else if let logical = entry?.logicalSegments {
                        full = logical.map { ($0.translation ?? $0.source)+$0.delimiter }.joined()
                    } else { full = entry?.translation ?? paragraph.translationSourceText ?? paragraph.text }
                    let lineBoxes = (paragraph.inlineContent?.flatMap { $0.lineRanges ?? [] } ?? paragraph.lineRanges).map { pixel($0.box.cgRect) }
                    let hoverBoxes = lineBoxes.flatMap { line in paragraph.displayRegions.map { pixel($0.cgRect).intersection(bounds).intersection(line) }.filter { !$0.isNull && !$0.isEmpty } }
                    for index in firstHover..<hover.count {
                        hover[index] = .init(itemID:hover[index].itemID,text:full,boxes:hoverBoxes)
                    }
                }
            }
            if isCancelled() { break }
            let entry = value.entries.first { $0.node == paragraph.node }
            let sourceText = paragraph.translationSourceText ?? ""
            let clips = paragraph.displayRegions.map(\.cgRect).map(pixel).map { $0.intersection(bounds) }.filter { !$0.isNull && !$0.isEmpty }
            func excluded(_ reason: String, segment: Int? = nil) {
                diagnostics.append(.init(node:paragraph.node,segment:segment,status:reason,box:pixel(paragraph.box.cgRect)))
            }
            func preserve(_ source: String, lines: [AXLine], itemID: UUID = UUID(), itemText: String? = nil, offset: Int = 0) {
                let ns = source as NSString
                var selected: [NativeMirrorRenderedFragment] = []
                var cut = false
                var visible: [CGRect] = []
                for line in lines {
                    let start = line.segmentRangeStart ?? line.rangeStart
                    guard start >= 0, line.rangeLength > 0, start <= ns.length,
                          line.rangeLength <= ns.length-start,
                          ns.substring(with:NSRange(location:start,length:line.rangeLength)) == line.text else { continue }
                    let box = pixel(line.box.cgRect)
                    guard box.width.isFinite, box.height.isFinite, box.width > 0, box.height > 0 else { continue }
                    visible += clips.map { $0.intersection(box) }.filter { !$0.isNull && !$0.isEmpty }
                    var local = 0
                    let text = line.text as NSString
                    while local < text.length {
                        let range = text.rangeOfComposedCharacterSequence(at:local)
                        let r = CGRect(x:box.minX+box.width*CGFloat(local)/CGFloat(text.length),y:box.minY,
                            width:box.width*CGFloat(range.length)/CGFloat(text.length),height:box.height)
                        if !cut && !text.substring(with:range).trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && isCut(r, clips) { cut = true }
                        if clips.contains(where: { $0.intersects(r) }) {
                            selected.append(.init(itemID:itemID,text:text.substring(with:range),rect:r,characterOffset:offset+start+local))
                        }
                        local = NSMaxRange(range)
                    }
                }
                guard !selected.isEmpty else { return }
                if cut { hover.append(.init(itemID:itemID,text:itemText ?? source,boxes:visible)) }
                fragments += selected
                if !items.contains(where: { $0.id == itemID }) {
                    items.append(MirrorItem(id:itemID,translatedText:itemText ?? source,presentation:.selectionOnly,
                        normalizedRect:normalized(pixel(paragraph.box.cgRect)),background:.lightBackground,foreground:.darkText))
                }
                selectionClips += clips
            }
            var parts: [AXLogicalRenderPart] = []
            var invalid = false
            var codeItemID: UUID?
            var fontHeights: [Int:(Double,[AXFontHeight.Decision])] = [:]
            var colorCache: [Int:(AXRenderColors.BackgroundSample,AXRenderColors)] = [:]
            let codeMode = paragraph.isCodeBlock && entry?.sourceLanguage != "ko"
            if codeMode {
                guard let runs = paragraph.codeSegments, !runs.isEmpty else { excluded("code_geometry_unavailable"); continue }
                let itemID = UUID(); codeItemID = itemID
                var offset = 0
                var heightDecisions: [AXFontHeight.Decision] = []
                let height = AXFontHeight.select(lines:paragraph.lineRanges.filter { !MathTranslationPolicy.nonrendering($0.text) },
                    source:sourceText,ids:paragraph.lineSourceNodes ?? paragraph.members,nodes:observations,
                    clips:paragraph.baseDisplayRegions.map(\.cgRect).map { $0.intersection(region) },
                    record:{ heightDecisions.append($0) })
                fontHeights[-2]=(height,heightDecisions)
                var paintable = Set<Int>(), paintFailures: [Int:String] = [:]
                for run in runs where run.translates && run.status == "complete" {
                    guard let translated = entry?.codeTranslations?.first(where: { $0.id == run.id && $0.source == run.text }),
                          translated.status == "translated", let text = translated.translation, !text.isEmpty else { continue }
                    guard height >= 8 else { paintFailures[run.id]="insufficient_line_height";continue }
                    guard !newline(text), !run.pieces.isEmpty,
                          run.pieces.allSatisfy({ ($0.status == "complete" && $0.box != nil) || $0.status == "nonrendering_text" }) else {
                        paintFailures[run.id]="code_geometry_unavailable";continue
                    }
                    let boxes = run.pieces.compactMap { $0.box }.map { pixel($0.cgRect) }
                    guard let sample = AXRenderColors.backgroundSample(lines:boxes,clips:clips),
                          let sampled = AXRenderColors.sampleBackground(in:image,pixelRect:sample.box,topEdge:sample.top,bottomEdge:sample.bottom) else {
                        paintFailures[run.id]="background_sample_unavailable";continue
                    }
                    colorCache[run.id]=(sample,AXRenderColors.select(background:sampled,sourceIDs:[],observations:[:],uniformOverride:run.style.foregroundColor))
                    paintable.insert(run.id)
                }
                let outputs = runs.map { run -> String in
                    let translated = entry?.codeTranslations?.first { $0.id == run.id && $0.source == run.text }
                    return paintable.contains(run.id) ? translated?.translation ?? run.text : run.text
                }
                let itemText = outputs.joined()
                items.append(MirrorItem(id:itemID,translatedText:itemText,presentation:.translated,
                    normalizedRect:normalized(pixel(paragraph.box.cgRect)),background:.lightBackground,foreground:.darkText))
                for (index,run) in runs.enumerated() {
                    let translated = entry?.codeTranslations?.first { $0.id == run.id && $0.source == run.text }
                    let paint = paintable.contains(run.id)
                    let lines: [AXLine] = run.pieces.compactMap { piece -> AXLine? in
                        guard let box = piece.box, piece.status == "complete" else { return nil }
                        return AXLine(text:piece.text,rangeStart:piece.rangeStart-run.rangeStart,rangeLength:piece.rangeLength,
                            box:box,line:nil,segment:nil,segmentRangeStart:nil)
                    }
                    if paint {
                        parts.append(.init(segment:run.id,text:outputs[index],lines:lines,fontLines:paragraph.lineRanges,
                            source:sourceText,logical:nil,itemID:itemID,itemText:itemText,offset:offset,code:run))
                    } else {
                        var codeCut = false
                        var codeHoverBoxes: [CGRect] = []
                        for piece in run.pieces {
                            guard let raw = piece.box, piece.status == "complete" else { continue }
                            let box = pixel(raw.cgRect), text = piece.text as NSString
                            codeHoverBoxes += clips.map { $0.intersection(box) }.filter { !$0.isNull && !$0.isEmpty }
                            var local = 0
                            while local < text.length {
                                let range = text.rangeOfComposedCharacterSequence(at:local)
                                let r = CGRect(x:box.minX+box.width*CGFloat(local)/CGFloat(text.length),y:box.minY,
                                    width:box.width*CGFloat(range.length)/CGFloat(text.length),height:box.height)
                                if !codeCut && !text.substring(with:range).trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && isCut(r,clips) { codeCut = true }
                                if clips.contains(where: { $0.intersects(r) }) {
                                    fragments.append(.init(itemID:itemID,text:text.substring(with:range),rect:r,
                                        characterOffset:offset+piece.rangeStart-run.rangeStart+local))
                                }
                                local = NSMaxRange(range)
                            }
                        }
                        if codeCut && !codeHoverBoxes.isEmpty { hover.append(.init(itemID:itemID,text:run.text,boxes:codeHoverBoxes)) }
                        diagnostics.append(.init(node:paragraph.node,segment:run.id,
                            status:run.translates ? (paintFailures[run.id] ?? (run.status != "complete" ? "code_geometry_unavailable" : translated?.status ?? "translation_pending")) : "preserved_source",
                            box:pixel(paragraph.box.cgRect),sourceRangeStart:run.rangeStart,sourceRangeLength:run.rangeLength,
                            lineBoxes:lines.map { pixel($0.box.cgRect) }))
                    }
                    offset += (outputs[index] as NSString).length
                }
            } else {
                if entry?.status == "skipped_non_source_language" {
                    if let content = paragraph.inlineContent {
                        for part in content where part.kind == "text" { preserve(part.text ?? "",lines:part.lineRanges ?? []) }
                    } else { preserve(sourceText,lines:paragraph.lineRanges) }
                    excluded("skipped_non_source_language"); continue
                }
                if newline(sourceText), entry?.logicalSegments == nil { excluded("logical_translation_unavailable"); continue }
                guard let entry else { excluded("translation_pending"); continue }
                if entry.status != "translated" && entry.segments?.contains(where: { $0.status == "translated" }) != true && entry.logicalSegments?.contains(where: { $0.status == "translated" }) != true { excluded(entry.status); continue }
                let sources: [(Int?,String,[AXLine],String?)] = paragraph.inlineContent.map { content in
                    content.filter { $0.kind == "text" }.map { ($0.id,$0.text ?? "",$0.lineRanges ?? [],$0.lineRangeStatus) }
                } ?? [(nil,sourceText,paragraph.lineRanges,paragraph.lineRangeStatus)]
                for (segment,source,lines,status) in sources {
                    if let status, status != "complete_unverified" && status != "nonrendering_text" { excluded("line_"+status,segment:segment); invalid = true; break }
                    let itemID = UUID()
                    if let logical = entry.logicalSegments {
                        let values = logical.filter { $0.sourcePart == segment }
                        do {
                            let mapping = try AXLogicalLines.split(source,lines:lines)
                            guard values.count == mapping.count else { throw AXLogicalLines.Failure.textMismatch }
                            let itemText = values.map { ($0.translation ?? $0.source)+$0.delimiter }.joined()
                            var offset = 0
                            for (value,map) in zip(values,mapping) {
                                guard value.source == map.text, value.rangeStart == map.range.location,
                                      value.rangeLength == map.range.length, value.delimiter == map.delimiter else { throw AXLogicalLines.Failure.textMismatch }
                                if value.status == "translated", let text = value.translation, !text.isEmpty {
                                    parts.append(.init(segment:segment,text:text,lines:map.lineIndices.map { lines[$0] },fontLines:lines,source:source,logical:value,itemID:itemID,itemText:itemText,offset:offset))
                                } else if value.status == "skipped_non_source_language" {
                                    let shifted = map.lineIndices.map { lines[$0] }
                                    preserve(source,lines:shifted,itemID:itemID,itemText:itemText,offset:offset-value.rangeStart)
                                } else { excluded(value.status,segment:segment) }
                                offset += ((value.translation ?? value.source)+value.delimiter as NSString).length
                            }
                        } catch { excluded("logical_line_mapping_"+String(describing:error),segment:segment); invalid = true; break }
                    } else {
                        let translated = segment.flatMap { id in entry.segments?.first { $0.id == id } }
                        let text = segment == nil ? entry.translation : translated?.translation
                        if translated?.status == "skipped_non_source_language" { preserve(source,lines:lines); continue }
                        guard (segment == nil ? entry.status : translated?.status) == "translated", let text else { excluded(translated?.status ?? entry.status,segment:segment); continue }
                        parts.append(.init(segment:segment,text:text,lines:lines,fontLines:lines,source:source,logical:nil,itemID:itemID,itemText:text,offset:0))
                    }
                }
            }
            if invalid { continue }
            // Color belongs to the whole paragraph, including all text segments
            // around math. Sampling/selection happen once; only drawing is clipped.
            var addedItems = Set<UUID>()
            if let codeItemID { addedItems.insert(codeItemID) }
            for part in parts {
                let colorKey = part.code?.id ?? -1
                let sample: AXRenderColors.BackgroundSample, colors: AXRenderColors
                if let cached = colorCache[colorKey] { (sample,colors)=cached }
                else {
                    let sampleLines = part.code == nil ? parts.flatMap { $0.lines } : part.lines
                    guard let selectedSample = AXRenderColors.backgroundSample(lines:sampleLines.map { pixel($0.box.cgRect) },clips:clips),
                          let sampledBackground = AXRenderColors.sampleBackground(in:image,pixelRect:selectedSample.box,
                            topEdge:selectedSample.top,bottomEdge:selectedSample.bottom) else { excluded("background_sample_unavailable",segment:part.segment); continue }
                    let sourceIDs = paragraph.inlineContent.map { $0.filter { $0.kind == "text" }.flatMap { $0.sourceNodes ?? [] } }
                        ?? paragraph.lineSourceNodes ?? paragraph.members
                    let selectedColors = part.code.map { AXRenderColors.select(background:sampledBackground,sourceIDs:[],observations:[:],
                        uniformOverride:$0.style.foregroundColor) } ?? AXRenderColors.select(background:sampledBackground,sourceIDs:sourceIDs,observations:observations)
                    sample=selectedSample;colors=selectedColors;colorCache[colorKey]=(sample,colors)
                }
                let segment = part.segment, text = part.text, lines = part.lines
                if newline(text) { excluded("translation_newline_unsupported",segment:segment); continue }
                guard !lines.isEmpty, !text.isEmpty else { excluded("line_unavailable",segment:segment); continue }
                let ids = paragraph.inlineContent?.first(where: { $0.id == segment })?.sourceNodes ?? paragraph.lineSourceNodes ?? paragraph.members
                let nativeSource = part.source
                var heightDecisions: [AXFontHeight.Decision] = []
                let fontKey = part.code == nil ? segment ?? -1 : -2
                let minHeight: Double
                if let cached = fontHeights[fontKey] { minHeight = cached.0; heightDecisions = cached.1 }
                else {
                    minHeight = AXFontHeight.select(lines:part.fontLines.filter { !MathTranslationPolicy.nonrendering($0.text) },source:nativeSource,ids:ids,nodes:observations,
                        clips:paragraph.baseDisplayRegions.map(\.cgRect).map { $0.intersection(region) },
                        record:{ heightDecisions.append($0) })
                    fontHeights[fontKey] = (minHeight,heightDecisions)
                }
                guard minHeight >= 8, lines.allSatisfy({ $0.box.width.isFinite && $0.box.width > 0 && $0.box.height.isFinite }) else { excluded("insufficient_line_height",segment:segment); continue }
                let originalRects = lines.map { pixel($0.box.cgRect) }
                let rects = lines.map { line in
                    pixel(Self.layoutBox(line.box.cgRect, expansionRight:part.code == nil && part.segment == nil ? paragraph.layoutExpansionRight : nil))
                }
                let fontProbe = CTFontCreateUIFontForLanguage(.system,1,nil)!
                let fontHeight = CTFontGetAscent(fontProbe)+CTFontGetDescent(fontProbe)+max(0,CTFontGetLeading(fontProbe))
                let fontSize = CGFloat(minHeight)*sy*0.98/fontHeight
                var font = CTFontCreateCopyWithAttributes(fontProbe,fontSize,nil,nil)
                var traits: CTFontSymbolicTraits = []
                if part.code?.style.bold == true { traits.insert(.traitBold) }
                if part.code?.style.italic == true { traits.insert(.traitItalic) }
                if !traits.isEmpty, let styled = CTFontCreateCopyWithSymbolicTraits(font,fontSize,nil,traits,traits) { font=styled }
                let attributes: [NSAttributedString.Key:Any] = [NSAttributedString.Key(kCTFontAttributeName as String):font,
                    NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String):true]
                let attr = NSAttributedString(string:text,attributes:attributes)
                let typesetter = CTTypesetterCreateWithAttributedString(attr)
                let string = text as NSString
                func line(_ range: NSRange) -> CTLine { CTTypesetterCreateLine(typesetter,CFRange(location:range.location,length:range.length)) }
                func measured(_ range: NSRange) -> CGFloat { CGFloat(CTLineGetTypographicBounds(line(range),nil,nil,nil)) }
                let total = measured(NSRange(location:0,length:string.length))
                let capacity = rects.reduce(CGFloat(0)) { $0+$1.width }
                guard total.isFinite, total > 0, capacity > 0 else { excluded("measurement_failed",segment:segment); continue }
                let common = min(1,capacity/total)
                // Seed the same budget with unused capacity before any line compresses.
                // Later line-end gaps spend it; local compression replenishes it.
                var credit: CGFloat = max(0,capacity-total*common), location = 0, scales: [Double] = []
                var hiddenWrapSpaceOffsets: [Int] = []
                let itemID = part.itemID
                var clipped = false
                var glyphCut = false
                var hoverBoxes: [CGRect] = []
                for (index,rect) in rects.enumerated() {
                    if isCancelled() { break }
                    let allowed = clips.map { $0.intersection(rect) }.filter { !$0.isNull && !$0.isEmpty }
                    clipRects += allowed
                    hoverBoxes += allowed
                    let area = allowed.reduce(CGFloat(0)) { $0+$1.width*$1.height }
                    clipped = clipped || area+0.01 < rect.width*rect.height
                    for clip in allowed {
                        bg?.setFillColor(colors.background.nsColor.cgColor)
                        let sourceMask = clip.intersection(originalRects[index])
                        if !sourceMask.isNull && !sourceMask.isEmpty { bg?.fill(sourceMask) }
                    }
                    // Consume exactly one ordinary space at a soft-wrapped line start.
                    // Keep the original string/UTF-16 offsets; additional spaces, tabs and
                    // nonbreaking spaces retain their normal layout and selection geometry.
                    if part.code == nil, index > 0, location < string.length, string.character(at:location) == 0x20 {
                        hiddenWrapSpaceOffsets.append(location)
                        // A minimal selection anchor preserves copy/search continuity
                        // without drawing the space or advancing the text position.
                        let anchor = CGRect(x:rect.minX,y:rect.minY,width:0.1,height:rect.height)
                        if allowed.contains(where: { $0.intersects(anchor) }) {
                            fragments.append(.init(itemID:itemID,text:" ",rect:anchor,characterOffset:part.offset+location))
                        }
                        location += 1
                    }
                    guard location < string.length else { continue }
                    let end: Int
                    if index == rects.count-1 {
                        end = string.length
                    } else {
                        let suggestion = CTTypesetterSuggestClusterBreak(typesetter,location,Double(rect.width/common))
                        var boundary = min(string.length,location+suggestion)
                        if boundary < string.length {
                            let composed = string.rangeOfComposedCharacterSequence(at:boundary)
                            if composed.location < boundary { boundary = composed.location }
                        }
                        boundary = max(location,boundary)
                        let a = measured(NSRange(location:location,length:boundary-location))*common
                        let slack = max(0,rect.width-a)
                        if boundary == string.length {
                            end = boundary
                        } else if boundary > location && slack <= credit {
                            end = boundary; credit -= slack
                        } else {
                            let next = string.rangeOfComposedCharacterSequence(at:min(boundary,string.length-1))
                            end = NSMaxRange(next)
                            let b = measured(NSRange(location:location,length:end-location))*common
                            credit += max(0,b-rect.width)
                        }
                    }
                    let range = NSRange(location:location,length:end-location)
                    let ctLine = line(range)
                    let natural = CGFloat(CTLineGetTypographicBounds(ctLine,nil,nil,nil))
                    let scale = min(common,rect.width/max(0.0001,natural))
                    let painted = CGRect(x:rect.minX,y:rect.minY,width:min(rect.width,natural*scale),height:rect.height)
                    for clip in allowed {
                        let translatedMask = clip.intersection(painted)
                        if !translatedMask.isNull && !translatedMask.isEmpty { bg?.fill(translatedMask) }
                    }
                    scales.append(Double(scale/common))
                    var ascent: CGFloat = 0, descent: CGFloat = 0
                    _ = CTLineGetTypographicBounds(ctLine,&ascent,&descent,nil)
                    let baseline = rect.midY-(ascent-descent)/2
                    fg?.saveGState()
                    if let fg, !allowed.isEmpty {
                        fg.addRects(allowed); fg.clip()
                        fg.translateBy(x:rect.minX,y:baseline); fg.scaleBy(x:scale,y:1)
                        fg.setFillColor(colors.foreground.nsColor.cgColor)
                        fg.textPosition = .zero; CTLineDraw(ctLine,fg)
                        if part.code?.style.underline == true || part.code?.style.strikethrough == true {
                            fg.setStrokeColor(colors.foreground.nsColor.cgColor)
                            fg.setLineWidth(max(0.5,CTFontGetUnderlineThickness(font)))
                            if part.code?.style.underline == true {
                                let y = CTFontGetUnderlinePosition(font)
                                fg.move(to:CGPoint(x:0,y:y));fg.addLine(to:CGPoint(x:natural,y:y))
                            }
                            if part.code?.style.strikethrough == true {
                                let y = CTFontGetXHeight(font)*0.5
                                fg.move(to:CGPoint(x:0,y:y));fg.addLine(to:CGPoint(x:natural,y:y))
                            }
                            fg.strokePath()
                        }
                    }
                    fg?.restoreGState()
                    var offset = location
                    while offset < end {
                        let character = string.rangeOfComposedCharacterSequence(at:offset)
                        let a = CTLineGetOffsetForStringIndex(ctLine,offset,nil)
                        let b = CTLineGetOffsetForStringIndex(ctLine,NSMaxRange(character),nil)
                        let box = CGRect(x:rect.minX+min(a,b)*scale,y:baseline-descent,width:max(0.1,abs(b-a)*scale),height:ascent+descent)
                        if !glyphCut && !string.substring(with:character).trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && isCut(box,clips) { glyphCut = true }
                        if allowed.contains(where: { $0.intersects(box) }) {
                            fragments.append(.init(itemID:itemID,text:string.substring(with:character),rect:box,characterOffset:part.offset+offset))
                        }
                        offset = NSMaxRange(character)
                    }
                    location = end
                }
                if glyphCut && !hoverBoxes.isEmpty { hover.append(.init(itemID:itemID,text:part.code == nil ? part.itemText : part.text,boxes:hoverBoxes)) }
                if addedItems.insert(itemID).inserted && !items.contains(where: { $0.id == itemID }) {
                    items.append(MirrorItem(id:itemID,translatedText:part.itemText,presentation:.translated,
                        normalizedRect:normalized(pixel(paragraph.box.cgRect)),background:colors.background,foreground:colors.foreground))
                }
                diagnostics.append(.init(node:paragraph.node,segment:segment,status:"rendered",box:pixel(paragraph.box.cgRect),logicalIndex:part.logical?.logicalIndex,sourceRangeStart:part.code?.rangeStart ?? part.logical?.rangeStart,sourceRangeLength:part.code?.rangeLength ?? part.logical?.rangeLength,fontSize:Double(fontSize),commonScale:Double(common),lineScales:scales,hiddenWrapSpaceOffsets:hiddenWrapSpaceOffsets,clipped:clipped,lineBoxes:rects,originalLineBoxes:originalRects,heightRatio:(lines.map { $0.box.height }.max() ?? minHeight)/minHeight,
                    selectedFontHeight:minHeight,fontHeightDecisions:heightDecisions,backgroundColor:[Double(colors.background.red),Double(colors.background.green),Double(colors.background.blue)],
                    foregroundColor:[Double(colors.foreground.red),Double(colors.foreground.green),Double(colors.foreground.blue)],
                    backgroundSample:sample,foregroundSource:colors.foregroundSource,foregroundContrast:colors.contrast))
            }
            if entry?.logicalSegments != nil || codeMode {
                let order = Dictionary(uniqueKeysWithValues:items.enumerated().map { ($0.element.id,$0.offset) })
                fragments.sort { $0.itemID == $1.itemID ? $0.characterOffset < $1.characterOffset : (order[$0.itemID] ?? 0) < (order[$1.itemID] ?? 0) }
                // Attach real hard breaks to adjacent visible characters. They use
                // no new hit boxes and preserve exact copy/search UTF-16 offsets.
                let attachable = codeMode ? CharacterSet.whitespacesAndNewlines : CharacterSet.newlines
                for item in items where addedItems.contains(item.id) {
                    let string = item.translatedText as NSString
                    let indices = fragments.indices.filter { fragments[$0].itemID == item.id }
                    for (position,index) in indices.enumerated() {
                        let fragment = fragments[index]
                        let end = fragment.characterOffset+(fragment.text as NSString).length
                        let next = position+1 < indices.count ? fragments[indices[position+1]].characterOffset : string.length
                        guard end <= next, next <= string.length else { continue }
                        let gap = string.substring(with:NSRange(location:end,length:next-end))
                        var prefix = ""
                        if position == 0, fragment.characterOffset > 0 {
                            let candidate = string.substring(to:fragment.characterOffset)
                            if candidate.unicodeScalars.allSatisfy({ attachable.contains($0) }) { prefix = candidate }
                        }
                        let suffix = gap.unicodeScalars.allSatisfy({ attachable.contains($0) }) ? gap : ""
                        fragments[index] = .init(itemID:item.id,text:prefix+fragment.text+suffix,rect:fragment.rect,
                            characterOffset:fragment.characterOffset-(prefix as NSString).length)
                    }
                }
            }
        }
        for d in diagnostics {
            let color: NSColor
            switch d.status {
            case "rendered": color = d.clipped ? .orange : .systemGreen
            case "source_newline_unsupported", "translation_newline_unsupported": color = .systemPurple
            case "translation_pending": color = .systemGray
            case "skipped_non_source_language", "preserved_by_policy", "nonrendering_text", "preserved_source": color = .systemBlue
            case "insufficient_line_height": color = .systemYellow
            default: color = .systemRed
            }
            debug?.setStrokeColor(color.cgColor); debug?.setLineWidth(2); debug?.stroke(d.box)
            debug?.setStrokeColor(NSColor.systemPink.cgColor); debug?.setLineWidth(1)
            for box in d.originalLineBoxes ?? [] { debug?.stroke(box) }
            debug?.setStrokeColor(NSColor.cyan.cgColor); debug?.setLineWidth(1)
            for box in d.lineBoxes {
                if d.status == "preserved_source" { debug?.setStrokeColor(NSColor.systemBlue.cgColor) }
                debug?.stroke(box)
            }
        }
        debug?.setStrokeColor(NSColor.orange.cgColor)
        for box in clipRects { debug?.stroke(box) }
        return AXRenderArtwork(background:bg?.makeImage(),text:fg?.makeImage(),debug:debug?.makeImage(),items:items,fragments:fragments,clipRects:clipRects,diagnostics:diagnostics,elapsed:CFAbsoluteTimeGetCurrent()-start,selectionClipRects:selectionClips,itemNodes:itemNodes,fullTextHover:hover)
    }
}
