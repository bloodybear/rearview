import Foundation

struct DebugCaptureTranscriptLine: Codable, Sendable {
    enum TranslationStatus: String, Codable, Sendable {
        case translated
        case translationFailed
        case notSourceLanguage
    }

    let id: String
    let sourceText: String
    let translatedText: String?
    let translationStatus: TranslationStatus
    let confidence: Double
    /// Vision normalized coordinates use a bottom-left origin.
    let rect: [Double]
}

private struct DebugCaptureTranscriptHeader: Codable {
    let schema: Int
    let type: String
    let region: [Double]
    let startedAt: Date
}

private struct DebugCaptureTranscriptFrame: Codable, Sendable {
    let schema: Int
    let type: String
    let frameID: UInt64
    let mode: String
    let lines: [DebugCaptureTranscriptLine]
}

private struct DebugCaptureTranscriptFooter: Codable {
    let schema: Int
    let type: String
    let framesRecorded: Int
    let truncated: Bool
}

/// Content-bearing transcript for the explicit --debug-select-region launch path only.
@MainActor
final class DebugCaptureTextTranscript {
    private static let schema = 1
    private static let maximumFrames = 20_000
    private static let maximumBytes = 32 * 1_024 * 1_024

    let url: URL
    private var handle: FileHandle?
    private var framesRecorded = 0
    private var bytesWritten = 0
    private var truncated = false
    private var closed = false

    init(region: [Double]) throws {
        let fileManager = FileManager.default
        guard let supportDirectory = fileManager.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        let directory = supportDirectory
            .appendingPathComponent("Rearview/DebugCaptureTranscripts", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        url = directory.appendingPathComponent(
            "debug-capture-\(formatter.string(from: Date()))-\(UUID().uuidString).jsonl"
        )
        guard fileManager.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        handle = try FileHandle(forWritingTo: url)
        guard try append(DebugCaptureTranscriptHeader(
            schema: Self.schema,
            type: "session",
            region: region,
            startedAt: Date()
        )) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    func record(frameID: UInt64, mode: OCRMode, lines: [DebugCaptureTranscriptLine]) {
        guard !closed, !truncated else { return }
        guard framesRecorded < Self.maximumFrames else {
            truncated = true
            return
        }
        do {
            guard try append(DebugCaptureTranscriptFrame(
                schema: Self.schema,
                type: "frame",
                frameID: frameID,
                mode: mode.rawValue,
                lines: lines
            )) else {
                truncated = true
                return
            }
            framesRecorded += 1
        } catch {
            truncated = true
            close()
        }
    }

    func close() {
        guard !closed else { return }
        try? append(DebugCaptureTranscriptFooter(
            schema: Self.schema,
            type: "end",
            framesRecorded: framesRecorded,
            truncated: truncated
        ), allowFooterSpace: true)
        closed = true
        try? handle?.synchronize()
        try? handle?.close()
        handle = nil
    }

    @discardableResult
    private func append<T: Encodable>(_ value: T, allowFooterSpace: Bool = false) throws -> Bool {
        var data = try JSONEncoder().encode(value)
        data.append(10)
        let limit = Self.maximumBytes + (allowFooterSpace ? 1_024 : 0)
        guard bytesWritten + data.count <= limit else {
            truncated = true
            return false
        }
        guard let handle else { throw CocoaError(.fileWriteUnknown) }
        try handle.write(contentsOf: data)
        bytesWritten += data.count
        return true
    }
}
