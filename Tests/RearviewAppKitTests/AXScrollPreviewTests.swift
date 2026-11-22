#if DEBUG
import XCTest
@testable import NotionAXCore
@testable import Rearview

final class AXScrollPreviewTests: XCTestCase {
    private let line = CGRect(x: 18, y: 48, width: 62, height: 12)

    private func image() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 96, height: 128,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 96, height: 128))
        for row in 24..<91 {
            let gray = CGFloat(row) / 96
            context.setFillColor(CGColor(red: gray, green: gray, blue: gray, alpha: 1))
            context.fill(CGRect(x: 24, y: CGFloat(row), width: 42, height: 1))
        }
        return try XCTUnwrap(context.makeImage())
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        let sample = try XCTUnwrap(image.cropping(to: CGRect(x: x, y: image.height - y - 1, width: 1, height: 1)))
        var bytes = [UInt8](repeating: 0, count: 4)
        try bytes.withUnsafeMutableBytes { storage in
            let context = try XCTUnwrap(CGContext(data: storage.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return bytes
    }

    func testMovesArtworkBySuppliedDisplacement() throws {
        let box: [String: Double] = ["x": 18, "y": 68, "width": 62, "height": 12]
        let snapshot = try AXExtractionSnapshot(
            nodes: [["id": 1, "role": "AXStaticText", "value": "日本語", "title": ""]],
            selected: [], paragraphs: [["node": 1, "text": "日本語", "box": box,
                "members": [1], "lineRanges": [], "isCodeBlock": false, "protectNonSourceText": false]],
            metadata: ["status": "complete", "documentSurfaces": [["node": 0, "bodyNodes": [1], "dialogBoxes": []]]])
        let previous = try image()
        var diagnostic = AXRenderDiagnostic(node: 1, segment: nil, status: "rendered", box: line)
        diagnostic.lineBoxes = [line]
        diagnostic.originalLineBoxes = [line]
        let artwork = AXRenderArtwork(background: previous, text: previous, debug: nil, items: [],
            fragments: [], clipRects: [line], diagnostics: [diagnostic], elapsed: 0)
        let region = AXScrollPreview.Region(viewport: CGRect(x: 0, y: 0, width: 96, height: 128))
        for dy in [-16, 16] {
            let preview = try XCTUnwrap(AXScrollPreview.make(size: CGSize(width: 96, height: 128),
                deltaY: CGFloat(dy), artwork: artwork, snapshot: snapshot, previous: region, current: region))
            XCTAssertEqual(preview.diagnostics.first?.lineBoxes, [line.offsetBy(dx: 0, dy: CGFloat(dy))])
            XCTAssertTrue(preview.items.isEmpty)
            let layer = try XCTUnwrap(preview.background)
            XCTAssertEqual(try pixel(layer, x: 40, y: 54 + dy), try pixel(previous, x: 40, y: 54))
            XCTAssertEqual(try pixel(layer, x: 10, y: 54 + dy), [0, 0, 0, 0])
        }
        let blocked = AXScrollPreview.Region(viewport: region.viewport,
                                            exclusions: [CGRect(x: 0, y: 64, width: 96, height: 14)])
        XCTAssertNil(AXScrollPreview.make(size: CGSize(width: 96, height: 128), deltaY: 16,
            artwork: artwork, snapshot: snapshot, previous: region, current: blocked))
        var partial = diagnostic
        partial.clipped = true
        let secondLine = line.offsetBy(dx: 0, dy: -24)
        partial.lineBoxes = [line, secondLine]
        partial.originalLineBoxes = [line, secondLine]
        let partialArtwork = AXRenderArtwork(background: previous, text: previous, debug: nil, items: [],
            fragments: [], clipRects: [line, secondLine], diagnostics: [partial], elapsed: 0)
        let preview = try XCTUnwrap(AXScrollPreview.make(size: CGSize(width: 96, height: 128), deltaY: 16,
            artwork: partialArtwork, snapshot: snapshot, previous: region, current: blocked))
        XCTAssertEqual(preview.diagnostics.first?.lineBoxes, [secondLine.offsetBy(dx: 0, dy: 16)])
        let bodyEdge = line.maxX
        let leftOfPreview = AXScrollPreview.Region(viewport: CGRect(x: 0, y: 0, width: bodyEdge, height: 128))
        let edgePreview = try XCTUnwrap(AXScrollPreview.make(size: CGSize(width: 96, height: 128), deltaY: 16,
            artwork: artwork, snapshot: snapshot, previous: leftOfPreview, current: leftOfPreview))
        XCTAssertEqual(edgePreview.clipRects.first?.maxX, bodyEdge)
        XCTAssertNil(AXScrollPreview.make(size: CGSize(width: 96, height: 128), deltaY: 0, artwork: artwork, snapshot: snapshot, previous: region, current: region))
    }
}
#endif
