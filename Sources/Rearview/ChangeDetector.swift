import CoreGraphics

enum FrameChangeKind: Sendable, Equatable {
    case initial
    case unchanged
    case localOrScroll
    case scroll
    case sceneChange
}

struct FrameShift: Sendable, Equatable {
    let x: Int
    let y: Int

    static let zero = FrameShift(x: 0, y: 0)
}

struct FrameMotionEstimate: Sendable, Equatable {
    let kind: FrameChangeKind
    let shift: FrameShift
    let residual: Double
}

struct FrameChange: Sendable {
    let regionOfInterest: CGRect?
    let changedRatio: Double
    let fingerprint: UInt64
    let motion: FrameMotionEstimate
}

func classifyFrameMotion(
    previous: [UInt8], current: [UInt8], columns: Int, rows: Int,
    pixelThreshold: Int = 18
) -> FrameMotionEstimate {
    guard columns > 0, rows > 0,
          previous.count == columns * rows, current.count == previous.count else {
        return FrameMotionEstimate(kind: .sceneChange, shift: .zero, residual: .infinity)
    }

    var changed = 0
    var zeroDifference = 0
    for index in current.indices {
        let difference = abs(Int(current[index]) - Int(previous[index]))
        zeroDifference += difference
        if difference >= pixelThreshold { changed += 1 }
    }
    guard changed > 0 else {
        return FrameMotionEstimate(kind: .unchanged, shift: .zero, residual: 0)
    }

    let changedRatio = Double(changed) / Double(current.count)
    let zeroResidual = Double(zeroDifference) / Double(current.count)
    var bestShift = FrameShift.zero
    var bestResidual = Double.infinity

    let maximumXShift = min(4, max(0, columns / 4))
    let maximumYShift = min(6, max(0, rows / 4))
    for yShift in -maximumYShift...maximumYShift {
        for xShift in -maximumXShift...maximumXShift where xShift != 0 || yShift != 0 {
            let overlapWidth = columns - abs(xShift)
            let overlapHeight = rows - abs(yShift)
            guard overlapWidth > 0, overlapHeight > 0,
                  Double(overlapWidth * overlapHeight) / Double(current.count) >= 0.70 else { continue }
            let currentX0 = max(0, xShift)
            let currentY0 = max(0, yShift)
            let previousX0 = max(0, -xShift)
            let previousY0 = max(0, -yShift)
            var difference = 0
            for row in 0..<overlapHeight {
                let currentBase = (currentY0 + row) * columns + currentX0
                let previousBase = (previousY0 + row) * columns + previousX0
                for column in 0..<overlapWidth {
                    difference += abs(
                        Int(current[currentBase + column]) - Int(previous[previousBase + column])
                    )
                }
            }
            let residual = Double(difference) / Double(overlapWidth * overlapHeight)
            if residual < bestResidual {
                bestResidual = residual
                bestShift = FrameShift(x: xShift, y: yShift)
            }
        }
    }

    if bestShift != .zero, bestResidual <= 10, zeroResidual - bestResidual >= 4 {
        return FrameMotionEstimate(kind: .scroll, shift: bestShift, residual: bestResidual)
    }
    if changedRatio >= 0.45, bestResidual >= 14 {
        return FrameMotionEstimate(kind: .sceneChange, shift: .zero, residual: bestResidual)
    }
    return FrameMotionEstimate(
        kind: .localOrScroll, shift: bestShift, residual: min(zeroResidual, bestResidual)
    )
}

final class ChangeDetector: @unchecked Sendable {
    private let columns = 32
    private let rows = 24
    private var previous: [UInt8]?

    func reset() { previous = nil }

    func analyze(_ image: CGImage) -> FrameChange {
        var pixels = [UInt8](repeating: 0, count: columns * rows)
        guard let context = CGContext(
            data: &pixels, width: columns, height: rows, bitsPerComponent: 8,
            bytesPerRow: columns, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return FrameChange(
                regionOfInterest: nil, changedRatio: 1, fingerprint: 0,
                motion: FrameMotionEstimate(kind: .sceneChange, shift: .zero, residual: .infinity)
            )
        }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: columns, height: rows))

        var hash: UInt64 = 1469598103934665603
        for value in pixels { hash = (hash ^ UInt64(value)) &* 1099511628211 }
        guard let previous, previous.count == pixels.count else {
            self.previous = pixels
            return FrameChange(
                regionOfInterest: CGRect(x: 0, y: 0, width: 1, height: 1),
                changedRatio: 1, fingerprint: hash,
                motion: FrameMotionEstimate(kind: .initial, shift: .zero, residual: 0)
            )
        }
        self.previous = pixels
        let motion = classifyFrameMotion(
            previous: previous, current: pixels, columns: columns, rows: rows
        )
        var changed = 0
        var minX = columns, minY = rows, maxX = -1, maxY = -1
        for y in 0..<rows {
            for x in 0..<columns {
                let index = y * columns + x
                guard abs(Int(pixels[index]) - Int(previous[index])) >= 18 else { continue }
                changed += 1
                minX = min(minX, x); minY = min(minY, y)
                maxX = max(maxX, x); maxY = max(maxY, y)
            }
        }
        guard changed > 0 else {
            return FrameChange(
                regionOfInterest: nil, changedRatio: 0, fingerprint: hash, motion: motion
            )
        }
        let padding = 1
        let x0 = max(0, minX - padding), x1 = min(columns - 1, maxX + padding)
        let y0 = max(0, minY - padding), y1 = min(rows - 1, maxY + padding)
        let region = CGRect(
            x: CGFloat(x0) / CGFloat(columns),
            y: CGFloat(y0) / CGFloat(rows),
            width: CGFloat(x1 - x0 + 1) / CGFloat(columns),
            height: CGFloat(y1 - y0 + 1) / CGFloat(rows)
        )
        return FrameChange(
            regionOfInterest: region,
            changedRatio: Double(changed) / Double(columns * rows),
            fingerprint: hash, motion: motion
        )
    }
}
