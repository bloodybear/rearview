import AppKit
import NotionAXCore

struct AXRenderColors {
    let background, foreground: RGBAColor
    let foregroundSource: String
    let contrast: Double

    struct BackgroundSample: Codable, Sendable {
        let box: CGRect // Image pixels, bottom-left origin, as used by the renderer.
        let top, bottom, fallback: Bool
    }

    static func backgroundSample(lines: [CGRect], clips: [CGRect]) -> BackgroundSample? {
        var preferred: BackgroundSample?, fallback: BackgroundSample?
        func larger(_ a: BackgroundSample, than b: BackgroundSample?) -> Bool {
            b == nil || a.box.width*a.box.height > b!.box.width*b!.box.height
        }
        for line in lines {
            guard !line.isNull, !line.isInfinite, line.width > 0, line.height > 0 else { continue }
            for clip in clips {
                let overlap = line.intersection(clip)
                guard !overlap.isNull, !overlap.isEmpty else { continue }
                let pixels = CGRect(x:ceil(overlap.minX),y:ceil(overlap.minY),
                    width:floor(overlap.maxX)-ceil(overlap.minX),height:floor(overlap.maxY)-ceil(overlap.minY))
                guard pixels.width >= 1, pixels.height >= 1 else { continue }
                let candidate = BackgroundSample(box:pixels,
                    top:abs(overlap.maxY-line.maxY) < 0.000001,
                    bottom:abs(overlap.minY-line.minY) < 0.000001,fallback:false)
                if (candidate.top || candidate.bottom), larger(candidate,than:preferred) { preferred = candidate }
                let any = BackgroundSample(box:pixels,top:true,bottom:true,fallback:true)
                if larger(any,than:fallback) { fallback = any }
            }
        }
        return preferred ?? fallback
    }

    // Read only complete pixels inside the paragraph's top/bottom edges.
    // No expansion, rescaling, side-edge sampling or averaging across colors.
    static func sampleBackground(in image: CGImage, pixelRect: CGRect, topEdge: Bool = true, bottomEdge: Bool = true) -> RGBAColor? {
        let proposed = CGRect(x:pixelRect.minX,y:CGFloat(image.height)-pixelRect.maxY,
            width:pixelRect.width,height:pixelRect.height)
        guard [proposed.minX,proposed.minY,proposed.maxX,proposed.maxY].allSatisfy({ $0.isFinite }) else { return nil }
        let left = Int(max(0,min(CGFloat(image.width),ceil(proposed.minX))))
        let right = Int(max(0,min(CGFloat(image.width),floor(proposed.maxX))))
        let top = Int(max(0,min(CGFloat(image.height),ceil(proposed.minY))))
        let bottom = Int(max(0,min(CGFloat(image.height),floor(proposed.maxY))))
        guard right > left, bottom > top else { return nil }
        let width = right-left
        var counts: [UInt32:Int] = [:]
        var rows: [Int] = []
        if topEdge { rows.append(top) }
        if bottomEdge, rows.last != bottom-1 { rows.append(bottom-1) }
        for y in rows {
            guard let strip = image.cropping(to:CGRect(x:left,y:y,width:width,height:1)) else { continue }
            var bytes = [UInt8](repeating:0,count:width*4)
            guard let context = CGContext(data:&bytes,width:width,height:1,bitsPerComponent:8,
                bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),
                bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
            context.draw(strip,in:CGRect(x:0,y:0,width:width,height:1))
            for x in 0..<width {
                let offset = x*4
                let key = UInt32(bytes[offset]) << 16 | UInt32(bytes[offset+1]) << 8 | UInt32(bytes[offset+2])
                counts[key,default:0] += 1
            }
        }
        // A deterministic RGB tie-break avoids dictionary iteration order.
        guard let winner = counts.max(by:{ $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value })?.key else { return nil }
        return RGBAColor(red:CGFloat((winner >> 16)&255)/255,
            green:CGFloat((winner >> 8)&255)/255,blue:CGFloat(winner&255)/255,alpha:1)
    }

    static func select(background sampled: RGBAColor, sourceIDs: [Int], observations: [Int:AXNode]) -> Self {
        let background = RGBAColor(red:sampled.red,green:sampled.green,blue:sampled.blue,alpha:1)
        var uniform: AXTextColor?
        var complete = !sourceIDs.isEmpty
        for id in Set(sourceIDs) {
            guard let node = observations[id], node.mathOwner == nil,
                  node.foregroundColorStatus == "uniform", let color = node.foregroundColor,
                  [color.red,color.green,color.blue,color.alpha].allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { complete = false; break }
            if let uniform, uniform != color { complete = false; break }
            uniform = color
        }
        if complete, let uniform {
            // Evaluate the actual paint color, including translucent text, on
            // the sampled opaque mask. Never manufacture contrast by ignoring alpha.
            let a = CGFloat(uniform.alpha)
            let foreground = RGBAColor(red:CGFloat(uniform.red)*a+background.red*(1-a),
                green:CGFloat(uniform.green)*a+background.green*(1-a),
                blue:CGFloat(uniform.blue)*a+background.blue*(1-a),alpha:1)
            let ratio = contrast(foreground,background)
            if ratio >= 4.5 { return Self(background:background,foreground:foreground,foregroundSource:"ax_uniform",contrast:ratio) }
        }
        // Keep the familiar near-black/near-white palette where it is readable.
        // Mid-tone backgrounds can require pure black or white to reach 4.5:1.
        var foreground = [RGBAColor(red:0.06,green:0.06,blue:0.06,alpha:1),
                          RGBAColor(red:0.96,green:0.96,blue:0.96,alpha:1)]
            .max { contrast($0,background) < contrast($1,background) }!
        if contrast(foreground,background) < 4.5 {
            foreground = [RGBAColor(red:0,green:0,blue:0,alpha:1),RGBAColor(red:1,green:1,blue:1,alpha:1)]
                .max { contrast($0,background) < contrast($1,background) }!
        }
        return Self(background:background,foreground:foreground,
                    foregroundSource:complete ? "default_low_contrast" : "default_mixed_or_missing_ax",
                    contrast:contrast(foreground,background))
    }

    static func contrast(_ first: RGBAColor, _ second: RGBAColor) -> Double {
        func luminance(_ color: RGBAColor) -> Double {
            func linear(_ value: CGFloat) -> Double { let v = Double(value); return v <= 0.04045 ? v/12.92 : pow((v+0.055)/1.055,2.4) }
            return 0.2126*linear(color.red)+0.7152*linear(color.green)+0.0722*linear(color.blue)
        }
        let a = luminance(first), b = luminance(second)
        return (max(a,b)+0.05)/(min(a,b)+0.05)
    }
}
