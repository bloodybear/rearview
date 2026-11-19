import CoreGraphics
import Foundation
import NotionAXCore

/// Repositions complete body lines using the measured AX displacement.
enum AXScrollPreview {
    static func make(size: CGSize, deltaY: CGFloat, artwork: AXRenderArtwork,
                     snapshot: AXExtractionSnapshot) -> AXRenderArtwork? {
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
        let inner = full.insetBy(dx: 2, dy: 2)
        var clip: [CGRect] = [], reused: [AXRenderDiagnostic] = []
        for (node, parts) in rendered where eligible.contains(node) {
            guard !Task.isCancelled else { return nil }
            var destinations: [CGRect] = []
            for part in parts {
                guard !part.clipped, !part.lineBoxes.isEmpty,
                      let originals = part.originalLineBoxes, originals.count == part.lineBoxes.count else { break }
                for (box, original) in zip(part.lineBoxes, originals) {
                    let source = box.union(original).insetBy(dx: -1, dy: -1).integral
                    let destination = source.offsetBy(dx: 0, dy: dy)
                    guard inner.contains(source), inner.contains(destination) else { break }
                    destinations.append(destination)
                }
            }
            guard !destinations.isEmpty, destinations.count == parts.reduce(0, { $0 + $1.lineBoxes.count }) else { continue }
            clip += destinations
            reused += parts.map { part in
                var diagnostic = AXRenderDiagnostic(node: part.node, segment: part.segment, status: part.status,
                    box: part.box.offsetBy(dx: 0, dy: dy))
                diagnostic.lineBoxes = part.lineBoxes.map { $0.offsetBy(dx: 0, dy: dy) }
                return diagnostic
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
