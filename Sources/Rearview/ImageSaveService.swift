import AppKit
import Foundation

enum ImageSaveError: LocalizedError {
    case noPNGRepresentation
    case emptyFilenameTemplate
    case unableToCreateDirectory(URL)

    var errorDescription: String? {
        switch self {
        case .noPNGRepresentation:
            return L10n.text("이미지를 PNG로 변환할 수 없습니다.")
        case .emptyFilenameTemplate:
            return L10n.text("파일명 규칙이 비어 있습니다.")
        case .unableToCreateDirectory(let url):
            return L10n.format("저장 폴더를 만들 수 없습니다: %@", url.path)
        }
    }
}

struct ImageSaveService {
    static func save(
        image: NSImage, directory: URL, filenameTemplate: String,
        date: Date = Date(), fileManager: FileManager = .default
    ) throws -> URL {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw ImageSaveError.noPNGRepresentation
        }

        let normalizedDirectory = directory.standardizedFileURL
        do {
            try fileManager.createDirectory(
                at: normalizedDirectory, withIntermediateDirectories: true
            )
        } catch {
            throw ImageSaveError.unableToCreateDirectory(normalizedDirectory)
        }

        let usesCounterToken = filenameTemplate.contains("{counter}")
        let baseName = renderedFilename(template: filenameTemplate, date: date, counter: 1)
        guard !baseName.isEmpty else { throw ImageSaveError.emptyFilenameTemplate }

        var candidate = normalizedDirectory.appendingPathComponent(baseName).appendingPathExtension("png")
        var counter = 2
        while fileManager.fileExists(atPath: candidate.path) {
            let nextName = usesCounterToken
                ? renderedFilename(template: filenameTemplate, date: date, counter: counter)
                : "\(baseName)-\(counter)"
            candidate = normalizedDirectory.appendingPathComponent(nextName)
                .appendingPathExtension("png")
            counter += 1
        }
        try png.write(to: candidate, options: .atomic)
        return candidate
    }

    private static func renderedFilename(template: String, date: Date, counter: Int) -> String {
        let raw = template.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ".png", with: "", options: .caseInsensitive)
        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let dateStamp = String(format: "%04d-%02d-%02d_%02d-%02d-%02d",
                               components.year ?? 0, components.month ?? 0, components.day ?? 0,
                               components.hour ?? 0, components.minute ?? 0, components.second ?? 0)
        let dateOnly = String(format: "%04d-%02d-%02d",
                              components.year ?? 0, components.month ?? 0, components.day ?? 0)
        var value = raw
            .replacingOccurrences(of: "{yyyy-MM-dd_HH-mm-ss}", with: dateStamp)
            .replacingOccurrences(of: "{yyyy-MM-dd}", with: dateOnly)
            .replacingOccurrences(of: "{yyyy}", with: String(format: "%04d", components.year ?? 0))
            .replacingOccurrences(of: "{MM}", with: String(format: "%02d", components.month ?? 0))
            .replacingOccurrences(of: "{dd}", with: String(format: "%02d", components.day ?? 0))
            .replacingOccurrences(of: "{HH}", with: String(format: "%02d", components.hour ?? 0))
            .replacingOccurrences(of: "{mm}", with: String(format: "%02d", components.minute ?? 0))
            .replacingOccurrences(of: "{ss}", with: String(format: "%02d", components.second ?? 0))
            .replacingOccurrences(of: "{counter}", with: String(counter))

        let invalid = CharacterSet(charactersIn: "/\\:\0")
        value = value.components(separatedBy: invalid).joined(separator: "-")
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value
    }
}
