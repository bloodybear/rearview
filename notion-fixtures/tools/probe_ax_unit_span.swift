import AppKit
import ApplicationServices
func rect(_ b:CGRect)->[String:Double]{["x":b.minX,"y":b.minY,"width":b.width,"height":b.height]}
func read(_ e:AXUIElement,_ k:String)->CFTypeRef?{var v:CFTypeRef?;return AXUIElementCopyAttributeValue(e,k as CFString,&v) == .success ? v:nil}
func frame(_ e:AXUIElement)->CGRect?{guard let p=read(e,"AXPosition"),let s=read(e,"AXSize") else{return nil};var pt=CGPoint.zero,sz=CGSize.zero;guard AXValueGetValue(p as! AXValue,.cgPoint,&pt),AXValueGetValue(s as! AXValue,.cgSize,&sz) else{return nil};return CGRect(origin:pt,size:sz)}
func rowFrame(_ r:[String:Any])->CGRect?{guard let f=r["frame"] as? [String:Double] else{return nil};return CGRect(x:f["x"]!,y:f["y"]!,width:f["width"]!,height:f["height"]!)}
func encode(_ o:DirectionalLinesResearch.Output)->[String:Any]{["status":o.status,"covered":o.lines.reduce(0){$0+$1.length},"lines":o.lines.map{["start":$0.start,"length":$0.length,"text":$0.text,"box":rect($0.box)]}]}
@main struct Probe {
static func main() throws {
 let folder=URL(fileURLWithPath:CommandLine.arguments[1]);func json(_ n:String)throws->Any{try JSONSerialization.jsonObject(with:Data(contentsOf:folder.appendingPathComponent(n)))}
 let raw=try json("rawAx.json") as! [[String:Any]],units=(try json("paragraphs.json") as! [String:Any])["units"] as! [[String:Any]]
 guard AXIsProcessTrusted(),let process=NSRunningApplication.runningApplications(withBundleIdentifier:"notion.id").first else{throw NSError(domain:"Notion/AX unavailable",code:1)}
 let app=AXUIElementCreateApplication(process.processIdentifier);AXUIElementSetMessagingTimeout(app,0.35);AXUIElementSetAttributeValue(app,"AXManualAccessibility" as CFString,kCFBooleanTrue);Thread.sleep(forTimeInterval:2.5)
 guard let root=read(app,"AXFocusedWindow") else{throw NSError(domain:"No window",code:1)}
 let deadline=Date().addingTimeInterval(90);var stack=[root as! AXUIElement],seen=Set<AXUIElement>(),handles:[Int:AXUIElement]=[:]
 while let e=stack.popLast(),seen.count<4000,Date()<deadline {
 guard seen.insert(e).inserted else{continue};stack.append(contentsOf:(read(e,"AXChildren") as? [AXUIElement] ?? []).reversed())
 let role=read(e,"AXRole") as? String ?? "",value=read(e,"AXValue") as? String ?? "",title=read(e,"AXTitle") as? String ?? ""
 guard let f=frame(e),let row=raw.first(where:{r in guard r["controlTextOwner"]==nil,r["role"] as? String==role,(r["value"] as? String ?? "")==value,(r["title"] as? String ?? "")==title,let b=rowFrame(r) else{return false};return abs(f.minX-b.minX)<0.5 && abs(f.minY-b.minY)<0.5 && abs(f.width-b.width)<0.5 && abs(f.height-b.height)<0.5}) else{continue};handles[row["id"] as! Int]=e
 }
 let resolver=ControlTextResolver();var ownerCache:[Int:ControlTextResolver.Result]=[:]
 for r in raw where r["controlTextOwner"] != nil {
 let id=r["id"] as! Int,owner=r["controlTextOwner"] as! Int;guard let element=handles[owner] else{continue}
 if ownerCache[owner]==nil {
 var classes:[String]=[],p:Int?=owner;while let i=p{classes+=raw[i]["domClasses"] as? [String] ?? [];p=raw[i]["parent"] as? Int}
 let neighbors=raw.indices.filter{i in i != owner && handles[i] != nil && ["AXButton","AXRadioButton","AXPopUpButton"].contains(raw[i]["role"] as? String ?? "") && rowFrame(raw[owner]).flatMap{a in rowFrame(raw[i]).map{a.contains($0)}} == true}.compactMap{handles[$0]}
 ownerCache[owner]=resolver.resolve(element,header:classes.contains("notion-table-view-header-row"),internalText:r["textDiscovery"] as? String == "internal_child_text",neighbors:neighbors,deadline:deadline)
 }
 if let t=ownerCache[owner]?.texts.first(where:{t in t.source==(r["recoveredText"] as? String ?? r["value"] as? String ?? "") && rowFrame(r).map{abs($0.minX-t.frame.minX)<0.5 && abs($0.minY-t.frame.minY)<0.5} == true}){handles[id]=t.element}
 }
 var results:[[String:Any]]=[];let viewport=CGRect(x:-100000,y:-100000,width:200000,height:200000)
 for unit in units {
 let id=unit["node"] as! Int,ids=(raw[id]["paragraphLineInvestigation"] as? [String:Any])?["sourceNodes"] as? [Int] ?? []
 guard !ids.isEmpty,ids.allSatisfy({handles[$0] != nil}),let element=handles[id] else{results.append(["node":id,"status":"unmatched_live_handles","sourceNodes":ids]);continue}
 var base=0;let leaves=ids.map{i -> DirectionalLinesResearch.Leaf in let text=(raw[i]["recoveredText"] ?? raw[i]["value"]) as! String;defer{base+=text.utf16.count};return .init(id:i,node:handles[i]!,text:text,base:base)}
 let input=DirectionalLinesResearch.Unit(id:id,node:element,role:raw[id]["role"] as! String,text:leaves.map{$0.text}.joined(),leaves:leaves)
 let access=AXTextAccess();var probes:[[String:Any]]=[]
 func inspect(_ label:String,_ range:AXTextMarkerRange){
 let string=access.param(element,"AXStringForTextMarkerRange",range) as? String
 probes.append(["label":label,"text":string as Any? ?? NSNull(),"matchesLeaves":string==input.text,"box":access.asRect(access.param(element,"AXBoundsForTextMarkerRange",range)).map(rect) as Any? ?? NSNull()])
 }
 if let range=access.param(element,"AXTextMarkerRangeForUIElement",element),CFGetTypeID(range)==AXTextMarkerRangeGetTypeID(){inspect("unit-whole",range as! AXTextMarkerRange)}
 var ranges:[AXTextMarkerRange]=[]
 for leaf in leaves {
 if let range=access.param(leaf.node,"AXTextMarkerRangeForUIElement",leaf.node),CFGetTypeID(range)==AXTextMarkerRangeGetTypeID(){let r=range as! AXTextMarkerRange;ranges.append(r);inspect("leaf-\(leaf.id)",r)}
 }
 if ranges.count==leaves.count,let first=ranges.first,let last=ranges.last {
 let a=AXTextMarkerRangeCopyStartMarker(first),end=AXTextMarkerRangeCopyEndMarker(last),span=AXTextMarkerRangeCreate(nil,a,end);inspect("leaf-span",span)
 if let start=access.param(element,"AXPreviousLineStartTextMarkerForTextMarker",end),CFGetTypeID(start)==AXTextMarkerGetTypeID(){inspect("reverse-from-last-leaf",AXTextMarkerRangeCreate(nil,start as! AXTextMarker,end))}
 }
 results.append(["node":id,"text":input.text,"sourceNodes":ids,"probes":probes])

 }
 let output:[String:Any]=["units":results,"unitCount":units.count,"timedOut":Date()>deadline,"repetitions":7,"timing":"alternate order; first sample excluded; upper median of remaining six","resolverCallsOutsideBenchmark":resolver.queryCount]
 try JSONSerialization.data(withJSONObject:output,options:[.prettyPrinted,.sortedKeys]).write(to:folder.appendingPathComponent("unit-span-study.json"));print("Compared \(results.count) units; timeout=\(Date()>deadline)")
}
}
