import AppKit
import NotionAXCore

struct AXRenderColors {
    let background, foreground: RGBAColor
    let foregroundSource: String
    let contrast: Double

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
