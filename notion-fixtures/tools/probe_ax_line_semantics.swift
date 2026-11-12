// Research only: compare full-range and first-character vertical geometry.
import AppKit
import ApplicationServices
func rect(_ b:CGRect)->[String:Double]{["x":b.minX,"y":b.minY,"width":b.width,"height":b.height]}
func read(_ e:AXUIElement,_ key:String,_ input:CFTypeRef?=nil)->CFTypeRef?{var v:CFTypeRef?;let err=input.map{AXUIElementCopyParameterizedAttributeValue(e,key as CFString,$0,&v)} ?? AXUIElementCopyAttributeValue(e,key as CFString,&v);return err == .success ? v:nil}
func box(_ v:CFTypeRef?)->CGRect?{guard let v,CFGetTypeID(v)==AXValueGetTypeID() else{return nil};var r=CGRect.zero;guard AXValueGetValue(v as! AXValue,.cgRect,&r),[r.minX,r.minY,r.width,r.height].allSatisfy(\.isFinite),r.width>0,r.height>0 else{return nil};return r}
func bounds(_ e:AXUIElement,_ length:Int)->CGRect?{var r=CFRange(location:0,length:length);return box(read(e,"AXBoundsForRange",AXValueCreate(.cfRange,&r)!))}
func run() throws {
 let folder=URL(fileURLWithPath:CommandLine.arguments[1]);let raw=try JSONSerialization.jsonObject(with:Data(contentsOf:folder.appendingPathComponent("rawAx.json"))) as! [[String:Any]]
 let candidates=try JSONSerialization.jsonObject(with:Data(contentsOf:folder.appendingPathComponent("candidate.json"))) as! [[String:Any]]
 var wanted=Set(candidates.map{$0["node"] as! Int})
 for r in raw {if let p=r["paragraphLineInvestigation"] as? [String:Any]{wanted.formUnion(p["sourceNodes"] as? [Int] ?? [])}}
 guard AXIsProcessTrusted(),let process=NSRunningApplication.runningApplications(withBundleIdentifier:"notion.id").first else{throw NSError(domain:"AX/Notion unavailable",code:1)}
 let app=AXUIElementCreateApplication(process.processIdentifier);AXUIElementSetMessagingTimeout(app,0.35)
 AXUIElementSetAttributeValue(app,"AXManualAccessibility" as CFString,kCFBooleanTrue);Thread.sleep(forTimeInterval:2.5)
 guard let root=read(app,"AXFocusedWindow") else{throw NSError(domain:"No window",code:1)}
 var stack=[root as! AXUIElement],seen=Set<AXUIElement>(),found:Set<Int>=[],rows:[[String:Any]]=[];let deadline=Date().addingTimeInterval(40)
 while let e=stack.popLast(),Date()<deadline,seen.count<4000{
 guard seen.insert(e).inserted else{continue}
 stack.append(contentsOf:(read(e,"AXChildren") as? [AXUIElement] ?? []).reversed())
 guard read(e,"AXRole") as? String == "AXStaticText",let text=read(e,"AXValue") as? String,!text.isEmpty,
 let position=read(e,"AXPosition"),let size=read(e,"AXSize") else{continue}
 var pt=CGPoint.zero,sz=CGSize.zero;guard AXValueGetValue(position as! AXValue,.cgPoint,&pt),AXValueGetValue(size as! AXValue,.cgSize,&sz) else{continue};let frame=CGRect(origin:pt,size:sz)
 guard let original=raw.first(where:{r in guard let id=r["id"] as? Int,wanted.contains(id),!found.contains(id),r["value"] as? String == text,let f=r["frame"] as? [String:Double] else{return false};return abs(f["x"]!-frame.minX)<1 && abs(f["y"]!-frame.minY)<1 && abs(f["width"]!-frame.width)<1 && abs(f["height"]!-frame.height)<1}) else{continue}
 let id=original["id"] as! Int;found.insert(id)
 let access=AXTextAccess()
 var routes:[[String:Any]]=[]
 let whole=read(e,"AXTextMarkerRangeForUIElement",e)
 if let whole,CFGetTypeID(whole)==AXTextMarkerRangeGetTypeID(){
 let range=whole as! AXTextMarkerRange,start=AXTextMarkerRangeCopyStartMarker(range),end=AXTextMarkerRangeCopyEndMarker(range)
 for route in ["previous-start-from-end","previous-start-from-last-char","left-line-from-end","right-line-from-start"] {
 var times:[Double]=[],last:[String:Any]=[:]
 for _ in 0..<7 {
 let t=Date();var calls=0
 func q(_ key:String,_ input:CFTypeRef)->CFTypeRef?{calls+=1;return read(e,key,input)}
 var candidate:CFTypeRef?
 if route=="previous-start-from-end",let a=q("AXPreviousLineStartTextMarkerForTextMarker",end),CFGetTypeID(a)==AXTextMarkerGetTypeID(){candidate=AXTextMarkerRangeCreate(nil,a as! AXTextMarker,end)}
 if route=="previous-start-from-last-char",let ch=q("AXPreviousTextMarkerForTextMarker",end),let a=q("AXPreviousLineStartTextMarkerForTextMarker",ch),CFGetTypeID(a)==AXTextMarkerGetTypeID(){candidate=AXTextMarkerRangeCreate(nil,a as! AXTextMarker,end)}
 if route=="left-line-from-end"{candidate=q("AXLeftLineTextMarkerRangeForTextMarker",end)}
 if route=="right-line-from-start"{candidate=q("AXRightLineTextMarkerRangeForTextMarker",start)}
 let source=candidate.flatMap{q("AXStringForTextMarkerRange",$0) as? String}
 last=["route":route,"source":source as Any? ?? NSNull(),"matches":source==text,"callsWithoutWhole":calls]
 times.append(Date().timeIntervalSince(t)*1000)
 }
 last["medianMs"]=Array(times.dropFirst()).sorted()[3];routes.append(last)
 }
 var tree:[[String:Any]]=[];var complete=false
 let description=read(e,"AXTextMarkerNodeDebugDescription",start) as? String ?? ""
 if !description.isEmpty {let raw=access.internalTree(e,start,description){node in ["value":read(node,"AXValue") as? String ?? ""]};tree=raw.nodes;complete=raw.complete}
 rows.append(["node":id,"text":text,"frame":rect(frame),"routes":routes,"description":description,"tree":tree,"treeComplete":complete,"priorLineProbe":(raw.first(where:{($0["paragraphLineInvestigation"] as? [String:Any])?["sourceNodes"] as? [Int] == [id]})?["paragraphLineInvestigation"] as Any?) ?? NSNull()])
 }

 }
 let result:[String:Any]=["rows":rows,"matched":found.count,"wanted":wanted.count,"timedOut":Date()>deadline,"method":"native reverse-line boundary and inline fragment inspection","baseline":"existing markers-local; not independent screenshot ground truth"]
 try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:folder.appendingPathComponent("line-semantics-probe.json"));print("Probed \(rows.count) nodes; timeout=\(Date()>deadline)")
}
@main struct Probe {static func main(){do{try run()}catch{fputs("\(error)\n",stderr);exit(1)}}}
