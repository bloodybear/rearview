import Foundation

/// Source offsets are UTF-16; punctuation is included only between Japanese characters.
public enum AXCodeTextSegments {
    public struct Segment: Sendable, Equatable {
        public let range: NSRange
        public let text: String
        public let translates: Bool
    }
    public static func split(_ text: String, korean: Bool = false) -> [Segment] {
        let bridge = CharacterSet(charactersIn: "、。！？「」『』・…‥ \t\u{3000}")
        func japanese(_ s: Unicode.Scalar) -> Bool {
            if korean { return (0xAC00...0xD7AF).contains(s.value) || (0x1100...0x11FF).contains(s.value) }
            return (0x3041...0x3096).contains(s.value) || (0x309D...0x309F).contains(s.value)
                || (0x30A1...0x30FA).contains(s.value) || (0x30FC...0x30FF).contains(s.value)
                || (0x31F0...0x31FF).contains(s.value) || (0x3005...0x3007).contains(s.value)
                || (0x3400...0x9FFF).contains(s.value) || (0xF900...0xFAFF).contains(s.value)
        }
        let scalars = Array(text.unicodeScalars)
        var offsets = [0]
        for s in scalars { offsets.append(offsets.last! + s.utf16.count) }
        var ranges: [NSRange] = []
        var i = 0
        while i < scalars.count {
            guard japanese(scalars[i]) else { i += 1; continue }
            let start = i
            var end = i + 1
            i += 1
            while i < scalars.count {
                if japanese(scalars[i]) || (i == end && CharacterSet.nonBaseCharacters.contains(scalars[i])) {
                    end = i + 1; i += 1
                } else if bridge.contains(scalars[i]) { i += 1 }
                else { break }
            }
            ranges.append(NSRange(location: offsets[start], length: offsets[end] - offsets[start]))
        }
        let source = text as NSString
        var result: [Segment] = [], cursor = 0
        func append(_ range: NSRange, _ translates: Bool) {
            if range.length > 0 { result.append(.init(range:range,text:source.substring(with:range),translates:translates)) }
        }
        for range in ranges {
            append(NSRange(location:cursor,length:range.location-cursor),false)
            append(range,true); cursor = NSMaxRange(range)
        }
        append(NSRange(location:cursor,length:source.length-cursor),false)
        return result
    }
}
