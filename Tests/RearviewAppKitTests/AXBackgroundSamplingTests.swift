import XCTest
import AppKit
@testable import Rearview

final class AXBackgroundSamplingTests: XCTestCase {
    func testUsesOnlyInsideHorizontalEdgesAndModalColor() throws {
        let context = try XCTUnwrap(CGContext(data:nil,width:20,height:20,bitsPerComponent:8,
            bytesPerRow:80,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray:0,alpha:1))
        context.fill(CGRect(x:0,y:0,width:20,height:20))
        // Brown label surrounded by black. White text fills its interior,
        // and the left/right edges, but not the horizontal background strips.
        context.setFillColor(CGColor(colorSpace:CGColorSpaceCreateDeviceRGB(),components:[0.6,0.3,0.1,1])!)
        context.fill(CGRect(x:4,y:4,width:12,height:12))
        context.setFillColor(CGColor(gray:1,alpha:1))
        context.fill(CGRect(x:4,y:5,width:12,height:10))
        context.fill(CGRect(x:4,y:4,width:1,height:12))
        context.fill(CGRect(x:15,y:4,width:1,height:12))
        let image = try XCTUnwrap(context.makeImage())
        let color = try XCTUnwrap(AXRenderColors.sampleBackground(in:image,pixelRect:CGRect(x:4,y:4,width:12,height:12)))
        XCTAssertEqual(color.red,0.6,accuracy:1/255)
        XCTAssertEqual(color.green,0.3,accuracy:1/255)
        XCTAssertEqual(color.blue,0.1,accuracy:1/255)
        XCTAssertEqual(color.alpha,1)
    }
    func testClippedEdgesAndFallback() throws {
        let line = CGRect(x:10,y:10,width:40,height:20)
        let bottomOnly = try XCTUnwrap(AXRenderColors.backgroundSample(lines:[line],clips:[CGRect(x:0,y:0,width:100,height:25)]))
        XCTAssertFalse(bottomOnly.top); XCTAssertTrue(bottomOnly.bottom); XCTAssertFalse(bottomOnly.fallback)
        let topOnly = try XCTUnwrap(AXRenderColors.backgroundSample(lines:[line],clips:[CGRect(x:0,y:15,width:100,height:50)]))
        XCTAssertTrue(topOnly.top); XCTAssertFalse(topOnly.bottom)
        let fallback = try XCTUnwrap(AXRenderColors.backgroundSample(lines:[line],clips:[CGRect(x:0,y:15,width:100,height:10)]))
        XCTAssertTrue(fallback.top); XCTAssertTrue(fallback.bottom); XCTAssertTrue(fallback.fallback)
        let small = CGRect(x:60,y:16,width:5,height:5)
        let preferred = try XCTUnwrap(AXRenderColors.backgroundSample(lines:[line,small],clips:[CGRect(x:0,y:15,width:100,height:10)]))
        XCTAssertEqual(preferred.box,small); XCTAssertFalse(preferred.fallback)
        XCTAssertNil(AXRenderColors.backgroundSample(lines:[line],clips:[CGRect(x:100,y:100,width:5,height:5)]))
        XCTAssertNil(AXRenderColors.backgroundSample(lines:[CGRect(x:0,y:0,width:0.2,height:0.2)],clips:[CGRect(x:0,y:0,width:5,height:5)]))
    }

    func testLineIntersectionStaysInsideParagraph() throws {
        let chosen = try XCTUnwrap(AXRenderColors.backgroundSample(
            lines:[CGRect(x:20,y:20,width:300,height:18)],clips:[CGRect(x:10,y:10,width:90,height:40)]))
        XCTAssertEqual(chosen.box,CGRect(x:20,y:20,width:80,height:18))
        XCTAssertTrue(chosen.top); XCTAssertTrue(chosen.bottom)
    }
}
