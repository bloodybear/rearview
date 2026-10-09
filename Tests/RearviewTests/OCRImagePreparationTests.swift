import Foundation
import CoreGraphics
import Testing
@testable import Rearview

struct OCRImagePreparationTests {
    @Test func unpremultipliedImageReallyScalesInsteadOfSilentlyUsingOriginal() throws {
        let data = Data(repeating: 255, count: 10 * 8 * 4)
        let provider = try #require(CGDataProvider(data: data as CFData))
        let image = try #require(CGImage(width: 10, height: 8, bitsPerComponent: 8,
            bitsPerPixel: 32, bytesPerRow: 40, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        #expect(image.alphaInfo == .last)
        let scaled = ocrScaledImage(image, by: 3)
        #expect(scaled.width == 30 && scaled.height == 24)
        #expect(scaled.alphaInfo == .premultipliedLast)
        #expect(ocrScaledImage(image, by: 1) === image)
    }
}
