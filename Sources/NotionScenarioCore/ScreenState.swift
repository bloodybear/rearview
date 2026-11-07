import Foundation

public struct PresentationRequest: Codable, Equatable, Sendable {
    public var mode: String
    public var fixtureId: String?
    public var rowIndex: Int?
    public var widthFraction: Double?
}
public struct SidebarRequest: Codable, Equatable, Sendable {
    public var mode: String
    public var width: Double?
}
public struct ViewportScrollRequest: Codable, Equatable, Sendable {
    public var scope: String
    public var container: Anchor?
    public var axis: String
    public var mode: String
    public var anchor: Anchor?
    public var offset: Double?
    public var rangeLocation: Int?
    public var rangeLength: Int?
    public var advancePixels: Int?
}
public struct TabRequest: Codable, Equatable, Sendable {
    public var scope: String
    public var anchor: Anchor
    public var selectedText: String
    public var contentAnchor: Anchor
}
public struct BlockDisplayRequest: Codable, Equatable, Sendable {
    public var scope: String
    public var anchor: Anchor
    public var mode: String
}
public struct RegionRequest: Codable, Equatable, Sendable {
    public var rect: Rect?
    public var scope: String?
    public var anchor: Anchor?
    public var cutEdge: String?
    public var fraction: Double?
    public var target: String?
}
public struct OverlayRequest: Codable, Equatable, Sendable {
    public var kind: String
    public var text: String
    public var expectedText: String?
}
public struct PageReference: Codable, Sendable {
    public var fixtureId: String
    public var pageId: String
    public var title: String
    public var rowIndex: Int?
    public var rowText: String?
}

/// Saved presentation choices are allowed only for explicitly disposable sandbox fixtures.
/// This check runs before the native runner opens Notion or requests AX.
public enum ReplaySafety {
    public static func rejection(for scenario: Scenario, operation: String,
                                 databaseViewTypes: [String: String]?,
                                 allowPersistentPresentation: Bool = false) -> String? {
        guard operation == "apply" else { return nil }
        if allowPersistentPresentation { return nil }
        let state = scenario.state
        if let displays = state.blockDisplays, !displays.isEmpty {
            return "Mermaid display switching can save page presentation and alter modification timestamps; replay is disabled."
        }
        if let name = state.databaseView {
            guard let type = databaseViewTypes?[name] else {
                return "Database view type is unknown; replay is blocked because timeline input must be excluded."
            }
            if type == "timeline" {
                return "Timeline display and panning can save date preferences and alter modification timestamps; replay is disabled."
            }
        }
        if state.scrolls?.contains(where: { $0.scope == "database" }) == true && state.databaseView == nil {
            return "Database scrolling requires an explicit known view so timestamp-changing timeline input can be excluded."
        }
        return nil
    }
}

/// Crop geometry is window-relative in points; CGImage rectangles use top-left pixels.
public enum RegionGeometry {
    public static func pixels(region: CGRect, window: CGRect, pixelWidth: Int, pixelHeight: Int) -> CGRect? {
        guard window.width > 0, window.height > 0, pixelWidth > 0, pixelHeight > 0,
              region.width > 0, region.height > 0,
              CGRect(origin: .zero, size: window.size).contains(region) else { return nil }
        let sx = Double(pixelWidth) / window.width, sy = Double(pixelHeight) / window.height
        return CGRect(x: region.minX * sx, y: region.minY * sy, width: region.width * sx, height: region.height * sy)
            .integral.intersection(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
    }
}
