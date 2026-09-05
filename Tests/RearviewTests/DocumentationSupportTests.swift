import Foundation
import Testing
@testable import Rearview

struct DocumentationSupportTests {
    @Test func decodesAndValidatesCheckedInScenarios() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = root.appendingPathComponent("docs/user-guide/source/scenarios.json")
        let file = try DocumentationJSON.loadScenarios(from: url)
        #expect(file.schemaVersion == 1)
        #expect(file.scenarios.count >= 10)
        #expect(file.scenarios.contains(where: { $0.id == "select-region" }))
    }

    @Test func rejectsDuplicateScenarioAndCaptureNames() throws {
        let action = DocumentationAction(
            type: "capture", name: "same", rect: nil, mode: nil,
            category: nil, value: nil, number: nil
        )
        let file = DocumentationScenarioFile(
            schemaVersion: 1,
            scenarios: [
                DocumentationScenario(id: "one", title: "One", actions: [action], captionKey: nil),
                DocumentationScenario(id: "one", title: "Duplicate", actions: [action], captionKey: nil)
            ]
        )
        #expect(throws: DocumentationError.invalidInput("duplicate scenario id: one")) {
            try file.validate()
        }

        let captureFile = DocumentationScenarioFile(
            schemaVersion: 1,
            scenarios: [
                DocumentationScenario(id: "one", title: "One", actions: [action], captionKey: nil),
                DocumentationScenario(id: "two", title: "Two", actions: [action], captionKey: nil)
            ]
        )
        #expect(throws: DocumentationError.invalidInput("duplicate capture name: same")) {
            try captureFile.validate()
        }
    }

    @Test func rejectsUnsupportedAction() throws {
        let action = DocumentationAction(
            type: "clickRandomly", name: nil, rect: nil, mode: nil,
            category: nil, value: nil, number: nil
        )
        let file = DocumentationScenarioFile(
            schemaVersion: 1,
            scenarios: [DocumentationScenario(
                id: "invalid", title: "Invalid", actions: [action], captionKey: nil
            )]
        )
        #expect(throws: DocumentationError.invalidInput("unsupported documentation action: clickRandomly")) {
            try file.validate()
        }
    }
}
