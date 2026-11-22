import Foundation
import ApplicationServices

// Native line boundaries, not rectangle unions. Keep original node observations.
// Multi-leaf units walk backwards from their original end and re-anchor line
// bounds onto the actual text leaves. Never union node rectangles or clip lines.
// Exact suffix matching rejects foreign UI/generated ellipsis text; unsupported
// ranges stay partial rather than falling back to heuristic geometry.
// See notion-fixtures/AX_LINE_DIRECTION_COMPARISON.md for the measured decision.
package enum NativeParagraphLines {
package struct Leaf {let id:Int;let node:AXUIElement;let text:String;let base:Int;var length:Int{(text as NSString).length}}
package struct Unit {let id:Int;let node:AXUIElement;let role:String;let text:String;let leaves:[Leaf]}
package struct Line {let start:Int;let length:Int;let text:String;let box:CGRect}
package struct Output {var lines:[Line]=[];var status="complete"; var observedSource:String?}
package final class Queries {
 var wholeCache:[AXUIElement:AXTextMarkerRange]=[:]
 let investigator:RangeInvestigator
 init(_ investigator:RangeInvestigator){self.investigator=investigator}
 func get(_ e:AXUIElement,_ k:String,_ input:CFTypeRef?=nil)->CFTypeRef? {
 guard !investigator.cancellation.isCancelled, Date()<investigator.deadline,investigator.calls<investigator.maxCalls else{investigator.limitReached=true;return nil}
 recordAXQuery();investigator.calls+=1;var value:CFTypeRef?
 let err=input.map{AXUIElementCopyParameterizedAttributeValue(e,k as CFString,$0,&value)} ?? AXUIElementCopyAttributeValue(e,k as CFString,&value)
 recordAXResult(k,err)
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
static func native(_ u:Unit,_ q:Queries,topFirstBounds:Bool = false)->Output {
 var out=Output()
 // The parent's range can include generated ellipsis text or embedded-object
 // placeholders. Anchor to the actual text leaves before validating the source.
 // Keep these native endpoints cached for later line re-anchoring; no box unions.
 guard let first=u.leaves.first,let last=u.leaves.last,
       let firstRange=q.whole(first.node),let lastRange=q.whole(last.node) else{out.status="leaf_span_unavailable";return out}
 let whole=AXTextMarkerRangeCreate(nil,AXTextMarkerRangeCopyStartMarker(firstRange),AXTextMarkerRangeCopyEndMarker(lastRange))
 guard let source=q.string(u.node,whole) else{out.status="native_source_read_failed";return out}
 out.observedSource=source
 guard !source.isEmpty else{out.status="native_source_empty";return out}
 guard source.utf16.elementsEqual(u.leaves.map({$0.text}).joined().utf16) else{out.status="native_leaf_text_mismatch";return out}
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

 var pending:[(Int,String,AXTextMarkerRange)]=[]
 func append(_ start:Int,_ text:String)->Bool {
 let count=(text as NSString).length
 guard let a=endpoint(start,true),let b=endpoint(start+count,false) else{out.status="leaf_endpoint_unavailable";return false}
 let range=AXTextMarkerRangeCreate(nil,a,b)
 guard q.string(u.node,range)==text else{out.status="rebased_string_mismatch";return false}
 if topFirstBounds {pending.append((start,text,range));return true}
 guard let box=q.box(u.node,range) else{out.status="marker_empty_bounds";return false}
 out.lines.append(Line(start:start,length:count,text:text,box:box));return true
 }
 let total=(source as NSString).length
 var marker=AXTextMarkerRangeCopyEndMarker(whole),offset=total
 for _ in 0..<128 where offset>0 {
 guard let boundary=q.get(u.node,"AXPreviousLineStartTextMarkerForTextMarker",marker),CFGetTypeID(boundary)==AXTextMarkerGetTypeID() else{out.status="reverse_empty_or_stalled_range";break}
 var a=boundary as! AXTextMarker
 guard var text=q.string(u.node,AXTextMarkerRangeCreate(nil,a,marker)),!text.isEmpty else{out.status="reverse_empty_or_stalled_range";break}
 // Native line starts may precede this text span (e.g. a page icon). Restrict
 // the text range to the real first-leaf start and revalidate, never trim text.
 if TextRangeSafety.lineCrossesNodeStart(text,before:offset,in:source) {
 a=AXTextMarkerRangeCopyStartMarker(whole)
 guard let bounded=q.string(u.node,AXTextMarkerRangeCreate(nil,a,marker)),bounded.utf16.elementsEqual((source as NSString).substring(to:offset).utf16) else{out.status="reverse_string_mismatch";break}
 text=bounded
 }
 let count=(text as NSString).length
 guard count<=offset,slice(source,offset-count,count)?.utf16.elementsEqual(text.utf16)==true else{out.status="reverse_string_mismatch";break}
 if !append(offset-count,text){break};offset-=count;marker=a
 }
 for (start,text,range) in pending.reversed() {
 guard let box=q.box(u.node,range) else{out.status="marker_empty_bounds";break}
 out.lines.append(Line(start:start,length:(text as NSString).length,text:text,box:box))
 }
 out.lines.sort{$0.start<$1.start};if offset>0 && out.status=="complete"{out.status="line_limit"};return out
}

}

extension RangeInvestigator {
    func inspectParagraph(_ element:AXUIElement, role:String, leaves:[(Int,AXUIElement,String)], viewport:CGRect, topFirstBounds:Bool = false) -> [String:Any] {
        let source=leaves.map{$0.2}.joined()
        if leaves.count==1,let leaf=leaves.first {
            var result=inspect(leaf.1,text:leaf.2,sourceNode:leaf.0,viewport:viewport,topFirstBounds:topFirstBounds)
            result["lineMethod"]="markers-local-reverse-single-node"
            result["lineSourceText"]=source
            return result
        }
        let started=Date()
        defer{elapsed+=Date().timeIntervalSince(started)}
        var base=0
        let inputs=leaves.map{leaf -> NativeParagraphLines.Leaf in
            defer{base+=(leaf.2 as NSString).length}
            return NativeParagraphLines.Leaf(id:leaf.0,node:leaf.1,text:leaf.2,base:base)
        }
        let unit=NativeParagraphLines.Unit(id:0,node:element,role:role,text:source,leaves:inputs)
        let output=NativeParagraphLines.native(unit,NativeParagraphLines.Queries(self),topFirstBounds:topFirstBounds)
        return ["lineMethod":"native-paragraph-markers-reverse","rangeAnchor":"first-to-last-text-leaf","lineSourceText":source,
                "lineRangeStatus":limitReached ? "query_limit_reached" : output.status=="complete" ? "complete_unverified":output.status,
                "coveredUTF16Length":output.lines.reduce(0){$0+$1.length},"totalUTF16Length":(source as NSString).length,
                "sourceComparison": output.status == "native_leaf_text_mismatch" ? ["expected":source,"observed":output.observedSource ?? ""] : [:],
                "lineRanges":output.lines.map{line -> [String:Any] in
                    ["rangeStart":line.start,"rangeLength":line.length,"text":line.text,"box":rect(line.box),
                     "boxKind":"native_paragraph_reverse_line","visibility":TextRangeSafety.visibility(line.box,in:viewport)]
                }]
    }
}
