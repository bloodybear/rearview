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
}

// No AX handles or UI objects cross this queue. All layout uses original line capacity.
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
}
enum AXLineRendering {
    private static let queue = DispatchQueue(label: "Rearview.ax.layout", qos: .userInitiated)
    static func render(_ value: SessionCoordinator.AXTranslatedFrame) async -> AXRenderArtwork {
        let cancellation = AXLayoutCancellation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async { continuation.resume(returning: build(value,isCancelled:{ cancellation.cancelled })) }
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
        for paragraph in value.frame.snapshot.paragraphUnits {
            if isCancelled() { break }
            let entry = value.entries.first { $0.node == paragraph.node }
            let sourceText = paragraph.translationSourceText ?? ""
            let clips = (paragraph.visibleBoxes?.map(\.cgRect) ?? [paragraph.box.cgRect]).map(pixel).map { $0.intersection(bounds) }.filter { !$0.isNull && !$0.isEmpty }
            func excluded(_ reason: String, segment: Int? = nil) {
                diagnostics.append(.init(node:paragraph.node,segment:segment,status:reason,box:pixel(paragraph.box.cgRect)))
            }
            if newline(sourceText), entry?.logicalSegments == nil { excluded("logical_translation_unavailable"); continue }
            guard let entry else { excluded("translation_pending"); continue }
            if entry.status != "translated" && entry.segments?.contains(where: { $0.status == "translated" }) != true && entry.logicalSegments?.contains(where: { $0.status == "translated" }) != true { excluded(entry.status); continue }
            var parts: [AXLogicalRenderPart] = []
            let sources: [(Int?,String,[AXLine],String?)] = paragraph.inlineContent.map { content in
                content.filter { $0.kind == "text" }.map { ($0.id,$0.text ?? "",$0.lineRanges ?? [],$0.lineRangeStatus) }
            } ?? [(nil,sourceText,paragraph.lineRanges,paragraph.lineRangeStatus)]
            var invalid = false
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
                            } else { excluded(value.status,segment:segment) }
                            offset += ((value.translation ?? value.source)+value.delimiter as NSString).length
                        }
                    } catch { excluded("logical_line_mapping_"+String(describing:error),segment:segment); invalid = true; break }
                } else {
                    let translated = segment.flatMap { id in entry.segments?.first { $0.id == id } }
                    let text = segment == nil ? entry.translation : translated?.translation
                    guard (segment == nil ? entry.status : translated?.status) == "translated", let text else { excluded(translated?.status ?? entry.status,segment:segment); continue }
                    parts.append(.init(segment:segment,text:text,lines:lines,fontLines:lines,source:source,logical:nil,itemID:itemID,itemText:text,offset:0))
                }
            }
            if invalid { continue }
            // Color belongs to the whole paragraph, including all text segments
            // around math. Sampling/selection happen once; only drawing is clipped.
            guard let sample = AXRenderColors.backgroundSample(lines:parts.flatMap { $0.lines }.map { pixel($0.box.cgRect) },clips:clips),
                  let sampledBackground = AXRenderColors.sampleBackground(in:image,pixelRect:sample.box,
                    topEdge:sample.top,bottomEdge:sample.bottom) else {
                excluded("background_sample_unavailable"); continue
            }
            let sourceIDs = paragraph.inlineContent.map { $0.filter { $0.kind == "text" }.flatMap { $0.sourceNodes ?? [] } }
                ?? paragraph.lineSourceNodes ?? paragraph.members
            let colors = AXRenderColors.select(background:sampledBackground,sourceIDs:sourceIDs,observations:observations)
            var addedItems = Set<UUID>()
            var fontHeights: [Int:(Double,[AXFontHeight.Decision])] = [:]
            for part in parts {
                let segment = part.segment, text = part.text, lines = part.lines
                if newline(text) { excluded("translation_newline_unsupported",segment:segment); continue }
                guard !lines.isEmpty, !text.isEmpty else { excluded("line_unavailable",segment:segment); continue }
                let ids = paragraph.inlineContent?.first(where: { $0.id == segment })?.sourceNodes ?? paragraph.lineSourceNodes ?? paragraph.members
                let nativeSource = part.source
                var heightDecisions: [AXFontHeight.Decision] = []
                let fontKey = segment ?? -1
                let minHeight: Double
                if let cached = fontHeights[fontKey] { minHeight = cached.0; heightDecisions = cached.1 }
                else {
                    minHeight = AXFontHeight.select(lines:part.fontLines.filter { !MathTranslationPolicy.nonrendering($0.text) },source:nativeSource,ids:ids,nodes:observations,
                        clips:(paragraph.visibleBoxes ?? [paragraph.box]).map(\.cgRect).map { $0.intersection(region) },
                        record:{ heightDecisions.append($0) })
                    fontHeights[fontKey] = (minHeight,heightDecisions)
                }
                guard minHeight >= 8, lines.allSatisfy({ $0.box.width.isFinite && $0.box.width > 0 && $0.box.height.isFinite }) else { excluded("insufficient_line_height",segment:segment); continue }
                let rects = lines.map { pixel($0.box.cgRect) }
                let fontProbe = CTFontCreateUIFontForLanguage(.system,1,nil)!
                let fontHeight = CTFontGetAscent(fontProbe)+CTFontGetDescent(fontProbe)+max(0,CTFontGetLeading(fontProbe))
                let fontSize = CGFloat(minHeight)*sy*0.98/fontHeight
                let font = CTFontCreateCopyWithAttributes(fontProbe,fontSize,nil,nil)
                let attr = NSAttributedString(string:text,attributes:[NSAttributedString.Key(kCTFontAttributeName as String):font,
                    NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String):true])
                let typesetter = CTTypesetterCreateWithAttributedString(attr)
                let string = text as NSString
                func line(_ range: NSRange) -> CTLine { CTTypesetterCreateLine(typesetter,CFRange(location:range.location,length:range.length)) }
                func measured(_ range: NSRange) -> CGFloat { CGFloat(CTLineGetTypographicBounds(line(range),nil,nil,nil)) }
                let total = measured(NSRange(location:0,length:string.length))
                let capacity = rects.reduce(CGFloat(0)) { $0+$1.width }
                guard total.isFinite, total > 0, capacity > 0 else { excluded("measurement_failed",segment:segment); continue }
                let common = min(1,capacity/total)
                var credit: CGFloat = 0, location = 0, scales: [Double] = []
                var hiddenWrapSpaceOffsets: [Int] = []
                let itemID = part.itemID
                var clipped = false
                for (index,rect) in rects.enumerated() {
                    if isCancelled() { break }
                    let allowed = clips.map { $0.intersection(rect) }.filter { !$0.isNull && !$0.isEmpty }
                    clipRects += allowed
                    let area = allowed.reduce(CGFloat(0)) { $0+$1.width*$1.height }
                    clipped = clipped || area+0.01 < rect.width*rect.height
                    for clip in allowed { bg?.setFillColor(colors.background.nsColor.cgColor); bg?.fill(clip) }
                    // Consume exactly one ordinary space at a soft-wrapped line start.
                    // Keep the original string/UTF-16 offsets; additional spaces, tabs and
                    // nonbreaking spaces retain their normal layout and selection geometry.
                    if index > 0, location < string.length, string.character(at:location) == 0x20 {
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
                    }
                    fg?.restoreGState()
                    var offset = location
                    while offset < end {
                        let character = string.rangeOfComposedCharacterSequence(at:offset)
                        let a = CTLineGetOffsetForStringIndex(ctLine,offset,nil)
                        let b = CTLineGetOffsetForStringIndex(ctLine,NSMaxRange(character),nil)
                        let box = CGRect(x:rect.minX+min(a,b)*scale,y:baseline-descent,width:max(0.1,abs(b-a)*scale),height:ascent+descent)
                        if allowed.contains(where: { $0.intersects(box) }) {
                            fragments.append(.init(itemID:itemID,text:string.substring(with:character),rect:box,characterOffset:part.offset+offset))
                        }
                        offset = NSMaxRange(character)
                    }
                    location = end
                }
                if addedItems.insert(itemID).inserted {
                    items.append(MirrorItem(id:itemID,translatedText:part.itemText,presentation:.translated,
                        normalizedRect:normalized(pixel(paragraph.box.cgRect)),background:colors.background,foreground:colors.foreground))
                }
                diagnostics.append(.init(node:paragraph.node,segment:segment,status:"rendered",box:pixel(paragraph.box.cgRect),logicalIndex:part.logical?.logicalIndex,sourceRangeStart:part.logical?.rangeStart,sourceRangeLength:part.logical?.rangeLength,fontSize:Double(fontSize),commonScale:Double(common),lineScales:scales,hiddenWrapSpaceOffsets:hiddenWrapSpaceOffsets,clipped:clipped,lineBoxes:rects,heightRatio:(lines.map { $0.box.height }.max() ?? minHeight)/minHeight,
                    selectedFontHeight:minHeight,fontHeightDecisions:heightDecisions,backgroundColor:[Double(colors.background.red),Double(colors.background.green),Double(colors.background.blue)],
                    foregroundColor:[Double(colors.foreground.red),Double(colors.foreground.green),Double(colors.foreground.blue)],
                    backgroundSample:sample,foregroundSource:colors.foregroundSource,foregroundContrast:colors.contrast))
            }
            if entry.logicalSegments != nil {
                // Attach real hard breaks to adjacent visible characters. They use
                // no new hit boxes and preserve exact copy/search UTF-16 offsets.
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
                            if candidate.unicodeScalars.allSatisfy({ CharacterSet.newlines.contains($0) }) { prefix = candidate }
                        }
                        let suffix = gap.unicodeScalars.allSatisfy({ CharacterSet.newlines.contains($0) }) ? gap : ""
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
            case "skipped_non_source_language", "preserved_by_policy", "nonrendering_text": color = .systemBlue
            case "insufficient_line_height": color = .systemYellow
            default: color = .systemRed
            }
            debug?.setStrokeColor(color.cgColor); debug?.setLineWidth(2); debug?.stroke(d.box)
            debug?.setStrokeColor(NSColor.cyan.cgColor); debug?.setLineWidth(1)
            for box in d.lineBoxes { debug?.stroke(box) }
        }
        debug?.setStrokeColor(NSColor.orange.cgColor)
        for box in clipRects { debug?.stroke(box) }
        return AXRenderArtwork(background:bg?.makeImage(),text:fg?.makeImage(),debug:debug?.makeImage(),items:items,fragments:fragments,clipRects:clipRects,diagnostics:diagnostics,elapsed:CFAbsoluteTimeGetCurrent()-start)
    }
}
