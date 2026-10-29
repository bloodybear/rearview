import Foundation

public struct Rect: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(_ r: CGRect) { x = r.minX; y = r.minY; width = r.width; height = r.height }
    public var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    public func near(_ other: Rect, tolerance: Double = 2) -> Bool {
        zip([x,y,width,height], [other.x,other.y,other.width,other.height]).allSatisfy { abs($0 - $1) <= tolerance }
    }
}
public struct Anchor: Codable, Equatable, Sendable {
    public var text: String
    public var blockClass: String?
    // Optional enclosing block text: used only to disambiguate, never guessed.
    public var ancestorText: String?
}
public struct ScrollRequest: Codable, Equatable, Sendable {
    public var mode: String
    public var anchor: Anchor?
    public var offset: Double?
}
public struct ToggleRequest: Codable, Equatable, Sendable {
    public var anchor: Anchor
    public var expanded: Bool
}
public struct FocusRequest: Codable, Equatable, Sendable {
    public var mode: String
    public var anchor: Anchor?
    public var location: Int?
    public var length: Int?
}
public struct RequestedState: Codable, Equatable, Sendable {
    public var coordinateSystem: String
    public var window: Rect?
    public var zoomPercent: Int?
    public var sidebarOpen: Bool?
    public var scroll: ScrollRequest?
    public var toggles: [ToggleRequest]?
    public var focus: FocusRequest?
    public var required: [String]
    public init() { coordinateSystem = "screen-top-left-points"; required = ["target", "window", "scroll", "focus", "screenshot"] }
}
public struct Scenario: Codable, Sendable {
    public var schemaVersion: Int
    public var id: String
    public var name: String
    public var version: Int
    public var fixtureId: String
    public var fixtureVersion: String
    public var state: RequestedState
    public init(id: String, name: String, fixtureId: String, fixtureVersion: String, state: RequestedState) {
        schemaVersion = 1; self.id = id; self.name = name; version = 1
        self.fixtureId = fixtureId; self.fixtureVersion = fixtureVersion; self.state = state
    }
}
public struct RunRequest: Codable, Sendable {
    public var runId: String
    public var operation: String
    public var pageId: String
    public var scenario: Scenario
    public var timeoutSeconds: Double?
}
public struct StepResult: Codable, Sendable {
    public var item: String
    public var status: String
    public var code: String?
    public var detail: String
    public var durationMs: Int
    public var attempts: Int = 1
    enum CodingKeys: String, CodingKey { case item, status, code, detail, durationMs, attempts }
    public init(item: String, status: String, code: String? = nil, detail: String, durationMs: Int, attempts: Int = 1) {
        self.item = item; self.status = status; self.code = code; self.detail = detail; self.durationMs = durationMs; self.attempts = attempts
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        item = try c.decode(String.self, forKey: .item); status = try c.decode(String.self, forKey: .status)
        code = try c.decodeIfPresent(String.self, forKey: .code); detail = try c.decode(String.self, forKey: .detail)
        durationMs = try c.decode(Int.self, forKey: .durationMs); attempts = try c.decodeIfPresent(Int.self, forKey: .attempts) ?? 1
    }
}
public struct CaptureInfo: Codable, Sendable {
    public var file: String
    public var frame: Rect
    public var viewport: Rect?
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var pixelsPerPointX: Double
    public var pixelsPerPointY: Double
    public var capturedAt: String
}
public struct RunResult: Codable, Sendable {
    public var runId: String
    public var fixtureId: String
    public var fixtureVersion: String
    public var scenarioId: String
    public var scenarioVersion: Int
    public var startedAt: String
    public var finishedAt: String?
    public var status: String
    public var requested: RequestedState
    public var observed: RequestedState
    public var steps: [StepResult]
    public var environment: [String: String]
    public var observedGeometry: [String: Rect] = [:]
    public var screenshot: CaptureInfo?

    public static func verdict(required: [String], steps: [StepResult]) -> String {
        if steps.contains(where: { $0.item == "target" && $0.status != "verified" }) { return "failed" }
        if required.allSatisfy({ item in steps.contains { $0.item == item && $0.status == "verified" } }) &&
            steps.allSatisfy({ $0.status == "verified" }) { return "verified" }
        return steps.contains(where: { $0.status == "verified" }) ? "partial" : "failed"
    }
}
public struct ScenarioFailure: Error, CustomStringConvertible {
    public var code: String
    public var description: String
    public init(_ code: String, _ description: String) { self.code = code; self.description = description }
}
