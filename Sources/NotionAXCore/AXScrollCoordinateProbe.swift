import ApplicationServices

/// Scroll alignment observations are tied to native AX element identity on the extraction queue.
struct AXScrollCoordinateProbe {
    struct Coordinate {
        let element: AXUIElement
        let text: String
        let range: Range<Int>?
        let box: CGRect
        let node: Int
        var alignedBox: CGRect? = nil
    }

    struct Alignment {
        let records: [[String: Any]]
        let coordinates: [Coordinate]
    }

    static func compare(previous: [Coordinate], current: [Coordinate], displacement: CGFloat,
                        viewport: CGRect, exclusions: [CGRect], referenceIsStable: Bool = true) -> Alignment {
        guard displacement.isFinite, abs(displacement) >= 2 else {
            return Alignment(records: [], coordinates: current)
        }
        func visible(_ box: CGRect) -> Bool {
            viewport.contains(box) && !exclusions.contains { $0.intersects(box) }
        }
        let matches = current.map { value -> (movement: CGFloat, offset: CGFloat, catchesUp: Bool)? in
            guard visible(value.box) else { return nil }
            let candidates = previous.filter {
                $0.range == value.range && $0.text == value.text && CFEqual($0.element, value.element) &&
                    visible($0.box) && abs($0.box.minX - value.box.minX) <= 1 &&
                    abs($0.box.width - value.box.width) <= 1 && abs($0.box.height - value.box.height) <= 1
            }
            guard candidates.count == 1, let original = candidates.first else { return nil }
            let moved = value.box.minY - original.box.minY
            guard let aligned = referenceIsStable ? original.box : original.alignedBox,
                  visible(aligned) else { return nil }
            let offset = aligned.minY + displacement - value.box.minY
            // AX can have already reached the next capture's position when the
            // previous result was collected. Its raw coordinate may then repeat.
            let catchesUp = !referenceIsStable && abs(moved) < 2 &&
                abs(original.box.minY - aligned.minY) >= 2 && abs(offset) <= 1
            return (moved, offset, catchesUp)
        }
        var lastCorrection: [Bool: CGFloat] = [:]
        var references = current
        let records = current.indices.map { index -> [String: Any] in
            let value = current[index]
            let match = matches[index]
            var status = "unavailable"
            var correction: CGFloat = 0
            let isLine = value.range != nil
            if visible(value.box) {
                if let (moved, offset, catchesUp) = match {
                    if (catchesUp || (moved.sign == displacement.sign && abs(moved) >= 2)),
                       abs(offset) <= viewport.height / 3, visible(value.box.offsetBy(dx: 0, dy: offset)) {
                        correction = offset
                        lastCorrection[isLine] = offset
                        status = "matched"
                    } else {
                        status = "stationary_or_inconsistent"
                    }
                } else if let offset = lastCorrection[isLine], visible(value.box.offsetBy(dx: 0, dy: offset)) {
                    correction = offset
                    status = "inherited"
                }
            }
            let corrected = value.box.offsetBy(dx: 0, dy: correction)
            if status == "matched" || status == "inherited" {
                references[index].alignedBox = corrected
            }
            var record: [String: Any] = ["node": value.node, "source": status, "dy": correction,
                "original": rect(value.box), "corrected": rect(corrected)]
            if let range = value.range {
                record["rangeStart"] = range.lowerBound
                record["rangeLength"] = range.count
            }
            return record
        }
        return Alignment(records: records, coordinates: references)
    }
}
