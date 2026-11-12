import Foundation
import ApplicationServices

// Native line boundaries, not rectangle unions. Keep original node observations.
// Single-leaf units use the existing markers-local inspector; the core below is
// used only for multiple leaves. See AX_LINE_METHOD_BENCHMARK.md for measurements.
// Known limitations intentionally retained: zero-width newline bounds stop the
// paragraph, and inline math may expose logical breaks within one visual line.
enum DirectionalLinesResearch {
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
 func end(_ e:AXUIElement,_ start:AXTextMarker)->AXTextMarker?{guard let v=get(e,"AXNextLineEndTextMarkerForTextMarker",start),CFGetTypeID(v)==AXTextMarkerGetTypeID() else{return nil};return (v as! AXTextMarker)}
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
static func native(_ u:Unit,_ q:Queries, reverse:Bool=false)->Output {
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
 if reverse {
 var position=leaf.length,marker=AXTextMarkerRangeCopyEndMarker(range)
 while position>local {
 guard let a=q.get(leaf.node,"AXPreviousLineStartTextMarkerForTextMarker",marker),CFGetTypeID(a)==AXTextMarkerGetTypeID(),let text=q.string(leaf.node,AXTextMarkerRangeCreate(nil,a as! AXTextMarker,marker)),!text.isEmpty else{return nil}
 let count=(text as NSString).length
 guard count<=position,slice(leaf.text,position-count,count)==text else{return nil}
 position-=count;internals[leaf.id,default:[:]][position]=(a as! AXTextMarker);marker=a as! AXTextMarker
 }
 return position==local ? marker:nil
 }
 var position=0,marker=AXTextMarkerRangeCopyStartMarker(range)
 while position<local {
 guard let end=q.end(leaf.node,marker),let text=q.string(leaf.node,AXTextMarkerRangeCreate(nil,marker,end)),!text.isEmpty else{return nil}
 let count=(text as NSString).length
 guard slice(leaf.text,position,count)==text else{return nil}
 position+=count;internals[leaf.id,default:[:]][position]=end;marker=end
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
 // Explicit control roots can have AX logical breaks between icon and label.
 // Require AX itself to return the complete unit as a line before taking one box.
 if !reverse && u.role != "AXTextArea" && u.leaves.count>1 {
 for leaf in u.leaves {
 guard let range=nodeRange(leaf) else{continue}
 let seed=AXTextMarkerRangeCopyStartMarker(range)
 var seeds=[seed]
 if let next=q.get(leaf.node,"AXNextTextMarkerForTextMarker",seed),CFGetTypeID(next)==AXTextMarkerGetTypeID(){seeds.append(next as! AXTextMarker)}
 for marker in seeds {
 guard let a=q.get(u.node,"AXPreviousLineStartTextMarkerForTextMarker",marker),CFGetTypeID(a)==AXTextMarkerGetTypeID(),let b=q.end(u.node,marker) else{continue}
 let r=AXTextMarkerRangeCreate(nil,a as! AXTextMarker,b)
 if q.string(u.node,r)==source {_ = append(0,source);return out}
 }
 }
 out.status="control_full_line_unavailable";return out
 }
 let total=(source as NSString).length
 if reverse {
 var marker=AXTextMarkerRangeCopyEndMarker(whole),offset=total
 for _ in 0..<128 where offset>0 {
 guard let a=q.get(u.node,"AXPreviousLineStartTextMarkerForTextMarker",marker),CFGetTypeID(a)==AXTextMarkerGetTypeID(),let text=q.string(u.node,AXTextMarkerRangeCreate(nil,a as! AXTextMarker,marker)),!text.isEmpty else{out.status="reverse_empty_or_stalled_range";break}
 let count=(text as NSString).length
 guard count<=offset,slice(source,offset-count,count)==text else{out.status="reverse_string_mismatch";break}
 if !append(offset-count,text){break};offset-=count;marker=a as! AXTextMarker
 }
 out.lines.sort{$0.start<$1.start};if offset>0 && out.status=="complete"{out.status="line_limit"};return out
 }
 var marker=AXTextMarkerRangeCopyStartMarker(whole),offset=0
 for _ in 0..<128 where offset<total {
 guard let end=q.end(u.node,marker),let text=q.string(u.node,AXTextMarkerRangeCreate(nil,marker,end)),!text.isEmpty else{out.status="marker_empty_or_stalled_range";break}
 let count=(text as NSString).length
 guard slice(source,offset,count)==text else{out.status="marker_string_mismatch";break}
 if !append(offset,text){break};offset+=count;marker=end
 }
 if offset<total && out.status=="complete"{out.status="line_limit"};return out
}

}

extension DirectionalLinesResearch {
 static func inspect(_ u:Unit,_ q:Queries,reverse:Bool)->Output {
 guard u.leaves.count==1,let leaf=u.leaves.first else{return native(u,q,reverse:reverse)}
 var out=Output();guard let whole=q.whole(leaf.node) else{out.status="marker_range_unavailable";return out}
 var marker=reverse ? AXTextMarkerRangeCopyEndMarker(whole):AXTextMarkerRangeCopyStartMarker(whole)
 let total=leaf.length;var offset=reverse ? total:0
 for _ in 0..<128 where reverse ? offset>0 : offset<total {
 let key=reverse ? "AXPreviousLineStartTextMarkerForTextMarker":"AXNextLineEndTextMarkerForTextMarker"
 guard let other=q.get(leaf.node,key,marker),CFGetTypeID(other)==AXTextMarkerGetTypeID() else{out.status="line_boundary_unavailable";break}
 let range=reverse ? AXTextMarkerRangeCreate(nil,other as! AXTextMarker,marker):AXTextMarkerRangeCreate(nil,marker,other as! AXTextMarker)
 guard let text=q.string(leaf.node,range),!text.isEmpty else{out.status="empty_or_stalled_range";break}
 let count=(text as NSString).length,start=reverse ? offset-count:offset
 guard slice(leaf.text,start,count)==text else{out.status="string_mismatch";break}
 guard let box=q.box(leaf.node,range) else{out.status="empty_bounds";break}
 out.lines.append(Line(start:start,length:count,text:text,box:box));offset=reverse ? start:start+count;marker=other as! AXTextMarker
 }
 if (reverse ? offset>0:offset<total) && out.status=="complete"{out.status="line_limit"}
 out.lines.sort{$0.start<$1.start};return out
 }
}
