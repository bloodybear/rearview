import AppKit
import CoreText
import NotionAXCore

struct AXRenderDiagnostic: Codable, Sendable {
    let node: Int
    let segment: Int?
    let status: String
    let box: CGRect
    var fontSize: Double = 0
    var commonScale: Double = 1
    var lineScales: [Double] = []
    var clipped = false
    var lineBoxes: [CGRect] = []
    var heightRatio: Double = 1
    var backgroundColor, foregroundColor: [Double]?
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
            let sourceText = paragraph.inlineContent.map { $0.filter { $0.kind == "text" }.map { $0.text ?? "" }.joined() } ?? paragraph.text
            let clips = (paragraph.visibleBoxes?.map(\.cgRect) ?? [paragraph.box.cgRect]).map(pixel).map { $0.intersection(bounds) }.filter { !$0.isNull && !$0.isEmpty }
            func excluded(_ reason: String, segment: Int? = nil) {
                diagnostics.append(.init(node:paragraph.node,segment:segment,status:reason,box:pixel(paragraph.box.cgRect)))
            }
            if newline(sourceText) { excluded("source_newline_unsupported"); continue }
            guard let entry else { excluded("translation_pending"); continue }
            if entry.status != "translated" && entry.segments?.contains(where: { $0.status == "translated" }) != true { excluded(entry.status); continue }
            let parts: [(Int?,String,[AXLine])]
            if let content = paragraph.inlineContent {
                parts = content.filter { $0.kind == "text" }.compactMap { part in
                    guard let translated = entry.segments?.first(where: { $0.id == part.id }), translated.status == "translated", let text = translated.translation else {
                        excluded(entry.segments?.first(where: { $0.id == part.id })?.status ?? "segment_unavailable",segment:part.id)
                        return nil
                    }
                    if let status = part.lineRangeStatus, status != "complete_unverified" {
                        excluded("line_"+status,segment:part.id); return nil
                    }
                    return (part.id,text,part.lineRanges ?? [])
                }
            } else {
                if let status = paragraph.lineRangeStatus, status != "complete_unverified" {
                    excluded("line_"+status); continue
                }
                parts = [(nil,entry.translation ?? "",paragraph.lineRanges)]
            }
            // Color belongs to the whole paragraph, including all text segments
            // around math. Sampling/selection happen once; only drawing is clipped.
            let sampleBox = clips.max { $0.width*$0.height < $1.width*$1.height }
            let sampledBackground = sampleBox.map { ColorSampler.colors(in:image,normalizedRect:normalized($0)).background } ?? .lightBackground
            let sourceIDs = paragraph.inlineContent.map { $0.filter { $0.kind == "text" }.flatMap { $0.sourceNodes ?? [] } }
                ?? paragraph.lineSourceNodes ?? paragraph.members
            let colors = AXRenderColors.select(background:sampledBackground,sourceIDs:sourceIDs,observations:observations)
            for (segment,text,lines) in parts {
                if newline(text) { excluded("translation_newline_unsupported",segment:segment); continue }
                guard !lines.isEmpty, !text.isEmpty else { excluded("line_unavailable",segment:segment); continue }
                let minHeight = lines.map { $0.box.height }.min() ?? 0
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
                let itemID = UUID()
                var clipped = false
                for (index,rect) in rects.enumerated() {
                    if isCancelled() { break }
                    let allowed = clips.map { $0.intersection(rect) }.filter { !$0.isNull && !$0.isEmpty }
                    clipRects += allowed
                    let area = allowed.reduce(CGFloat(0)) { $0+$1.width*$1.height }
                    clipped = clipped || area+0.01 < rect.width*rect.height
                    for clip in allowed { bg?.setFillColor(colors.background.nsColor.cgColor); bg?.fill(clip) }
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
                            fragments.append(.init(itemID:itemID,text:string.substring(with:character),rect:box,characterOffset:offset))
                        }
                        offset = NSMaxRange(character)
                    }
                    location = end
                }
                items.append(MirrorItem(id:itemID,translatedText:text,presentation:.translated,
                    normalizedRect:normalized(pixel(paragraph.box.cgRect)),background:colors.background,foreground:colors.foreground))
                diagnostics.append(.init(node:paragraph.node,segment:segment,status:"rendered",box:pixel(paragraph.box.cgRect),fontSize:Double(fontSize),commonScale:Double(common),lineScales:scales,clipped:clipped,lineBoxes:rects,heightRatio:(lines.map { $0.box.height }.max() ?? minHeight)/minHeight,
                    backgroundColor:[Double(colors.background.red),Double(colors.background.green),Double(colors.background.blue)],
                    foregroundColor:[Double(colors.foreground.red),Double(colors.foreground.green),Double(colors.foreground.blue)],
                    foregroundSource:colors.foregroundSource,foregroundContrast:colors.contrast))
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
