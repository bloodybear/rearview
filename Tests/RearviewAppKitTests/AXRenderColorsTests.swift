import XCTest
import AppKit
@testable import Rearview
@testable import NotionAXCore

final class AXRenderColorsTests: XCTestCase {
    private func node(_ id:Int,_ color:[Double]?,status:String? = "uniform",background:[Double]? = nil) throws -> AXNode {
        var value:[String:Any] = ["id":id,"role":"AXStaticText","value":"日本語","title":""]
        func fields(_ c:[Double])->[String:Double]{["red":c[0],"green":c[1],"blue":c[2],"alpha":c[3]]}
        if let color{value["foregroundColor"]=fields(color)}
        if let status{value["foregroundColorStatus"]=status}
        if let background{value["backgroundColor"]=fields(background)}
        return try JSONDecoder().decode(AXNode.self,from:JSONSerialization.data(withJSONObject:value))
    }
    private let white = RGBAColor(red:1,green:1,blue:1,alpha:1)

    func testAllNodesMustHaveTheSameVerifiedForeground() throws {
        let red = try node(1,[0.6,0,0,1]),same = try node(2,[0.6,0,0,1]),blue = try node(2,[0,0,0.6,1])
        XCTAssertEqual(AXRenderColors.select(background:white,sourceIDs:[1,2],observations:[1:red,2:same]).foregroundSource,"ax_uniform")
        XCTAssertEqual(AXRenderColors.select(background:white,sourceIDs:[1,2],observations:[1:red,2:blue]).foregroundSource,"default_mixed_or_missing_ax")
        XCTAssertEqual(AXRenderColors.select(background:white,sourceIDs:[1,2],observations:[1:red]).foregroundSource,"default_mixed_or_missing_ax")
        let old = try node(1,[0.6,0,0,1],status:nil)
        XCTAssertEqual(AXRenderColors.select(background:white,sourceIDs:[1],observations:[1:old]).foregroundSource,"default_mixed_or_missing_ax")
    }

    func testLowContrastAndTranslucentTextUseReadableDefaults() throws {
        for color in [[0.96,0.96,0.96,1],[0,0,0,0.05],[1,0,0,1]] {
            let result = AXRenderColors.select(background:white,sourceIDs:[1],observations:[1:try node(1,color)])
            XCTAssertEqual(result.foregroundSource,"default_low_contrast")
            XCTAssertGreaterThanOrEqual(result.contrast,4.5)
        }
        let result = AXRenderColors.select(background:white,sourceIDs:[1],observations:[1:try node(1,[0,0,0,0.8])])
        XCTAssertEqual(result.foregroundSource,"ax_uniform")
        XCTAssertEqual(result.foreground.red,0.2,accuracy:0.00001)
    }

    func testBackgroundAlwaysComesFromSamplingAndFallbackHasContrastOnMidtones() throws {
        let sample = RGBAColor(red:0.19,green:0.2,blue:0.21,alpha:0.96)
        let result = AXRenderColors.select(background:sample,sourceIDs:[1],observations:[1:try node(1,[1,1,1,1],background:[1,1,0,0.24])])
        XCTAssertEqual(result.background,RGBAColor(red:sample.red,green:sample.green,blue:sample.blue,alpha:1))
        for level in stride(from:CGFloat(0),through:1,by:0.01) {
            let colors = AXRenderColors.select(background:.init(red:level,green:level,blue:level,alpha:1),sourceIDs:[],observations:[:])
            XCTAssertGreaterThanOrEqual(colors.contrast,4.5)
        }
    }
}
