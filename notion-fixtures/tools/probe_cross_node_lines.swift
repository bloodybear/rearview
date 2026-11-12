// Research only: ask AX for whole visual lines across inline nodes. No box union.
import AppKit
import ApplicationServices
var queryErrors: [String: [String: Int]] = [:]
func q(_ e: AXUIElement,_ k:String,_ input:CFTypeRef? = nil)->CFTypeRef? {
 var v:CFTypeRef?; let err = input.map{AXUIElementCopyParameterizedAttributeValue(e,k as CFString,$0,&v)} ?? AXUIElementCopyAttributeValue(e,k as CFString,&v)
 queryErrors[k,default:[:]][String(err.rawValue),default:0] += 1
 return err == .success ? v:nil
}
func bounds(_ e:AXUIElement,_ range:CFTypeRef)->Any {
 guard let v=q(e,"AXBoundsForTextMarkerRange",range),CFGetTypeID(v)==AXValueGetTypeID() else{return NSNull()}
 var r=CGRect.zero;guard AXValueGetValue(v as! AXValue,.cgRect,&r) else{return NSNull()}
 return ["x":r.minX,"y":r.minY,"width":r.width,"height":r.height]
}
func run() throws {
 guard CommandLine.arguments.count==2,AXIsProcessTrusted(),let p=NSRunningApplication.runningApplications(withBundleIdentifier:"notion.id").first else{throw NSError(domain:"Notion/AX required",code:1)}
 let app=AXUIElementCreateApplication(p.processIdentifier);AXUIElementSetMessagingTimeout(app,0.35)
 let prior=q(app,"AXManualAccessibility");defer{if let prior{AXUIElementSetAttributeValue(app,"AXManualAccessibility" as CFString,prior)}}
 AXUIElementSetAttributeValue(app,"AXManualAccessibility" as CFString,kCFBooleanTrue);Thread.sleep(forTimeInterval:2.5)
 var stack:[(AXUIElement,[AXUIElement])]=[(app,[])],results:[[String:Any]]=[],count=0
 while let (e,anc)=stack.popLast(),count<3500 {
 count+=1
 let role=q(e,"AXRole") as? String ?? "",text=q(e,"AXValue") as? String ?? ""
 if role=="AXStaticText", !text.isEmpty, text.count<400,
 let pos=q(e,"AXPosition"),let size=q(e,"AXSize"),CFGetTypeID(pos)==AXValueGetTypeID(),CFGetTypeID(size)==AXValueGetTypeID() {
 var pt=CGPoint.zero,sz=CGSize.zero;AXValueGetValue(pos as! AXValue,.cgPoint,&pt);AXValueGetValue(size as! AXValue,.cgSize,&sz)
 if sz.height>1,pt.y>=140,pt.y<760,pt.x<1024,pt.x+sz.width>0,
 let wr=q(e,"AXTextMarkerRangeForUIElement",e),CFGetTypeID(wr)==AXTextMarkerRangeGetTypeID() {
 let start=AXTextMarkerRangeCopyStartMarker(wr as! AXTextMarkerRange)
 let finish=AXTextMarkerRangeCopyEndMarker(wr as! AXTextMarkerRange)
 var tests:[[String:Any]]=[]
 let receivers=[e]+anc.reversed().filter{(q($0,"AXRole") as? String)=="AXTextArea" || (q($0,"AXRole") as? String)=="AXWebArea"}.prefix(2)
 for (ri,receiver) in receivers.enumerated() {
 func record(_ method:String,_ range:CFTypeRef?) {
 guard let range else {tests.append(["receiver":ri,"method":method,"unavailable":true]);return}
 var entry:[String:Any]=["receiver":ri,"method":method,"text":q(receiver,"AXStringForTextMarkerRange",range) as? String ?? "<unavailable>","length":q(receiver,"AXLengthForTextMarkerRange",range) as? NSNumber ?? -1,"box":bounds(receiver,range)]
 if CFGetTypeID(range)==AXTextMarkerRangeGetTypeID(){
 let a=AXTextMarkerRangeCopyStartMarker(range as! AXTextMarkerRange),b=AXTextMarkerRangeCopyEndMarker(range as! AXTextMarkerRange)
 entry["startDebug"]=q(receiver,"AXTextMarkerDebugDescription",a) as? String ?? "<unavailable>"
 entry["endDebug"]=q(receiver,"AXTextMarkerDebugDescription",b) as? String ?? "<unavailable>"
 for (label,marker) in [("startElement",a),("endElement",b)] {
 if let owner=q(receiver,"AXUIElementForTextMarker",marker),CFGetTypeID(owner)==AXUIElementGetTypeID(){let el=owner as! AXUIElement;entry[label]=["role":q(el,"AXRole") as? String ?? "","value":q(el,"AXValue") as? String ?? ""]}
 }
 }
 tests.append(entry)
 }
 record("node.whole",wr)
 if let visible=q(receiver,"AXVisibleCharacterRange"),CFGetTypeID(visible)==AXValueGetTypeID(){
 var range=CFRange();if AXValueGetValue(visible as! AXValue,.cfRange,&range){
 var entry:[String:Any]=["receiver":ri,"method":"node.visibleCharacterRange","location":range.location,"length":range.length,"text":q(receiver,"AXStringForRange",visible) as? String ?? "<unavailable>"]
 if let bv=q(receiver,"AXBoundsForRange",visible),CFGetTypeID(bv)==AXValueGetTypeID(){var b=CGRect.zero;if AXValueGetValue(bv as! AXValue,.cgRect,&b){entry["box"]=["x":b.minX,"y":b.minY,"width":b.width,"height":b.height]}}
 tests.append(entry)
 }
 }
 if let nextEnd=q(receiver,"AXNextLineEndTextMarkerForTextMarker",start),CFGetTypeID(nextEnd)==AXTextMarkerGetTypeID(){record("node.start+nextEnd",AXTextMarkerRangeCreate(nil,start,nextEnd as! AXTextMarker))}
 var fullRange=CFRange(location:0,length:(text as NSString).length)
 if let value=AXValueCreate(.cfRange,&fullRange),let rawBounds=q(receiver,"AXBoundsForRange",value),CFGetTypeID(rawBounds)==AXValueGetTypeID(){
 var rect=CGRect.zero;if AXValueGetValue(rawBounds as! AXValue,.cgRect,&rect){tests.append(["receiver":ri,"method":"node.fullBoundsForRange","text":text,"box":["x":rect.minX,"y":rect.minY,"width":rect.width,"height":rect.height]])}
 }
 if let insideEnd=q(receiver,"AXPreviousTextMarkerForTextMarker",finish),CFGetTypeID(insideEnd)==AXTextMarkerGetTypeID() {
 record("endInterior.lineRange",q(receiver,"AXLineTextMarkerRangeForTextMarker",insideEnd))
 if let a=q(receiver,"AXPreviousLineStartTextMarkerForTextMarker",insideEnd),let b=q(receiver,"AXNextLineEndTextMarkerForTextMarker",insideEnd),CFGetTypeID(a)==AXTextMarkerGetTypeID(),CFGetTypeID(b)==AXTextMarkerGetTypeID(){record("endInterior.previousStart+nextEnd",AXTextMarkerRangeCreate(nil,a as! AXTextMarker,b as! AXTextMarker))}
 }
 if let raw=q(receiver,"AXLineTextMarkerRangeForTextMarker",start),CFGetTypeID(raw)==AXTextMarkerRangeGetTypeID() {
 let a=AXTextMarkerRangeCopyStartMarker(raw as! AXTextMarkerRange),b=AXTextMarkerRangeCopyEndMarker(raw as! AXTextMarkerRange)
 if let beforeEnd=q(receiver,"AXPreviousTextMarkerForTextMarker",b),let newEnd=q(receiver,"AXNextLineEndTextMarkerForTextMarker",beforeEnd),CFGetTypeID(newEnd)==AXTextMarkerGetTypeID(){record("lineRange.endFromInterior",AXTextMarkerRangeCreate(nil,a,newEnd as! AXTextMarker))}
 if let afterStart=q(receiver,"AXNextTextMarkerForTextMarker",a),let newStart=q(receiver,"AXPreviousLineStartTextMarkerForTextMarker",afterStart),CFGetTypeID(newStart)==AXTextMarkerGetTypeID(){record("lineRange.startFromInterior",AXTextMarkerRangeCreate(nil,newStart as! AXTextMarker,b))}
 // Rebase internal inline-box endpoints onto exposed static-text markers.
 func alternatives(_ marker:AXTextMarker)->[AXTextMarker] {
 var choices=[marker]
 guard let owner=q(receiver,"AXUIElementForTextMarker",marker),CFGetTypeID(owner)==AXUIElementGetTypeID() else{return choices}
 var node=owner as! AXUIElement
 for _ in 0..<4 {
 if q(node,"AXRole") as? String == "AXStaticText",let value=q(node,"AXValue") as? String,!value.isEmpty {
 if let whole=q(node,"AXTextMarkerRangeForUIElement",node),CFGetTypeID(whole)==AXTextMarkerRangeGetTypeID(){choices.append(AXTextMarkerRangeCopyStartMarker(whole as! AXTextMarkerRange));choices.append(AXTextMarkerRangeCopyEndMarker(whole as! AXTextMarkerRange))}
 for i in 0..<8 {if let local=q(node,"AXTextMarkerRangeForLine",NSNumber(value:i)),CFGetTypeID(local)==AXTextMarkerRangeGetTypeID(){choices.append(AXTextMarkerRangeCopyStartMarker(local as! AXTextMarkerRange));choices.append(AXTextMarkerRangeCopyEndMarker(local as! AXTextMarkerRange))}}
 break
 }
 guard let parent=q(node,"AXParent"),CFGetTypeID(parent)==AXUIElementGetTypeID() else{break};node=parent as! AXUIElement
 }
 return choices
 }
 let expected=q(receiver,"AXStringForTextMarkerRange",raw) as? String
 var matched=0
 for aa in alternatives(a) {for bb in alternatives(b) {
 let trial=AXTextMarkerRangeCreate(nil,aa,bb)
 if q(receiver,"AXStringForTextMarkerRange",trial) as? String == expected {
 record("lineRange.rebased.\(matched)",trial);matched+=1
 }
 }}
 // Equivalent-position round trips test endpoint anchoring; no geometry merge.
 if let an=q(receiver,"AXNextTextMarkerForTextMarker",a),let ac=q(receiver,"AXPreviousTextMarkerForTextMarker",an),let bp=q(receiver,"AXPreviousTextMarkerForTextMarker",b),let bc=q(receiver,"AXNextTextMarkerForTextMarker",bp),CFGetTypeID(ac)==AXTextMarkerGetTypeID(),CFGetTypeID(bc)==AXTextMarkerGetTypeID(){record("lineRange.canonicalEndpoints",AXTextMarkerRangeCreate(nil,ac as! AXTextMarker,bc as! AXTextMarker))}
 }
 var point=CGPoint(x:pt.x+min(2,sz.width/2),y:pt.y+sz.height/2)
 if let pv=AXValueCreate(.cgPoint,&point),let at=q(receiver,"AXTextMarkerForPosition",pv) {record("position.lineRange",q(receiver,"AXLineTextMarkerRangeForTextMarker",at))}
 var rect=CGRect(origin:pt,size:sz)
 if let rv=AXValueCreate(.cgRect,&rect) {
 for key in ["AXStartTextMarkerForBounds","AXEndTextMarkerForBounds"] {
 if let marker=q(receiver,key,rv){record(key+".lineRange",q(receiver,"AXLineTextMarkerRangeForTextMarker",marker))}
 }
 }
 for lineIndex in 0..<4 {
 let number=NSNumber(value:lineIndex)
 record("numeric.textMarkerRangeForLine.\(lineIndex)",q(receiver,"AXTextMarkerRangeForLine",number))
 if let range=q(receiver,"AXRangeForLine",number),CFGetTypeID(range)==AXValueGetTypeID() {
 var cr=CFRange();if AXValueGetValue(range as! AXValue,.cfRange,&cr) {
 var entry:[String:Any]=["receiver":ri,"method":"numeric.rangeForLine.\(lineIndex)","location":cr.location,"length":cr.length]
 entry["text"]=q(receiver,"AXStringForRange",range) as? String ?? "<unavailable>"
 if let bv=q(receiver,"AXBoundsForRange",range),CFGetTypeID(bv)==AXValueGetTypeID(){var br=CGRect.zero;if AXValueGetValue(bv as! AXValue,.cgRect,&br){entry["box"]=["x":br.minX,"y":br.minY,"width":br.width,"height":br.height]}}
 tests.append(entry)
 }
 }
 }
 for key in ["AXLineTextMarkerRangeForTextMarker","AXLeftLineTextMarkerRangeForTextMarker","AXRightLineTextMarkerRangeForTextMarker"] {record(key,q(receiver,key,start))}
 // Probe an interior marker too: an exact node start may be treated as
 // a boundary even when it lies in the middle of the rendered line.
 if let inside=q(receiver,"AXNextTextMarkerForTextMarker",start),CFGetTypeID(inside)==AXTextMarkerGetTypeID() {
 record("interior.lineRange",q(receiver,"AXLineTextMarkerRangeForTextMarker",inside))
 if let a=q(receiver,"AXPreviousLineStartTextMarkerForTextMarker",inside),let b=q(receiver,"AXNextLineEndTextMarkerForTextMarker",inside),CFGetTypeID(a)==AXTextMarkerGetTypeID(),CFGetTypeID(b)==AXTextMarkerGetTypeID(){record("interior.previousStart+nextEnd",AXTextMarkerRangeCreate(nil,a as! AXTextMarker,b as! AXTextMarker))}
 }
 if let a=q(receiver,"AXPreviousLineStartTextMarkerForTextMarker",start),let b=q(receiver,"AXNextLineEndTextMarkerForTextMarker",start),CFGetTypeID(a)==AXTextMarkerGetTypeID(),CFGetTypeID(b)==AXTextMarkerGetTypeID(){record("previousStart+nextEnd",AXTextMarkerRangeCreate(nil,a as! AXTextMarker,b as! AXTextMarker))}
 }
 results.append(["text":text,"frame":["x":pt.x,"y":pt.y,"width":sz.width,"height":sz.height],"tests":tests])
 }
 }
 for child in q(e,"AXChildren") as? [AXUIElement] ?? [] {stack.append((child,anc+[e]))}
 }
 try JSONSerialization.data(withJSONObject:["nodes":count,"truncated": !stack.isEmpty,"queryErrors":queryErrors,"results":results],options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
}
do{try run()}catch{fputs("\(error)\n",stderr);exit(1)}
