import Foundation
import AppKit
import Testing
@testable import Rearview

func withTestDefaults<T>(_ body: (UserDefaults) -> T) -> T {
    let suiteName = "RearviewTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }
    return body(defaults)
}

func expectApproximatelyEqual(
    _ lhs: CGFloat,
    _ rhs: CGFloat,
    tolerance: CGFloat = 0.000_001
) -> Bool {
    abs(lhs - rhs) < tolerance
}

func testLine(
    _ text: String,
    confidence: Float = 0.9,
    normalizedRect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)
) -> RecognizedLine {
    RecognizedLine(
        sourceText: text,
        normalizedRect: normalizedRect,
        confidence: confidence,
        background: .lightBackground,
        foreground: .darkText
    )
}

func testImage(width: Int = 16, height: Int = 16) -> CGImage? {
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    return context.makeImage()
}

func testMotionSource(columns: Int = 16, rows: Int = 12) -> [UInt8] {
    (0..<(columns * rows)).map { index in
        UInt8((index * 37 + (index / columns) * 19) % 251)
    }
}
