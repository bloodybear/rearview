// Research: native paragraph line boundaries + leaf-anchored range bounds.
// No rectangle union, y-coordinate grouping, marker byte decoding or text rewriting.
import AppKit
import ApplicationServices
var calls=0
var queryErrors:[String:[String:Int]]=[:]
func q(_ e:AXUIElement,_ k:String,_ input:CFTypeRef?=nil)->CFTypeRef? {
 calls+=1;var v:CFTypeRef?;let err=input.map{AXUIElementCopyParameterizedAttributeValue(e,k as CFString,$0,&v)} ?? AXUIElementCopyAttributeValue(e,k as CFString,&v)
 queryErrors[k,default:[:]][String(err.rawValue),default:0] += 1
 return err == .success ? v:nil
}
func whole(_ e:AXUIElement)->AXTextMarkerRange? {
 guard let v=q(e,"AXTextMarkerRangeForUIElement",e),CFGetTypeID(v)==AXTextMarkerRangeGetTypeID() else{return nil};return (v as! AXTextMarkerRange)
}
func rect(_ e:AXUIElement)->CGRect? {
 guard let p=q(e,"AXPosition"),let s=q(e,"AXSize"),CFGetTypeID(p)==AXValueGetTypeID(),CFGetTypeID(s)==AXValueGetTypeID() else{return nil}
 var pt=CGPoint.zero,sz=CGSize.zero;guard AXValueGetValue(p as! AXValue,.cgPoint,&pt),AXValueGetValue(s as! AXValue,.cgSize,&sz) else{return nil};return CGRect(origin:pt,size:sz)
}
func box(_ e:AXUIElement,_ r:AXTextMarkerRange)->CGRect? {
 guard let v=q(e,"AXBoundsForTextMarkerRange",r),CFGetTypeID(v)==AXValueGetTypeID() else{return nil};var b=CGRect.zero
 return AXValueGetValue(v as! AXValue,.cgRect,&b) ? b:nil
}
func dict(_ b:CGRect)->[String:Double]{["x":b.minX,"y":b.minY,"width":b.width,"height":b.height]}
struct Endpoint {let marker:AXTextMarker;let source:Int;let kind:String}
func run() throws {
 guard CommandLine.arguments.count==2,AXIsProcessTrusted(),let p=NSRunningApplication.runningApplications(withBundleIdentifier:"notion.id").first else{throw NSError(domain:"Notion/AX required",code:1)}
 let app=AXUIElementCreateApplication(p.processIdentifier);AXUIElementSetMessagingTimeout(app,0.35)
 let prior=q(app,"AXManualAccessibility");defer{if let prior{AXUIElementSetAttributeValue(app,"AXManualAccessibility" as CFString,prior)}}
 AXUIElementSetAttributeValue(app,"AXManualAccessibility" as CFString,kCFBooleanTrue);Thread.sleep(forTimeInterval:2.5)
 var nodes:[AXUIElement]=[],children:[[Int]]=[],roles:[String]=[],values:[String]=[]
 func visit(_ e:AXUIElement)->Int {
 let id=nodes.count;nodes.append(e);children.append([]);roles.append(q(e,"AXRole") as? String ?? "");let value=q(e,"AXValue") as? String ?? "";values.append(value.isEmpty ? (q(e,"AXTitle") as? String ?? "") : value)
 if nodes.count<3500 {for c in q(e,"AXChildren") as? [AXUIElement] ?? [] {let child=visit(c);children[id].append(child)}};return id
 }
 _=visit(app)
 var results:[[String:Any]]=[]
 for id in nodes.indices where ["AXTextArea","AXButton","AXPopUpButton","AXRadioButton"].contains(roles[id]) && !values[id].isEmpty {
 guard let frame=rect(nodes[id]),frame.height>1,frame.minY<760,frame.maxY>140,let native=whole(nodes[id]) else{continue}
 let nativeText=q(nodes[id],"AXStringForTextMarkerRange",native) as? String ?? ""
 var leafIDs:[Int]=[]
 func leaves(_ n:Int){if roles[n]=="AXStaticText" {leafIDs.append(n);return};for c in children[n]{leaves(c)}}
 for c in children[id]{leaves(c)}
 let joined=leafIDs.map{values[$0]}.joined()
 var result:[String:Any]=["node":id,"role":roles[id],"text":values[id],"nativeText":nativeText,"frame":dict(frame),"leaves":leafIDs.map{["node":$0,"text":values[$0]]},"leafTextMatches":joined==nativeText]
 guard !nativeText.isEmpty,joined==nativeText else{result["status"]="native_leaf_text_mismatch";results.append(result);continue}
 var starts:[Int:Endpoint]=[:],ends:[Int:Endpoint]=[:],base=0
 for leaf in leafIDs {
 guard let wr=whole(nodes[leaf]) else{continue}
 let start=AXTextMarkerRangeCopyStartMarker(wr),end=AXTextMarkerRangeCopyEndMarker(wr),text=values[leaf],length=(text as NSString).length
 starts[base]=Endpoint(marker:start,source:leaf,kind:"node_start")
 ends[base+length]=Endpoint(marker:end,source:leaf,kind:"node_end")
 for line in 0..<128 {
 guard let raw=q(nodes[leaf],"AXTextMarkerRangeForLine",NSNumber(value:line)),CFGetTypeID(raw)==AXTextMarkerRangeGetTypeID() else{break}
 let lr=raw as! AXTextMarkerRange
 for (m,isStart) in [(AXTextMarkerRangeCopyStartMarker(lr),true),(AXTextMarkerRangeCopyEndMarker(lr),false)] {
 let prefixRange=AXTextMarkerRangeCreate(nil,start,m)
 guard let prefix=q(nodes[leaf],"AXStringForTextMarkerRange",prefixRange) as? String,text.hasPrefix(prefix) else{continue}
 let offset=base+(prefix as NSString).length,ep=Endpoint(marker:m,source:leaf,kind:"node_line_boundary")
 if isStart {if starts[offset]==nil{starts[offset]=ep}} else {if ends[offset]==nil{ends[offset]=ep}}
 // An AX line-end marker is also a logical boundary for the following line.
 if starts[offset]==nil{starts[offset]=ep};if ends[offset]==nil{ends[offset]=ep}
 }
 }
 var localStart=start,localOffset=0
 for _ in 0..<128 where localOffset<length {
 guard let rawEnd=q(nodes[leaf],"AXNextLineEndTextMarkerForTextMarker",localStart),CFGetTypeID(rawEnd)==AXTextMarkerGetTypeID() else{break}
 let localEnd=rawEnd as! AXTextMarker
 let localRange=AXTextMarkerRangeCreate(nil,localStart,localEnd)
 guard let fragment=q(nodes[leaf],"AXStringForTextMarkerRange",localRange) as? String,!fragment.isEmpty else{break}
 let count=(fragment as NSString).length
 guard localOffset+count<=length,(text as NSString).substring(with:NSRange(location:localOffset,length:count))==fragment else{break}
 localOffset+=count
 let ep=Endpoint(marker:localEnd,source:leaf,kind:"node_next_line_end")
 if starts[base+localOffset]==nil{starts[base+localOffset]=ep};if ends[base+localOffset]==nil{ends[base+localOffset]=ep}
 localStart=localEnd
 }
 base+=length
 }
 // A native previous-start/next-end query can cross the icon/label split
 // even when NextLineEnd from the control itself treats them as separate lines.
 // Only report a whole-line candidate if AX itself returns the complete unit.
 var fullProof:[[String:Any]]=[]
 for leaf in leafIDs where fullProof.isEmpty {
 guard let wr=whole(nodes[leaf]) else{continue}
 let seed=AXTextMarkerRangeCopyStartMarker(wr)
 var seeds=[seed]
 if let next=q(nodes[leaf],"AXNextTextMarkerForTextMarker",seed),CFGetTypeID(next)==AXTextMarkerGetTypeID(){seeds.append(next as! AXTextMarker)}
 for marker in seeds where fullProof.isEmpty {
 guard let a=q(nodes[id],"AXPreviousLineStartTextMarkerForTextMarker",marker),let b=q(nodes[id],"AXNextLineEndTextMarkerForTextMarker",marker),CFGetTypeID(a)==AXTextMarkerGetTypeID(),CFGetTypeID(b)==AXTextMarkerGetTypeID() else{continue}
 let range=AXTextMarkerRangeCreate(nil,a as! AXTextMarker,b as! AXTextMarker)
 guard q(nodes[id],"AXStringForTextMarkerRange",range) as? String == nativeText,
 let start=starts[0],let end=ends[(nativeText as NSString).length] else{continue}
 let rebased=AXTextMarkerRangeCreate(nil,start.marker,end.marker)
 guard q(nodes[id],"AXStringForTextMarkerRange",rebased) as? String == nativeText,let box=box(nodes[id],rebased) else{continue}
 fullProof.append(["text":nativeText,"box":dict(box),"seedNode":leaf,"sourceStart":start.source,"sourceEnd":end.source,"plausibleWithinParagraph":box.width>0 && box.height>0 && frame.insetBy(dx:-2,dy:-12).contains(box)])
 }
 }
 result["wholeUnitNativeLineCandidates"]=fullProof
 let total=(nativeText as NSString).length
 var marker=AXTextMarkerRangeCopyStartMarker(native),offset=0,lines:[[String:Any]]=[]
 for _ in 0..<128 where offset<total {
 guard let end=q(nodes[id],"AXNextLineEndTextMarkerForTextMarker",marker),CFGetTypeID(end)==AXTextMarkerGetTypeID() else{break}
 let range=AXTextMarkerRangeCreate(nil,marker,end as! AXTextMarker)
 guard let text=q(nodes[id],"AXStringForTextMarkerRange",range) as? String,!text.isEmpty else{break}
 let length=(text as NSString).length
 guard offset+length<=total,(nativeText as NSString).substring(with:NSRange(location:offset,length:length))==text else{break}
 var line:[String:Any]=["start":offset,"length":length,"text":text]
 if let b=box(nodes[id],range){line["nativeBox"]=dict(b)}
 if let a=starts[offset],let b=ends[offset+length] {
 let rebased=AXTextMarkerRangeCreate(nil,a.marker,b.marker)
 let verified=q(nodes[id],"AXStringForTextMarkerRange",rebased) as? String == text
 line["sourceStart"]=a.source;line["sourceEnd"]=b.source;line["verifiedString"]=verified
 if verified,let bounds=box(nodes[id],rebased) {
 line["box"]=dict(bounds)
 line["plausibleWithinParagraph"]=bounds.width>0 && bounds.height>0 && frame.insetBy(dx:-2,dy:-12).contains(bounds)
 }
 }else{line["status"]="leaf_endpoint_unavailable"}
 lines.append(line);offset+=length;marker=end as! AXTextMarker
 }
 result["lines"]=lines;result["covered"]=offset;result["total"]=total;result["complete"]=offset==total
 result["allLineBoxesPlausible"]=offset==total && !lines.isEmpty && lines.allSatisfy{$0["plausibleWithinParagraph"] as? Bool == true}
 results.append(result)
 }
 try JSONSerialization.data(withJSONObject:["nodes":nodes.count,"calls":calls,"queryErrors":queryErrors,"results":results],options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
}
do{try run()}catch{fputs("\(error)\n",stderr);exit(1)}
