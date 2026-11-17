import Foundation
import NotionAXCore

/// The preferred mode is independent of the mode supported by the current target.
enum TextExtractionPreference {
    static let defaultsKey = "textExtraction.mode"
    static func load(from defaults: UserDefaults = .standard) -> TextExtractionMode {
        defaults.string(forKey: defaultsKey) == "ocr" ? .ocr : .ax
    }
    static func save(_ mode: TextExtractionMode, to defaults: UserDefaults = .standard) {
        defaults.set(mode == .ax ? "ax" : "ocr", forKey: defaultsKey)
    }
    static func effective(_ preferred: TextExtractionMode, bundleIdentifier: String?) -> TextExtractionMode {
        preferred == .ax && bundleIdentifier == "notion.id" ? .ax : .ocr
    }
}
