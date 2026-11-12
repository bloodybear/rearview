// Research only: inspect native AX paragraph boundaries and existing ancestors.
// Never synthesize paragraph source by joining strings or grouping coordinates.
import AppKit
import ApplicationServices

struct Entry { let element: AXUIElement; let parent: Int?; let role: String; let text: String; let box: CGRect? }
func q(_ e: AXUIElement, _ key: String, _ input: CFTypeRef? = nil) -> (CFTypeRef?, Int32) {
    var value: CFTypeRef?
    let error = input.map { AXUIElementCopyParameterizedAttributeValue(e,key as CFString,$0,&value) }
        ?? AXUIElementCopyAttributeValue(e,key as CFString,&value)
    return (error == .success ? value : nil, error.rawValue)
}
func frame(_ e: AXUIElement) -> CGRect? {
    guard let p=q(e,"AXPosition").0, let s=q(e,"AXSize").0,
          CFGetTypeID(p)==AXValueGetTypeID(), CFGetTypeID(s)==AXValueGetTypeID() else { return nil }
    var point=CGPoint.zero, size=CGSize.zero
    guard AXValueGetValue(p as! AXValue,.cgPoint,&point), AXValueGetValue(s as! AXValue,.cgSize,&size) else { return nil }
    return CGRect(origin:point,size:size)
}
func rect(_ r:CGRect)->[String:Double] { ["x":r.minX,"y":r.minY,"width":r.width,"height":r.height] }
func describeRange(_ e:AXUIElement,_ range:CFTypeRef?,_ error:Int32)->[String:Any] {
    var result:[String:Any]=["rangeError":error]
    guard let range, CFGetTypeID(range)==AXTextMarkerRangeGetTypeID() else { return result }
    let (string,se)=q(e,"AXStringForTextMarkerRange",range)
    result["stringError"]=se;result["text"]=string as? String
    let (value,be)=q(e,"AXBoundsForTextMarkerRange",range);result["boundsError"]=be
    if let value, CFGetTypeID(value)==AXValueGetTypeID() {
        var r=CGRect.zero
        if AXValueGetValue(value as! AXValue,.cgRect,&r) { result["box"]=rect(r) }
    }
    return result
}
func run() throws {
    guard CommandLine.arguments.count==2, AXIsProcessTrusted(),
          let process=NSRunningApplication.runningApplications(withBundleIdentifier:"notion.id").first else { throw NSError(domain:"Usage: probe_ax_paragraphs COLLECTED_FOLDER",code:1) }
    let folder=URL(fileURLWithPath:CommandLine.arguments[1])
    let candidates=try JSONSerialization.jsonObject(with:Data(contentsOf:folder.appendingPathComponent("candidate.json"))) as! [[String:Any]]
    let wanted=Set(candidates.filter{$0["textSource"] as? String == "AXValue"}.compactMap{$0["text"] as? String})
    let app=AXUIElementCreateApplication(process.processIdentifier)
    AXUIElementSetMessagingTimeout(app,0.35)
    let prior=q(app,"AXManualAccessibility").0
    defer {if let prior {AXUIElementSetAttributeValue(app,"AXManualAccessibility" as CFString,prior)}}
    let activation=AXUIElementSetAttributeValue(app,"AXManualAccessibility" as CFString,kCFBooleanTrue)
    Thread.sleep(forTimeInterval:2.5)
    guard let window=q(app,"AXFocusedWindow").0 else {throw NSError(domain:"No window",code:1)}
    let windowElement=window as! AXUIElement
    let before=frame(windowElement)
    var entries:[Entry]=[],stack:[(AXUIElement,Int?)]=[(windowElement,nil)]
    let deadline=Date().addingTimeInterval(20)
    while let (e,parent)=stack.popLast(),entries.count<3500,Date()<deadline {
        let id=entries.count
        entries.append(Entry(element:e,parent:parent,role:q(e,"AXRole").0 as? String ?? "",text:q(e,"AXValue").0 as? String ?? "",box:frame(e)))
        for child in (q(e,"AXChildren").0 as? [AXUIElement] ?? []).reversed(){ stack.append((child,id)) }
    }
    var nestedAreas=Set<Int>()
    for entry in entries where entry.role=="AXTextArea" {
        var parent=entry.parent
        while let id=parent { if entries[id].role=="AXTextArea" {nestedAreas.insert(id)};parent=entries[id].parent }
    }
    var cache:[Int:[String:Any]]=[:]
    func ancestor(_ id:Int)->[String:Any] {
        if let value=cache[id]{return value}
        let e=entries[id]
        var value:[String:Any]=["probeNode":id,"role":e.role,"text":e.text,"containsNestedTextAreas":nestedAreas.contains(id)]
        value["box"]=e.box.map(rect)
        value["roleDescription"]=q(e.element,"AXRoleDescription").0 as? String
        value["domIdentifier"]=q(e.element,"AXDOMIdentifier").0 as? String
        value["domClasses"]=q(e.element,"AXDOMClassList").0 as? [String]
        if e.role=="AXTextArea" {let r=q(e.element,"AXTextMarkerRangeForUIElement",e.element);value["elementMarkerRange"]=describeRange(e.element,r.0,r.1)}
        cache[id]=value;return value
    }
    var results:[[String:Any]]=[]
    for (id,e) in entries.enumerated() where e.role=="AXStaticText" && wanted.contains(e.text) && !e.text.isEmpty {
        guard let b=e.box,b.width>1,b.height>1, before?.intersects(b)==true else {continue}
        guard Date()<deadline else {break}
        var item:[String:Any]=["probeNode":id,"text":e.text,"box":rect(b)]
        var parent=e.parent,path:[Int]=[]
        while let p=parent {path.append(p);parent=entries[p].parent}
        item["ancestorPath"]=path
        if let p=path.first(where:{entries[$0].role=="AXTextArea"}) {item["nearestTextArea"]=p;_=ancestor(p)}
        item["nearbyStructure"]=path.prefix(4).map(ancestor)
        let (whole,we)=q(e.element,"AXTextMarkerRangeForUIElement",e.element)
        item["nodeRangeError"]=we
        if let whole, CFGetTypeID(whole)==AXTextMarkerRangeGetTypeID() {
            let start=AXTextMarkerRangeCopyStartMarker(whole as! AXTextMarkerRange)
            let (paragraph,pe)=q(e.element,"AXParagraphTextMarkerRangeForTextMarker",start)
            item["paragraphAPI"]=describeRange(e.element,paragraph,pe)
            let (end,ee)=q(e.element,"AXNextParagraphEndTextMarkerForTextMarker",start)
            if let end,CFGetTypeID(end)==AXTextMarkerGetTypeID(){ item["nextParagraphEndAPI"]=describeRange(e.element,AXTextMarkerRangeCreate(nil,start,end as! AXTextMarker),ee) }
            else { item["nextParagraphEndAPI"]=["rangeError":ee] }
        }
        results.append(item)
    }
    let result:[String:Any]=["activationError":activation.rawValue,"method":"native AX ancestors and paragraph marker APIs; no synthesized source",
        "nodesScanned":entries.count,"truncated":!stack.isEmpty || Date()>=deadline,"windowFrameUnchanged":before==frame(windowElement),
        "ancestors":cache.mapValues{$0},"results":results]
    // JSON keys must be strings.
    var output=result;output["ancestors"]=Dictionary(uniqueKeysWithValues:cache.map{(String($0.key),$0.value)})
    try JSONSerialization.data(withJSONObject:output,options:[.prettyPrinted,.sortedKeys]).write(to:folder.appendingPathComponent("paragraph-probe.json"))
}
do {try run()} catch {fputs("\(error)\n",stderr);exit(1)}
