import CoreGraphics
import Foundation
import NotionAXCore

/// Repositions complete body lines using the measured AX displacement.
enum AXScrollPreview {
    struct Region {
        let viewport: CGRect
        let exclusions: [CGRect]

        init(viewport: CGRect, exclusions: [CGRect] = []) {
            self.viewport = viewport
            self.exclusions = exclusions
        }

        init(_ geometry: AXScrollGeometry, selection: CGRect, size: CGSize) {
            let sx = size.width / selection.width, sy = size.height / selection.height
            func pixels(_ rect: CGRect) -> CGRect {
                CGRect(x: (rect.minX - selection.minX) * sx, y: (selection.maxY - rect.maxY) * sy,
                       width: rect.width * sx, height: rect.height * sy)
            }
            self.init(viewport: pixels(geometry.viewport), exclusions: geometry.exclusions.map(pixels))
        }

        func contains(_ box: CGRect) -> Bool {
            viewport.contains(box) && !exclusions.contains { $0.intersects(box) }
        }
    }

    static func make(size: CGSize, deltaY: CGFloat, artwork: AXRenderArtwork,
                     snapshot: AXExtractionSnapshot, previous: Region, current: Region) -> AXRenderArtwork? {
        let width = Int(size.width), height = Int(size.height)
        let dy = deltaY.rounded()
        guard width >= 64, height >= 64, width * height <= 3_000_000,
              dy.isFinite, abs(dy) >= 4, abs(dy) < size.height / 2, snapshot.status == .complete,
              let surface = snapshot.documentSurfaces.only, surface.dialogBoxes.isEmpty,
              !snapshot.imageRegions.contains(where: { $0.status == "selected" }) else { return nil }
        let body = Set(surface.bodyNodes)
        let parents = Dictionary(uniqueKeysWithValues: snapshot.observations.map { ($0.id, $0.parent) })
        func isBody(_ node: Int) -> Bool {
            var current: Int? = node
            while let id = current {
                if body.contains(id) { return true }
                current = parents[id] ?? nil
            }
            return false
        }
        let eligible = Set(snapshot.paragraphUnits.compactMap { paragraph in
            !paragraph.isCodeBlock && paragraph.inlineContent == nil &&
                (paragraph.occlusionBoxes ?? []).isEmpty && !paragraph.members.isEmpty &&
                paragraph.members.allSatisfy(isBody) ? paragraph.node : nil
        })
        let rendered = Dictionary(grouping: artwork.diagnostics.filter { $0.status == "rendered" }, by: \.node)
        guard !eligible.isDisjoint(with: rendered.keys), !Task.isCancelled else { return nil }

        let full = CGRect(x: 0, y: 0, width: width, height: height)
        var clip: [CGRect] = [], reused: [AXRenderDiagnostic] = []
        for (node, parts) in rendered where eligible.contains(node) {
            guard !Task.isCancelled else { return nil }
            for part in parts {
                guard let originals = part.originalLineBoxes, originals.count == part.lineBoxes.count else { continue }
                var movedLines: [CGRect] = []
                for (box, original) in zip(part.lineBoxes, originals) {
                    // A long paragraph can straddle the viewport. Its fully painted
                    // lines are still safe to reuse independently.
                    guard artwork.clipRects.contains(where: { $0.contains(box) }) else { continue }
                    let source = box.union(original).integral
                    let destination = source.offsetBy(dx: 0, dy: dy)
                    guard full.contains(source), full.contains(destination),
                          previous.contains(source), current.contains(destination) else { continue }
                    let padded = source.insetBy(dx: -1, dy: -1)
                        .intersection(full).intersection(previous.viewport)
                        .intersection(full.intersection(current.viewport).offsetBy(dx: 0, dy: -dy))
                    let paddedDestination = padded.offsetBy(dx: 0, dy: dy)
                    clip.append(previous.contains(padded) && current.contains(paddedDestination)
                                ? paddedDestination : destination)
                    movedLines.append(box.offsetBy(dx: 0, dy: dy))
                }
                guard let first = movedLines.first else { continue }
                var diagnostic = AXRenderDiagnostic(node: part.node, segment: part.segment, status: part.status,
                    box: movedLines.dropFirst().reduce(first) { $0.union($1) })
                diagnostic.lineBoxes = movedLines
                reused.append(diagnostic)
            }
        }

        guard !clip.isEmpty, let previousBackground = artwork.background, let previousText = artwork.text else { return nil }
        func shifted(_ image: CGImage) -> CGImage? {
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.addRects(clip)
            context.clip()
            context.interpolationQuality = .none
            context.draw(image, in: full.offsetBy(dx: 0, dy: dy))
            return context.makeImage()
        }
        guard let background = shifted(previousBackground), let text = shifted(previousText) else { return nil }
        return AXRenderArtwork(background: background, text: text, debug: nil,
            items: [], fragments: [], clipRects: clip, diagnostics: reused, elapsed: 0)
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
