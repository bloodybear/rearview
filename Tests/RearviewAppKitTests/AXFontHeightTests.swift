import XCTest
import Foundation
@testable import Rearview
import NotionAXCore
final class AXFontHeightTests:XCTestCase {
 func testEmojiClassification() {
  for s in ["✅","👩‍💻","🇯🇵","👍🏽","1️⃣"]{XCTAssertTrue(AXFontHeight.emojiNode(s))}
  for s in ["","文章","1","✅✅","文✅"]{XCTAssertFalse(AXFontHeight.emojiNode(s))}
 }
 func testTextHeightAndFallback() throws {
  func node(_ id:Int,_ text:String,_ h:Double)throws->AXNode {
   try JSONDecoder().decode(AXNode.self,from:JSONSerialization.data(withJSONObject:["id":id,"role":"AXStaticText","value":text,"title":"","frame":["x":10,"y":10,"width":50,"height":h]]))
  }
  let line=try JSONDecoder().decode(AXLine.self,from:JSONSerialization.data(withJSONObject:["text":"✅文字","rangeStart":0,"rangeLength":3,"box":["x":0,"y":0,"width":100,"height":27]]))
  let nodes=[1:try node(1,"✅",27),2:try node(2,"文字",19)]
  XCTAssertEqual(AXFontHeight.select(lines:[line],source:"✅文字",ids:[1,2],nodes:nodes,clips:[]),19)
  XCTAssertEqual(AXFontHeight.select(lines:[line],source:"different",ids:[1,2],nodes:nodes,clips:[]),27)
 }
}
