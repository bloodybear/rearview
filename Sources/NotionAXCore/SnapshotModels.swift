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
    public let isCodeBlock, protectNonSourceText: Bool
}
public struct AXTextColor: Codable, Sendable, Equatable {
    public let red, green, blue, alpha: Double
}
public struct AXNode: Codable, Sendable {
    public let id: Int
    public let parent, controlTextOwner, mathOwner: Int?
    public let role, value, title: String
    public let frame: AXBox?
    public let decision, decisionReason: String?
    public let foregroundColor, backgroundColor: AXTextColor?
    public let foregroundColorStatus: String?
}
public enum AXCollectionStatus: String, Codable, Sendable { case complete, partial, failed }
