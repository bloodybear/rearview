// Frozen parent-range baseline for the leaf-span comparison. Research only.
import Foundation
import ApplicationServices

// Native line boundaries, not rectangle unions. Keep original node observations.
// Multi-leaf units walk backwards from their original end and re-anchor line
// bounds onto the actual text leaves. Never union node rectangles or clip lines.
// Exact suffix matching rejects foreign UI/generated ellipsis text; unsupported
// ranges stay partial rather than falling back to heuristic geometry.
// See notion-fixtures/AX_LINE_DIRECTION_COMPARISON.md for the measured decision.
enum PreviousParentRangeLines {
struct Leaf {let id:Int;let node:AXUIElement;let text:String;let base:Int;var length:Int{(text as NSString).length}}
struct Unit {let id:Int;let node:AXUIElement;let role:String;let text:String;let leaves:[Leaf]}
struct Line {let start:Int;let length:Int;let text:String;let box:CGRect}
struct Output {var lines:[Line]=[];var status="complete"}
final class Queries {
 var wholeCache:[AXUIElement:AXTextMarkerRange]=[:]
 let investigator:RangeInvestigator
 init(_ investigator:RangeInvestigator){self.investigator=investigator}
 func get(_ e:AXUIElement,_ k:String,_ input:CFTypeRef?=nil)->CFTypeRef? {
 guard Date()<investigator.deadline,investigator.calls<investigator.maxCalls else{investigator.limitReached=true;return nil}
 investigator.calls+=1;var value:CFTypeRef?
 let err=input.map{AXUIElementCopyParameterizedAttributeValue(e,k as CFString,$0,&value)} ?? AXUIElementCopyAttributeValue(e,k as CFString,&value)
 return err == .success ? value:nil
 }
 func whole(_ e:AXUIElement)->AXTextMarkerRange?{if let cached=wholeCache[e]{return cached};guard let r=get(e,"AXTextMarkerRangeForUIElement",e),CFGetTypeID(r)==AXTextMarkerRangeGetTypeID() else{return nil};let range=r as! AXTextMarkerRange;wholeCache[e]=range;return range}
 func string(_ e:AXUIElement,_ r:AXTextMarkerRange)->String?{get(e,"AXStringForTextMarkerRange",r) as? String}
 func box(_ e:AXUIElement,_ r:AXTextMarkerRange)->CGRect? {
 guard let v=get(e,"AXBoundsForTextMarkerRange",r),CFGetTypeID(v)==AXValueGetTypeID() else{return nil};var b=CGRect.zero
 guard AXValueGetValue(v as! AXValue,.cgRect,&b),b.minX.isFinite,b.minY.isFinite,b.width.isFinite,b.height.isFinite,b.width>0,b.height>0 else{return nil};return b
 }
}
static func slice(_ text:String,_ start:Int,_ length:Int)->String? {
 let utf=Array(text.utf16);guard start>=0,length>0,start+length<=utf.count else{return nil}
 for i in [start,start+length] {if i>0 && i<utf.count && (0xD800...0xDBFF).contains(utf[i-1]) && (0xDC00...0xDFFF).contains(utf[i]){return nil}}
 return (text as NSString).substring(with:NSRange(location:start,length:length))
}
static func native(_ u:Unit,_ q:Queries)->Output {
 var out=Output()
 guard let whole=q.whole(u.node),let source=q.string(u.node,whole),source==u.leaves.map({$0.text}).joined(),!source.isEmpty else{out.status="native_leaf_text_mismatch";return out}
 var nodeRanges:[Int:AXTextMarkerRange]=[:],internals:[Int:[Int:AXTextMarker]]=[:]
 func nodeRange(_ leaf:Leaf)->AXTextMarkerRange? {
 if let cached=nodeRanges[leaf.id]{return cached};let range=q.whole(leaf.node);nodeRanges[leaf.id]=range;return range
 }
 func endpoint(_ offset:Int,_ isStart:Bool)->AXTextMarker? {
 guard let leaf=u.leaves.first(where:{isStart ? $0.base<=offset && offset<$0.base+$0.length : $0.base<offset && offset<=$0.base+$0.length}),let range=nodeRange(leaf) else{return nil}
 let local=offset-leaf.base
 if local==0{return AXTextMarkerRangeCopyStartMarker(range)}
 if local==leaf.length{return AXTextMarkerRangeCopyEndMarker(range)}
 if let cached=internals[leaf.id]?[local]{return cached}
 var position=leaf.length,marker=AXTextMarkerRangeCopyEndMarker(range)
 while position>local {
 guard let a=q.get(leaf.node,"AXPreviousLineStartTextMarkerForTextMarker",marker),CFGetTypeID(a)==AXTextMarkerGetTypeID(),let text=q.string(leaf.node,AXTextMarkerRangeCreate(nil,a as! AXTextMarker,marker)),!text.isEmpty else{return nil}
 let count=(text as NSString).length
 guard count<=position,slice(leaf.text,position-count,count)==text else{return nil}
 position-=count;internals[leaf.id,default:[:]][position]=(a as! AXTextMarker);marker=a as! AXTextMarker
 }
 return position==local ? marker:nil
 }

 func append(_ start:Int,_ text:String)->Bool {
 let count=(text as NSString).length
 guard let a=endpoint(start,true),let b=endpoint(start+count,false) else{out.status="leaf_endpoint_unavailable";return false}
 let range=AXTextMarkerRangeCreate(nil,a,b)
 guard q.string(u.node,range)==text else{out.status="rebased_string_mismatch";return false}
 guard let box=q.box(u.node,range) else{out.status="marker_empty_bounds";return false}
 out.lines.append(Line(start:start,length:count,text:text,box:box));return true
 }
 let total=(source as NSString).length
 var marker=AXTextMarkerRangeCopyEndMarker(whole),offset=total
 for _ in 0..<128 where offset>0 {
 guard let a=q.get(u.node,"AXPreviousLineStartTextMarkerForTextMarker",marker),CFGetTypeID(a)==AXTextMarkerGetTypeID(),let text=q.string(u.node,AXTextMarkerRangeCreate(nil,a as! AXTextMarker,marker)),!text.isEmpty else{out.status="reverse_empty_or_stalled_range";break}
 let count=(text as NSString).length
 guard count<=offset,slice(source,offset-count,count)==text else{out.status="reverse_string_mismatch";break}
 if !append(offset-count,text){break};offset-=count;marker=a as! AXTextMarker
 }
 out.lines.sort{$0.start<$1.start};if offset>0 && out.status=="complete"{out.status="line_limit"};return out
}

}
