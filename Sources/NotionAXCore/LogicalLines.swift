import Foundation

/// Logical hard breaks and their original native visual lines. No geometry is inferred.
package enum AXLogicalLines {
    package struct Segment: Sendable {
        package let range: NSRange
        package let text: String
        package let delimiter: String
        package let lineIndices: [Int]
    }
    package enum Failure: Error { case invalidRange, textMismatch, ambiguousLine, missingLine }
    package static func pieces(_ source: String) -> [(NSRange, String)] {
        let ns = source as NSString
        let expression = try! NSRegularExpression(pattern: "\\r\\n|[\\n\\r\\u000B\\u000C\\u0085\\u2028\\u2029]")
        let breaks = expression.matches(in: source, range: NSRange(location: 0, length: ns.length))
        var spans: [(NSRange, String)] = [], start = 0
        for match in breaks {
            spans.append((NSRange(location: start, length: match.range.location-start), ns.substring(with: match.range)))
            start = NSMaxRange(match.range)
        }
        spans.append((NSRange(location: start, length: ns.length-start), ""))
        return spans
    }
    package static func split(_ source: String, lines: [AXLine]) throws -> [Segment] {
        let ns = source as NSString
        let spans = pieces(source)
        var assignments = Array(repeating: [Int](), count: spans.count)
        var previousEnd = 0
        for (index, line) in lines.enumerated() {
            let localStart = line.segmentRangeStart ?? line.rangeStart
            guard localStart >= 0, line.rangeLength >= 0,
                  localStart <= ns.length, line.rangeLength <= ns.length-localStart else { throw Failure.invalidRange }
            guard localStart >= previousEnd else { throw Failure.invalidRange }
            previousEnd = localStart+line.rangeLength
            let range = NSRange(location: localStart, length: line.rangeLength)
            guard ns.substring(with: range).utf16.elementsEqual(line.text.utf16) else { throw Failure.textMismatch }
            let owners = spans.indices.filter { NSIntersectionRange(spans[$0].0, range).length > 0 }
            guard owners.count <= 1 else { throw Failure.ambiguousLine }
            if let owner = owners.first { assignments[owner].append(index) }
        }
        return try spans.enumerated().map { index, span in
            let text = ns.substring(with: span.0)
            let coverage = assignments[index].reduce(0) { count,i in
                count+NSIntersectionRange(span.0,NSRange(location:lines[i].segmentRangeStart ?? lines[i].rangeStart,length:lines[i].rangeLength)).length
            }
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && coverage != span.0.length { throw Failure.missingLine }
            return Segment(range: span.0, text: text, delimiter: span.1, lineIndices: assignments[index])
        }
    }
    package static func flattenGeneratedBreaks(_ text: String) -> String {
        text.replacingOccurrences(of: "\\r\\n|[\\n\\r\\u000B\\u000C\\u0085\\u2028\\u2029]", with: " ", options: .regularExpression)
    }
}
