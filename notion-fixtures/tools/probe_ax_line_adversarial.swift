import AppKit
import ApplicationServices
func read(_ e:AXUIElement,_ k:String,_ i:CFTypeRef?=nil)->CFTypeRef?{var v:CFTypeRef?;let err=i.map{AXUIElementCopyParameterizedAttributeValue(e,k as CFString,$0,&v)} ?? AXUIElementCopyAttributeValue(e,k as CFString,&v);return err == .success ? v:nil}
func bounds(_ e:AXUIElement,_ n:Int)->[Double]?{var r=CFRange(location:0,length:n);guard let v=read(e,"AXBoundsForRange",AXValueCreate(.cfRange,&r)!),CFGetTypeID(v)==AXValueGetTypeID() else{return nil};var b=CGRect.zero;guard AXValueGetValue(v as! AXValue,.cgRect,&b) else{return nil};return [b.minX,b.minY,b.width,b.height]}
let app=AXUIElementCreateApplication(pid_t(CommandLine.arguments[1])!);AXUIElementSetAttributeValue(app,"AXEnhancedUserInterface" as CFString,kCFBooleanTrue);Thread.sleep(forTimeInterval:2.5)
var stack=[app],seen=Set<AXUIElement>(),rows:[[String:Any]]=[]
while let e=stack.popLast(),seen.count<3000{
 guard seen.insert(e).inserted else{continue};stack.append(contentsOf:read(e,"AXChildren") as? [AXUIElement] ?? [])
 guard read(e,"AXRole") as? String == "AXStaticText",let text=read(e,"AXValue") as? String,!text.isEmpty else{continue}
 var a:AXUIElement?=e,owner=""
 for _ in 0..<8{guard let current=a else{break};if let id=read(current,"AXDOMIdentifier") as? String,id.hasPrefix("case-"){owner=id;break};a=read(current,"AXParent").map{$0 as! AXUIElement}}
 guard !owner.isEmpty else{continue}
 let full=bounds(e,text.utf16.count),first=bounds(e,text.unicodeScalars.first!.value>0xFFFF ? 2:1)
 var source:String?=nil
 if let w=read(e,"AXTextMarkerRangeForUIElement",e),CFGetTypeID(w)==AXTextMarkerRangeGetTypeID(){let end=AXTextMarkerRangeCopyEndMarker(w as! AXTextMarkerRange);if let start=read(e,"AXPreviousLineStartTextMarkerForTextMarker",end),CFGetTypeID(start)==AXTextMarkerGetTypeID(){source=read(e,"AXStringForTextMarkerRange",AXTextMarkerRangeCreate(nil,start as! AXTextMarker,end)) as? String}}
 rows.append(["case":owner,"text":text,"first":first as Any? ?? NSNull(),"full":full as Any? ?? NSNull(),"reverseMatches":source==text,"reverseSource":source as Any? ?? NSNull()])
}
print(String(data:try JSONSerialization.data(withJSONObject:rows,options:[.sortedKeys]),encoding:.utf8)!)
