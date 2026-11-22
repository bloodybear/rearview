#if DEBUG
import CoreGraphics
import XCTest
@testable import Rearview

final class AXScrollPixelProbeTests: XCTestCase {
    func testCorrectedLineKeepsTranslationWidthAndExcludesFixedPanel() {
        let line = CGRect(x: 10, y: 30, width: 30, height: 12)
        let body = CGRect(x: 0, y: 0, width: 160, height: 130)
        let plain = AXLineRendering.scrollProbeClips(line: line,
            regions: [CGRect(x: 10, y: 20, width: 120, height: 80)], delta: 20,
            viewport: body, exclusions: [CGRect(x: 100, y: 0, width: 60, height: 130)])
        XCTAssertEqual(plain, [CGRect(x: 10, y: 50, width: 90, height: 12)])
    }

    func testFindsSignedPixelDistanceDespiteSmallLocalChange() throws {
        let width = 320, height = 480
        func frame(displacement: Int, occlusion: Bool = false) throws -> CGImage {
            let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            for index in 0..<37 {
                let y = index * 13 + (index * index) % 11
                let x = (index * 23) % 110
                context.setFillColor(gray: CGFloat(index % 5) / 10, alpha: 1)
                context.fill(CGRect(x: x, y: y - displacement, width: 164 + index % 27, height: 4 + index % 3))
            }
            if occlusion {
                context.setFillColor(gray: 0.8, alpha: 1)
                context.fill(CGRect(x: 0, y: 185, width: 45, height: 34))
            }
            return try XCTUnwrap(context.makeImage())
        }

        let previous = try frame(displacement: 0)
        let body = CGRect(x: 0, y: 0, width: width, height: height)
        for delta in [-27, 13, 32] {
            let current = try frame(displacement: delta, occlusion: true)
            XCTAssertEqual(AXScrollPixelProbe.estimate(previous: previous, current: current,
                                                       body: body, exclusions: []), delta)
        }
    }
}
#endif
