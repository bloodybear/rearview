// Compare identical live AX handles. Shared discovery/activation/report I/O is outside timing.
// Old algorithm is trace-free; new algorithm resolves only requested leaf endpoints.
import AppKit
import ApplicationServices
struct Leaf {let id:Int;let node:AXUIElement;let text:String;let base:Int;var length:Int{(text as NSString).length}}
struct Unit {let id:Int;let node:AXUIElement;let role:String;let text:String;let leaves:[Leaf]}
struct Line {let start:Int;let length:Int;let text:String;let box:CGRect}
struct Output {var lines:[Line]=[];var status="complete"}
final class Queries {
 var calls=0
 func get(_ e:AXUIElement,_ k:String,_ input:CFTypeRef?=nil)->CFTypeRef? {
 calls+=1;var value:CFTypeRef?
 let err=input.map{AXUIElementCopyParameterizedAttributeValue(e,k as CFString,$0,&value)} ?? AXUIElementCopyAttributeValue(e,k as CFString,&value)
 return err == .success ? value:nil
 }
 func whole(_ e:AXUIElement)->AXTextMarkerRange?{guard let r=get(e,"AXTextMarkerRangeForUIElement",e),CFGetTypeID(r)==AXTextMarkerRangeGetTypeID() else{return nil};return (r as! AXTextMarkerRange)}
 func end(_ e:AXUIElement,_ start:AXTextMarker)->AXTextMarker?{guard let v=get(e,"AXNextLineEndTextMarkerForTextMarker",start),CFGetTypeID(v)==AXTextMarkerGetTypeID() else{return nil};return (v as! AXTextMarker)}
 func string(_ e:AXUIElement,_ r:AXTextMarkerRange)->String?{get(e,"AXStringForTextMarkerRange",r) as? String}
 func box(_ e:AXUIElement,_ r:AXTextMarkerRange)->CGRect? {
 guard let v=get(e,"AXBoundsForTextMarkerRange",r),CFGetTypeID(v)==AXValueGetTypeID() else{return nil};var b=CGRect.zero
 guard AXValueGetValue(v as! AXValue,.cgRect,&b),b.minX.isFinite,b.minY.isFinite,b.width.isFinite,b.height.isFinite,b.width>0,b.height>0 else{return nil};return b
 }
}
func slice(_ text:String,_ start:Int,_ length:Int)->String? {
 let utf=Array(text.utf16);guard start>=0,length>0,start+length<=utf.count else{return nil}
 for i in [start,start+length] {if i>0 && i<utf.count && (0xD800...0xDBFF).contains(utf[i-1]) && (0xDC00...0xDFFF).contains(utf[i]){return nil}}
 return (text as NSString).substring(with:NSRange(location:start,length:length))
}
func oldLeaf(_ leaf:Leaf,_ q:Queries)->Output {
 var out=Output();guard let whole=q.whole(leaf.node) else{out.status="marker_range_unavailable";return out}
 var marker=AXTextMarkerRangeCopyStartMarker(whole),offset=0
 for _ in 0..<128 where offset<leaf.length {
 guard let end=q.end(leaf.node,marker) else{out.status="marker_line_end_unavailable";break}
 let r=AXTextMarkerRangeCreate(nil,marker,end)
 guard let text=q.string(leaf.node,r),!text.isEmpty else{out.status="marker_empty_or_stalled_range";break}
 let count=(text as NSString).length
 guard slice(leaf.text,offset,count)==text else{out.status="marker_string_mismatch";break}
 guard let box=q.box(leaf.node,r) else{out.status="marker_empty_bounds";break}
 out.lines.append(Line(start:leaf.base+offset,length:count,text:text,box:box));offset+=count;marker=end
 }
 if offset<leaf.length && out.status=="complete"{out.status="line_limit"};return out
}
func old(_ u:Unit,_ q:Queries)->Output {
 var out=Output()
 for leaf in u.leaves {let part=oldLeaf(leaf,q);out.lines+=part.lines;if part.status != "complete"{out.status=part.status}}
 return out
}
func native(_ u:Unit,_ q:Queries)->Output {
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
 if u.role != "AXTextArea" && u.leaves.count>1 {
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
 var marker=AXTextMarkerRangeCopyStartMarker(whole),offset=0
 for _ in 0..<128 where offset<total {
 guard let end=q.end(u.node,marker),let text=q.string(u.node,AXTextMarkerRangeCreate(nil,marker,end)),!text.isEmpty else{out.status="marker_empty_or_stalled_range";break}
 let count=(text as NSString).length
 guard slice(source,offset,count)==text else{out.status="marker_string_mismatch";break}
 if !append(offset,text){break};offset+=count;marker=end
 }
 if offset<total && out.status=="complete"{out.status="line_limit"};return out
}
func dictionary(_ out:Output)->[String:Any] { ["status":out.status,"lines":out.lines.map{["start":$0.start,"length":$0.length,"text":$0.text,"box":["x":$0.box.minX,"y":$0.box.minY,"width":$0.box.width,"height":$0.box.height]]}] }
func rect(_ e:AXUIElement,_ q:Queries)->[String:Double]? {
 guard let p=q.get(e,"AXPosition"),let s=q.get(e,"AXSize"),CFGetTypeID(p)==AXValueGetTypeID(),CFGetTypeID(s)==AXValueGetTypeID() else{return nil}
 var pt=CGPoint.zero,sz=CGSize.zero;guard AXValueGetValue(p as! AXValue,.cgPoint,&pt),AXValueGetValue(s as! AXValue,.cgSize,&sz) else{return nil};return ["x":pt.x,"y":pt.y,"width":sz.width,"height":sz.height]
}
func run() throws {
 guard CommandLine.arguments.count==3,AXIsProcessTrusted(),let process=NSRunningApplication.runningApplications(withBundleIdentifier:"notion.id").first else{throw NSError(domain:"benchmark REPORT_FOLDER OUTPUT.json requires Notion/AX",code:1)}
 let folder=URL(fileURLWithPath:CommandLine.arguments[1]),output=URL(fileURLWithPath:CommandLine.arguments[2])
 let paragraphs=(try JSONSerialization.jsonObject(with:Data(contentsOf:folder.appendingPathComponent("paragraphs.json"))) as! [String:Any])["units"] as! [[String:Any]]
 let raw=try JSONSerialization.jsonObject(with:Data(contentsOf:folder.appendingPathComponent("rawAx.json"))) as! [[String:Any]]
 let frames=Dictionary(uniqueKeysWithValues:raw.map{($0["id"] as! Int,$0["frame"] as? [String:Double] ?? [:])})
 let app=AXUIElementCreateApplication(process.processIdentifier),discovery=Queries();AXUIElementSetMessagingTimeout(app,0.35)
 let previous=discovery.get(app,"AXManualAccessibility");defer{if let previous{AXUIElementSetAttributeValue(app,"AXManualAccessibility" as CFString,previous)}}
 AXUIElementSetAttributeValue(app,"AXManualAccessibility" as CFString,kCFBooleanTrue);Thread.sleep(forTimeInterval:2.5)
 var nodes:[AXUIElement]=[],children:[[Int]]=[],roles:[String]=[],values:[String]=[],titles:[String]=[]
 func visit(_ e:AXUIElement)->Int {
 let id=nodes.count;nodes.append(e);children.append([]);roles.append(discovery.get(e,"AXRole") as? String ?? "");values.append(discovery.get(e,"AXValue") as? String ?? "");titles.append(discovery.get(e,"AXTitle") as? String ?? "")
 if nodes.count<3500 {for c in discovery.get(e,"AXChildren") as? [AXUIElement] ?? [] {let child=visit(c);children[id].append(child)}};return id
 }
 _=visit(app)
 var units:[Unit]=[],skipped:[[String:Any]]=[],seenParagraphs:Set<Int>=[]
 for id in nodes.indices where ["AXTextArea","AXRadioButton","AXButton","AXPopUpButton"].contains(roles[id]) {
 let text=values[id].isEmpty ? titles[id]:values[id]
 guard !text.isEmpty,let frame=rect(nodes[id],discovery),let match=paragraphs.first(where:{$0["text"] as? String == text && frames[$0["node"] as! Int]==frame}) else{continue}
 let reportID=match["node"] as! Int
 guard !seenParagraphs.contains(reportID) else{continue}
 var leafIDs:[Int]=[]
 func leaves(_ i:Int){if roles[i]=="AXStaticText"{leafIDs.append(i);return};for c in children[i]{leaves(c)}}
 for c in children[id]{leaves(c)}
 var base=0,ls:[Leaf]=[]
 for i in leafIDs where !values[i].isEmpty {ls.append(Leaf(id:i,node:nodes[i],text:values[i],base:base));base+=(values[i] as NSString).length}
 guard !ls.isEmpty else{skipped.append(["paragraph":match["node"]!,"text":text,"reason":"no_static_text_descendants"]);continue}
 seenParagraphs.insert(reportID)
 units.append(Unit(id:reportID,node:nodes[id],role:roles[id],text:text,leaves:ls))
 }
 guard !units.isEmpty else{throw NSError(domain:"No live units match report source/frame",code:1)}
 let focusedBefore=discovery.get(app,"AXFocusedWindow")
 var records:[[String:Any]]=[],first:[String:Data]=[:],outcomes:[[String:Any]]=[]
 let methods=["old","native","native-single-fastpath"]
 for round in -3..<18 {
 let order=round%2==0 ? methods:Array(methods.reversed())
 for method in order {
 for u in (round%3==0 ? Array(units.reversed()):units) {
 let q=Queries(),start=DispatchTime.now().uptimeNanoseconds
 let result:Output
 if method=="old" || (method=="native-single-fastpath" && u.leaves.count==1){result=old(u,q)}else{result=native(u,q)}
 let ns=DispatchTime.now().uptimeNanoseconds-start
 if round>=0 {
 let key="\(method):\(u.id)",data=try JSONSerialization.data(withJSONObject:dictionary(result),options:.sortedKeys)
 let stable=first[key].map{$0==data} ?? true
 if first[key]==nil{first[key]=data;outcomes.append(["method":method,"paragraph":u.id,"text":u.text,"leafCount":u.leaves.count,"result":dictionary(result)])}
 records.append(["round":round,"method":method,"paragraph":u.id,"leafCount":u.leaves.count,"ns":ns,"calls":q.calls,"stable":stable,"status":result.status,"lineCount":result.lines.count])
 }
 }
 }
 }
 // Reject a changed document/window/source instead of treating noisy state as a timing result.
 var valid=true
 if let focusedBefore,let after=discovery.get(app,"AXFocusedWindow"){valid=CFEqual(focusedBefore,after)}else{valid=false}
 for u in units {let now=discovery.get(u.node,u.role=="AXTextArea" ? "AXValue":"AXTitle") as? String;valid = valid && now==u.text && rect(u.node,discovery)==frames[u.id]}
 valid = valid && records.allSatisfy{$0["stable"] as? Bool == true}
 let document:[String:Any]=["validLiveState":valid,"rounds":18,"warmups":3,"clock":"DispatchTime.uptimeNanoseconds","scope":"line extraction only; shared discovery/activation excluded; per-invocation marker caches empty; trace formatting disabled for all methods","sharedDiscoveryCalls":discovery.calls,"skipped":skipped,"outcomes":outcomes,"samples":records]
 try JSONSerialization.data(withJSONObject:document,options:[.prettyPrinted,.sortedKeys]).write(to:output)
 if !valid{throw NSError(domain:"Live state changed; benchmark invalid",code:1)}
}
do{try run()}catch{fputs("\(error)\n",stderr);exit(1)}
