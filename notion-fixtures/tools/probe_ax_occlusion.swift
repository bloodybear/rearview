// Research only: timeline occlusion metadata. No hit-test, mouse event, pixels, or document mutation.
// AX child order does not prove paint order; class/geometry are candidates, not visibility facts.
import AppKit
import ApplicationServices

func read(_ e: AXUIElement, _ key: String, _ arg: CFTypeRef? = nil) -> (CFTypeRef?, Int32) {
    var v: CFTypeRef?
    let error = arg.map { AXUIElementCopyParameterizedAttributeValue(e, key as CFString, $0, &v) }
        ?? AXUIElementCopyAttributeValue(e, key as CFString, &v)
    return (v, error.rawValue)
}
func encoded(_ v: CFTypeRef) -> Any {
    if CFGetTypeID(v) == AXValueGetTypeID() {
        let a = v as! AXValue
        switch AXValueGetType(a) {
        case .cgPoint: var p=CGPoint.zero; AXValueGetValue(a,.cgPoint,&p); return ["x":p.x,"y":p.y]
        case .cgSize: var s=CGSize.zero; AXValueGetValue(a,.cgSize,&s); return ["width":s.width,"height":s.height]
        case .cfRange: var r=CFRange(); AXValueGetValue(a,.cfRange,&r); return ["location":r.location,"length":r.length]
        default: return String(describing:v)
        }
    }
    return String(describing:v)
}
func query(_ e: AXUIElement, _ key: String) -> [String:Any] {
    let (v,error)=read(e,key); var result:[String:Any]=["error":error]
    if let v { result["value"]=encoded(v) }; return result
}
func run() throws {
    guard CommandLine.arguments.count == 2, AXIsProcessTrusted(),
          let process=NSRunningApplication.runningApplications(withBundleIdentifier:"notion.id").first else {
        throw NSError(domain:"Notion/AX unavailable",code:1)
    }
    let app=AXUIElementCreateApplication(process.processIdentifier)
    AXUIElementSetMessagingTimeout(app,1)
    let prior=read(app,"AXManualAccessibility").0
    defer { if let prior { AXUIElementSetAttributeValue(app,"AXManualAccessibility" as CFString,prior) } }
    _=AXUIElementSetAttributeValue(app,"AXManualAccessibility" as CFString,kCFBooleanTrue)
    Thread.sleep(forTimeInterval:1)
    guard let w=read(app,"AXFocusedWindow").0 else {throw NSError(domain:"No window",code:1)}
    var elements:[AXUIElement]=[], parents:[Int?]=[], stack:[(AXUIElement,Int?)]=[(w as! AXUIElement,nil)]
    let deadline=Date().addingTimeInterval(25)
    while let (e,parent)=stack.popLast(), elements.count<3500,Date()<deadline {
        if elements.contains(where:{CFEqual($0,e)}) {continue}
        let index=elements.count;elements.append(e);parents.append(parent)
        stack.append(contentsOf:(read(e,"AXChildren").0 as? [AXUIElement] ?? []).reversed().map{($0,index)})
    }
    var rows:[[String:Any]]=[]
    for (i,e) in elements.enumerated() {
        var row:[String:Any]=["id":i]
        if let parent=parents[i] {row["parent"]=parent}
        for key in ["AXRole","AXValue","AXTitle","AXPosition","AXSize","AXDOMClassList","AXDOMIdentifier","AXDescription","AXVisibleChildren","AXZIndex","AXZOrder","AXHidden","AXVisible"] {
            let (v,error)=read(e,key)
            if key == "AXVisibleChildren", let children=v as? [AXUIElement] {
                row[key]=["error":error,"ids":children.map{child in elements.firstIndex{CFEqual($0,child)} ?? -1}]
            } else if let strings=v as? [String] {
                row[key]=["error":error,"value":strings]
            } else { row[key]=query(e,key) }
        }
        rows.append(row)
    }
    let data:[String:Any]=["timestamp":ISO8601DateFormatter().string(from:Date()),"truncated":!stack.isEmpty,"nodes":rows]
    try JSONSerialization.data(withJSONObject:data,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
    print("nodes \(rows.count)")
}
do {try run()} catch {fputs("\(error)\n",stderr);exit(1)}
