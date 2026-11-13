import Foundation
import CoreGraphics

package enum AXForegroundStyle {
    // A first-character sample cannot establish uniform styling. Require the
    // complete native text and a valid, identical color over every UTF-16 run.
    package static func uniformColor(in attributed: NSAttributedString, matching text: String) -> AXTextColor? {
        guard attributed.length > 0, attributed.string.utf16.elementsEqual(text.utf16),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var candidate: AXTextColor?
        var valid = true
        attributed.enumerateAttribute(NSAttributedString.Key("AXForegroundColor"), in: NSRange(location:0,length:attributed.length)) { raw, _, stop in
            guard let raw, CFGetTypeID(raw as CFTypeRef) == CGColor.typeID,
                  let color = unsafeBitCast(raw as CFTypeRef,to:CGColor.self).converted(to:space,intent:.defaultIntent,options:nil),
                  let c = color.components, c.count == 4,
                  c.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
                valid = false; stop.pointee = true; return
            }
            let current = AXTextColor(red:Double(c[0]),green:Double(c[1]),blue:Double(c[2]),alpha:Double(c[3]))
            if let candidate, candidate != current { valid = false; stop.pointee = true }
            else { candidate = current }
        }
        return valid ? candidate : nil
    }
}
