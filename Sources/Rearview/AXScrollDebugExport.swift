import CoreGraphics
import Foundation
import ImageIO
import OSLog
import UniformTypeIdentifiers

/// Records preview decisions and saves the composite only after AppKit draws it.
struct AXScrollDebugExport: Sendable {
    let directory: URL
    let session: String
    let frameID: UInt64
    let method: AXScrollMethod
    let whileWaiting: Bool
    let attempt = UUID()

    struct Reference: Sendable {
        let frameID: UInt64
        let source: CGImage
        let artwork: AXRenderArtwork
        let receivedAt: UInt64
        let stable: Bool
    }

    private static let queue = DispatchQueue(label: "Rearview.ax.preview-export", qos: .utility)
    private static let imageSlots = DispatchSemaphore(value: 4)
    private static let logger = Logger(subsystem: "Rearview", category: "AXScrollDebugExport")

    func record(_ result: String, shift: CGFloat? = nil, image: CGImage? = nil, boxes: [CGRect] = [],
                reference: Reference? = nil, current: CGImage? = nil,
                currentReceivedAt: UInt64? = nil, backgroundOpacity: CGFloat = 1) {
        let date = Date()
        let canSaveImage = image != nil && Self.imageSlots.wait(timeout: .now()) == .success
        let imageToSave = canSaveImage ? image : nil
        let dropped = image != nil && !canSaveImage
        Self.queue.async {
            defer { if canSaveImage { Self.imageSlots.signal() } }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let time = ISO8601DateFormatter()
                time.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let timestamp = time.string(from: date)
                var row: [String: Any] = [
                    "timestamp": timestamp, "session": session, "frameID": frameID,
                    "attempt": attempt.uuidString, "method": method.rawValue,
                    "whileWaiting": whileWaiting, "result": result
                ]
                if let shift { row["shiftPixelsYUp"] = shift }
                if let reference {
                    row["referenceFrameID"] = reference.frameID
                    row["referenceReceivedAtNs"] = reference.receivedAt
                    row["referenceStable"] = reference.stable
                }
                if let currentReceivedAt { row["currentReceivedAtNs"] = currentReceivedAt }
                if let imageToSave {
                    let filename = "\(timestamp.replacingOccurrences(of: ":", with: "-"))-\(session)-\(frameID)-\(method.rawValue)-\(attempt.uuidString).png"
                    do {
                        try Self.save(imageToSave, boxes: boxes, to: directory.appendingPathComponent(filename))
                        row["image"] = filename
                        row["movedLineCount"] = boxes.count
                        if let reference, let current {
                            let prefix = "reference-\(session)-\(reference.frameID)-\(reference.artwork.identity.uuidString)"
                            let sourceName = prefix + "-source.png"
                            let renderedName = prefix + "-rendered.png"
                            let currentName = String(filename.dropLast(4)) + "-source.png"
                            let sources = [
                                (sourceName, reference.source),
                                (renderedName, Self.composite(reference, opacity: backgroundOpacity)),
                                (currentName, current)
                            ]
                            for (name, source) in sources {
                                guard let source else { throw ImageSaveError.noPNGRepresentation }
                                let url = directory.appendingPathComponent(name)
                                if !FileManager.default.fileExists(atPath: url.path) {
                                    try Self.save(source, boxes: [], to: url)
                                }
                            }
                            row["referenceSource"] = sourceName
                            row["referenceRendered"] = renderedName
                            row["currentSource"] = currentName
                            let layoutName = prefix + "-layout.json"
                            let layoutURL = directory.appendingPathComponent(layoutName)
                            if !FileManager.default.fileExists(atPath: layoutURL.path) {
                                try JSONEncoder().encode(reference.artwork.diagnostics.filter { $0.status == "rendered" })
                                    .write(to: layoutURL, options: .atomic)
                            }
                            row["referenceLayout"] = layoutName
                        }
                    } catch {
                        row["imageError"] = error.localizedDescription
                    }
                } else if dropped {
                    row["imageError"] = "export_queue_busy"
                }
                var data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
                data.append(0x0a)
                let file = directory.appendingPathComponent("decisions-\(session).jsonl")
                if !FileManager.default.fileExists(atPath: file.path) {
                    try Data().write(to: file)
                }
                let handle = try FileHandle(forWritingTo: file)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } catch {
                Self.logger.error("Scroll debug export failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    static func drawBoxes(_ boxes: [CGRect], in context: CGContext, destination: CGRect, sourceSize: CGSize) {
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: destination)
        let sx = destination.width / sourceSize.width, sy = destination.height / sourceSize.height
        let rects = boxes.map {
            CGRect(x: destination.minX + $0.minX * sx, y: destination.minY + $0.minY * sy,
                   width: $0.width * sx, height: $0.height * sy)
        }
        context.setStrokeColor(red: 0, green: 0, blue: 0, alpha: 0.9)
        context.setLineWidth(3)
        for rect in rects { context.stroke(rect) }
        context.setStrokeColor(red: 0.15, green: 1, blue: 0.85, alpha: 1)
        context.setLineWidth(2)
        context.setLineDash(phase: 0, lengths: [5, 3])
        for rect in rects { context.stroke(rect) }
    }

    static func annotated(_ image: CGImage, boxes: [CGRect]) -> CGImage? {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        guard let context = CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: bounds)
        drawBoxes(boxes, in: context, destination: bounds, sourceSize: bounds.size)
        return context.makeImage()
    }

    private static func composite(_ reference: Reference, opacity: CGFloat) -> CGImage? {
        let source = reference.source
        let rect = CGRect(x: 0, y: 0, width: source.width, height: source.height)
        guard let context = CGContext(data: nil, width: source.width, height: source.height,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(source, in: rect)
        if let background = reference.artwork.background {
            context.setAlpha(MirrorBackgroundOpacity.clamp(opacity))
            context.draw(background, in: rect)
        }
        if let text = reference.artwork.text {
            context.setAlpha(1)
            context.draw(text, in: rect)
        }
        return context.makeImage()
    }

    private static func save(_ image: CGImage, boxes: [CGRect], to url: URL) throws {
        let data = NSMutableData()
        guard let result = (boxes.isEmpty ? image : annotated(image, boxes: boxes)),
              let output = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw ImageSaveError.noPNGRepresentation
        }
        CGImageDestinationAddImage(output, result, nil)
        guard CGImageDestinationFinalize(output) else { throw ImageSaveError.noPNGRepresentation }
        try (data as Data).write(to: url, options: .atomic)
    }
}
