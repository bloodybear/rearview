import CoreGraphics
import Foundation

/// Estimates vertical scroll displacement. Coordinates here follow the capture's top-left pixel origin.
enum AXScrollPixelProbe {
    static func estimate(previous: CGImage, current: CGImage, body: CGRect, exclusions: [CGRect]) -> Int? {
        let bounds = CGRect(x: 0, y: 0, width: current.width, height: current.height)
        let region = body.intersection(bounds).integral
        guard region.width >= 64, region.height >= 96, region.width * region.height <= 3_000_000,
              previous.width == current.width, previous.height == current.height,
              let before = previous.cropping(to: region), let after = current.cropping(to: region) else { return nil }

        let detector = ChangeDetector()
        _ = detector.analyze(before)
        let seed = Int((CGFloat(detector.analyze(after).motion.shift.y) * region.height / 24).rounded())
        let radius = Int(ceil(region.height / 24))
        guard let oldBytes = pixels(before), let newBytes = pixels(after) else { return nil }
        let width = before.width, height = before.height
        let oldStride = oldBytes.count / height, newStride = newBytes.count / height
        return oldBytes.withUnsafeBytes { (old: UnsafeRawBufferPointer) in
            newBytes.withUnsafeBytes { (new: UnsafeRawBufferPointer) in
                var points: [(x: Int, y: Int, value: Int, prior: Int)] = []
                for band in 0..<8 {
                    for column in 1...12 {
                        let x = column * width / 13
                        let first = (band + 8) * height / 24
                        let last = (band + 9) * height / 24
                        var bestContrast = 19
                        var bestRow: Int?
                        for y in first..<last {
                            let position = CGPoint(x: region.minX + CGFloat(x), y: region.minY + CGFloat(y))
                            guard !exclusions.contains(where: { $0.contains(position) }) else { continue }
                            let offset = y * oldStride + x * 4 + 1
                            let contrast = abs(Int(old[offset]) - Int(old[offset - oldStride]))
                            if contrast > bestContrast {
                                bestContrast = contrast
                                bestRow = y
                            }
                        }
                        if let y = bestRow {
                            let offset = y * oldStride + x * 4 + 1
                            points.append((x, y, Int(old[offset]), Int(old[offset - oldStride])))
                        }
                    }
                }
                guard points.count >= 12 else { return nil }
                var best = Int.max, second = Int.max, winner = 0
                var support = 0
                // Downsampling can alias thin text. Retain a small zero-centered search
                // so a bad coarse seed does not hide short moves.
                let lower = max(-height / 3, min(-2 * radius, seed - radius))
                let upper = min(height / 3, max(2 * radius, seed + radius))
                for delta in lower...upper where abs(delta) <= 2 * radius || abs(delta - seed) <= radius {
                    var score = 0, matches = 0
                    for point in points {
                        let y = point.y + delta
                        let position = CGPoint(x: region.minX + CGFloat(point.x), y: region.minY + CGFloat(y))
                        guard y > 0, y < height, !exclusions.contains(where: { $0.contains(position) }) else {
                            score += 48
                            continue
                        }
                        let offset = y * newStride + point.x * 4 + 1
                        let difference = max(abs(point.value - Int(new[offset])),
                                             abs(point.prior - Int(new[offset - newStride])))
                        score += min(48, difference)
                        if difference <= 12 { matches += 1 }
                        if score >= second { break }
                    }
                    if score < best {
                        second = best
                        best = score
                        winner = delta
                        support = matches
                    } else if score < second {
                        second = score
                    }
                }
                guard best <= points.count * 8, second - best >= points.count,
                      support * 4 >= points.count * 3 else { return nil }
                return winner
            }
        }
    }

    private static func pixels(_ image: CGImage) -> Data? {
        let width = image.width, height = image.height
        var bytes = Data(count: width * height * 4)
        let success = bytes.withUnsafeMutableBytes { storage -> Bool in
            guard let context = CGContext(data: storage.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return success ? bytes : nil
    }
}
