import Foundation
import AppKit
import Testing
@testable import Rearview

@Suite
struct ImageSaveTests {
    @Test func imageSaveSettingsRoundTripAndReset() {
        withTestDefaults { defaults in
            #expect(ImageSaveSettings.filenameTemplate(from: defaults) == AppDefaults.imageSaveFilenameTemplate)
            let directory = URL(fileURLWithPath: "/tmp/rearview-tests", isDirectory: true)
            ImageSaveSettings.save(directoryURL: directory, to: defaults)
            ImageSaveSettings.save(filenameTemplate: "capture_{yyyy}_{counter}", to: defaults)
            #expect(ImageSaveSettings.directoryURL(from: defaults).path == directory.path)
            #expect(ImageSaveSettings.filenameTemplate(from: defaults) == "capture_{yyyy}_{counter}")
            AppSettings.reset(to: defaults)
            #expect(ImageSaveSettings.filenameTemplate(from: defaults) == AppDefaults.imageSaveFilenameTemplate)
        }
    }

    @Test func savesPNGAndAvoidsExistingFilename() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RearviewImageSaveTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        guard let cgImage = testImage() else {
            Issue.record("test image could not be created")
            return
        }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: 16, height: 16))
        let date = Date(timeIntervalSince1970: 1_735_689_600)
        let first = try ImageSaveService.save(
            image: image, directory: directory,
            filenameTemplate: "Rearview_{yyyy-MM-dd}_{counter}", date: date
        )
        let second = try ImageSaveService.save(
            image: image, directory: directory,
            filenameTemplate: "Rearview_{yyyy-MM-dd}_{counter}", date: date
        )
        #expect(first.pathExtension == "png")
        #expect(first.lastPathComponent == "Rearview_2025-01-01_1.png")
        #expect(second.lastPathComponent == "Rearview_2025-01-01_2.png")
        #expect(FileManager.default.fileExists(atPath: first.path))
        #expect(FileManager.default.fileExists(atPath: second.path))
    }
}
