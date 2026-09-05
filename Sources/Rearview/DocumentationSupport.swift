import Foundation

/// The input contract for the repeatable user-guide build.  This type is kept
/// independent from AppKit so the scenario file can be validated in ordinary
/// Swift tests and by the command-line build script before launching a GUI.
struct DocumentationScenarioFile: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let scenarios: [DocumentationScenario]

    func validate() throws {
        guard schemaVersion == 1 else {
            throw DocumentationError.invalidInput("unsupported scenario schema version \(schemaVersion)")
        }
        var ids = Set<String>()
        var captureNames = Set<String>()
        for scenario in scenarios {
            guard !scenario.id.isEmpty else {
                throw DocumentationError.invalidInput("scenario id must not be empty")
            }
            guard ids.insert(scenario.id).inserted else {
                throw DocumentationError.invalidInput("duplicate scenario id: \(scenario.id)")
            }
            var hasCapture = false
            for action in scenario.actions {
                try action.validate()
                if action.type == "capture" {
                    hasCapture = true
                    guard let name = action.name, !name.isEmpty else {
                        throw DocumentationError.invalidInput(
                            "capture action in \(scenario.id) must have a name"
                        )
                    }
                    guard captureNames.insert(name).inserted else {
                        throw DocumentationError.invalidInput("duplicate capture name: \(name)")
                    }
                }
            }
            guard hasCapture else {
                throw DocumentationError.invalidInput(
                    "scenario \(scenario.id) does not contain a capture action"
                )
            }
        }
    }
}

struct DocumentationScenario: Codable, Equatable, Sendable {
    let id: String
    let title: String
    let actions: [DocumentationAction]
    let captionKey: String?
}

struct DocumentationAction: Codable, Equatable, Sendable {
    let type: String
    let name: String?
    let rect: [CGFloat]?
    let mode: String?
    let category: String?
    let value: String?
    let number: Int?

    func validate() throws {
        let supported: Set<String> = [
            "showPermissionPreview", "showSelectionPreview", "setSelection",
            "startSession", "setDisplayMode", "setRefreshMode", "setPaused",
            "showSearch", "showTextSelection", "copyText", "showSettings", "setSetting", "showToolbarOverflow",
            "capture", "stopSession", "wait"
        ]
        guard supported.contains(type) else {
            throw DocumentationError.invalidInput("unsupported documentation action: \(type)")
        }
        if type == "setSelection" {
            guard rect?.count == 4 else {
                throw DocumentationError.invalidInput("setSelection requires [x, y, width, height]")
            }
        }
        if type == "capture" && (name == nil || name?.isEmpty == true) {
            throw DocumentationError.invalidInput("capture requires name")
        }
    }
}

struct DocumentationScreenshotRecord: Codable, Equatable, Sendable {
    let scenarioID: String
    let name: String
    let path: String
    let width: Int
    let height: Int
    let sha256: String
}

struct DocumentationManifest: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let appVersion: String
    let scenarios: [DocumentationScreenshotRecord]
    let coveredUIItems: [String]
}

enum DocumentationError: LocalizedError, Equatable {
    case invalidInput(String)
    case captureFailed(String)
    case outputFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidInput(let message): "문서 입력이 올바르지 않습니다: \(message)"
        case .captureFailed(let message): "문서 캡처에 실패했습니다: \(message)"
        case .outputFailed(let message): "문서 결과물 생성에 실패했습니다: \(message)"
        }
    }
}

enum DocumentationJSON {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    static let decoder = JSONDecoder()

    static func loadScenarios(from url: URL) throws -> DocumentationScenarioFile {
        do {
            let data = try Data(contentsOf: url)
            let file = try decoder.decode(DocumentationScenarioFile.self, from: data)
            try file.validate()
            return file
        } catch let error as DocumentationError {
            throw error
        } catch {
            throw DocumentationError.invalidInput(
                "\(url.path): \(error.localizedDescription)"
            )
        }
    }

    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try encoder.encode(value).write(to: url, options: .atomic)
        } catch {
            throw DocumentationError.outputFailed("\(url.path): \(error.localizedDescription)")
        }
    }
}
