import Foundation

public struct AXBox: Codable, Sendable, Equatable {
    public let x, y, width, height: Double
    public var cgRect: CGRect { CGRect(x:x,y:y,width:width,height:height) }
}
public struct AXLine: Codable, Sendable {
    public let text: String
    public let rangeStart, rangeLength: Int
    public let box: AXBox
    public let line, segment, segmentRangeStart: Int?
    public init(text:String, rangeStart:Int, rangeLength:Int, box:AXBox, line:Int? = nil, segment:Int? = nil, segmentRangeStart:Int? = nil) {
        self.text=text;self.rangeStart=rangeStart;self.rangeLength=rangeLength;self.box=box
        self.line=line;self.segment=segment;self.segmentRangeStart=segmentRangeStart
    }
}
public struct AXInlineContent: Codable, Sendable {
    public let kind: String
    public let id: Int
    public let node: Int?
    public let text: String?
    public let sourceNodes: [Int]?
    public let lineRanges: [AXLine]?
    public let lineRangeStatus: String?
}
public struct AXParagraph: Codable, Sendable {
    public let node: Int
    public let text: String
    public let box: AXBox
    public let originalBox: AXBox?
    public let visibleBoxes: [AXBox]?
    public let members: [Int]
    public let lineRanges: [AXLine]
    public let lineSourceNodes: [Int]?
    public let lineSourceText, lineRangeStatus, lineMethod: String?
    public let inlineContent: [AXInlineContent]?
    public var layoutExpansionRight: Double? = nil
    public var codeSegments: [AXCodeSegment]? = nil
    public let isCodeBlock, protectNonSourceText: Bool
}
extension AXParagraph {
    /// Only source backed by the native line collection may cross the translation boundary.
    public var translationSourceText: String? {
        guard lineRangeStatus == "complete_unverified" else { return nil }
        if let inlineContent {
            guard inlineContent.filter({ $0.kind == "text" }).allSatisfy({
                $0.lineRangeStatus == "complete_unverified" || $0.lineRangeStatus == "nonrendering_text"
            }) else { return nil }
            return inlineContent.filter { $0.kind == "text" }.map { $0.text ?? "" }.joined()
        }
        return lineSourceText
    }
}
public struct AXTextColor: Codable, Sendable, Equatable {
    public let red, green, blue, alpha: Double
}
public struct AXNode: Codable, Sendable {
    public let id: Int
    public let parent, controlTextOwner, mathOwner: Int?
    public let role, value, title: String
    public let recoveredText: String?
    public let frame: AXBox?
    public let decision, decisionReason: String?
    public let foregroundColor, backgroundColor: AXTextColor?
    public let foregroundColorStatus: String?
}
public enum AXCollectionStatus: String, Codable, Sendable { case complete, partial, failed }

public struct AXCodePiece: Codable, Sendable {
    public let sourceNode, rangeStart, rangeLength: Int
    public let text: String
    public let box: AXBox?
    public let status: String
}
public struct AXCodeStyle: Codable, Sendable {
    public let foregroundColor: AXTextColor?
    public let foregroundColorStatus: String
    public let bold, italic, underline, strikethrough: Bool?
}
public struct AXCodeSegment: Codable, Sendable {
    public let id, rangeStart, rangeLength: Int
    public let text: String
    public let translates: Bool
    public let pieces: [AXCodePiece]
    public let status: String
    public let style: AXCodeStyle
}
