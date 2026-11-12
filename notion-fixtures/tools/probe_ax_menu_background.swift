// Research only: menu background AX availability. No hit-test, pixels, or document mutation.
// --cycle dismisses/reopens the menu with Escape/AXPress/a click to test retained handles.
// Never invoke this interaction from the extractor.
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

func nodes(_ root:AXUIElement, keys:[String] = ["AXChildren"]) -> [AXUIElement] {
    var result:[AXUIElement]=[],pending=[root]
    while let e=pending.popLast(),result.count<3500 {
        if result.contains(where:{CFEqual($0,e)}) {continue}
        result.append(e)
        for key in keys {pending.append(contentsOf:read(e,key).0 as? [AXUIElement] ?? [])}
    }
    return result
}
func snapshot(_ app:AXUIElement) -> [String:Any] {
    let window=(read(app,"AXFocusedWindow").0 as! AXUIElement)
    let normal=nodes(window),alternate=nodes(window,keys:["AXChildren","AXChildrenInNavigationOrder","AXVisibleChildren","AXContents","AXWindows"])
    var searches:[[String:Any]]=[]
    for root in normal where read(root,"AXRole").0 as? String == "AXWebArea" {
        for visible in [false,true] {
            let p:[String:Any] = ["AXSearchKey":"AXAnyTypeSearchKey","AXResultsLimit":10000,"AXVisibleOnly":visible,"AXDirection":"AXDirectionNext","AXImmediateDescendantsOnly":false]
            let(v,error)=read(root,"AXUIElementsForSearchPredicate",p as CFDictionary)
            let found=v as? [AXUIElement] ?? []
            searches.append(["rootTitle":read(root,"AXTitle").0 as? String ?? "","visibleOnly":visible,"error":error,"count":found.count,"bodyNodes":found.filter{(read($0,"AXDOMClassList").0 as? [String] ?? []).contains("notion-frame")}.count])
        }
    }
    return ["normalCount":normal.count,"alternateCount":alternate.count,"searches":searches,
        "bodyNodes":alternate.filter{(read($0,"AXDOMClassList").0 as? [String] ?? []).contains("notion-frame")}.count,
        "nodes":normal.enumerated().map { i,e -> [String:Any] in
            var actions:CFArray?;AXUIElementCopyActionNames(e,&actions)
            return ["id":i,"role":read(e,"AXRole").0 as? String ?? "","text":read(e,"AXValue").0 as? String ?? "","title":read(e,"AXTitle").0 as? String ?? "","classes":read(e,"AXDOMClassList").0 as? [String] ?? [],"actions":actions as? [String] ?? [],"modal":query(e,"AXModal"),"hidden":query(e,"AXHidden")]
        }]
}
func run() throws {
    guard AXIsProcessTrusted(), let process=NSRunningApplication.runningApplications(withBundleIdentifier:"notion.id").first, CommandLine.arguments.count>=2 else {throw NSError(domain:"Notion unavailable",code:1)}
    let app=AXUIElementCreateApplication(process.processIdentifier);AXUIElementSetMessagingTimeout(app,0.4)
    let keys=["AXManualAccessibility","AXEnhancedUserInterface"],prior=keys.map{read(app,$0).0}
    defer{for(k,v)in zip(keys,prior){AXUIElementSetAttributeValue(app,k as CFString,v ?? kCFBooleanFalse)}}
    var data:[String:Any]=["timestamp":ISO8601DateFormatter().string(from:Date())]
    AXUIElementSetAttributeValue(app,keys[0] as CFString,kCFBooleanTrue);Thread.sleep(forTimeInterval:0.6)
    data["manual"]=snapshot(app)
    AXUIElementSetAttributeValue(app,keys[1] as CFString,kCFBooleanTrue);Thread.sleep(forTimeInterval:0.6)
    data["both"]=snapshot(app)
    if CommandLine.arguments.count == 3 && CommandLine.arguments[2] == "--cycle" {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == process.processIdentifier else {throw NSError(domain:"Notion must be foreground for controlled Escape",code:1)}
        let window=read(app,"AXFocusedWindow").0 as! AXUIElement
        let initial=nodes(window)
        let initiallyOpen=initial.contains(where:{(read($0,"AXPlaceholderValue").0 as? String ?? "").contains("Search actions")})
        data["initiallyOpen"]=initiallyOpen
        // Research only: dismiss/reopen the menu, never mutate the document.
        // These targeted key/AXPress actions are NOT part of the extractor.
        if initiallyOpen {
        CGEvent(keyboardEventSource:nil,virtualKey:53,keyDown:true)?.postToPid(process.processIdentifier)
        CGEvent(keyboardEventSource:nil,virtualKey:53,keyDown:false)?.postToPid(process.processIdentifier)
        }
        Thread.sleep(forTimeInterval:0.8)
        let closed=nodes(window)
        guard let body=closed.first(where:{(read($0,"AXDOMClassList").0 as? [String] ?? []).contains("notion-frame")}),
              let actions=closed.first(where:{(read($0,"AXDescription").0 as? String)=="Actions"}) else {throw NSError(domain:"Menu close did not restore body/Actions",code:1)}
        data["closed"]=snapshot(app)
        let retained=nodes(body).filter{read($0,"AXRole").0 as? String == "AXStaticText"}
        let before=retained.map{read($0,"AXValue").0 as? String ?? ""}
        let press=AXUIElementPerformAction(actions,"AXPress" as CFString)
        guard press == .success else {throw NSError(domain:"Actions AXPress failed",code:Int(press.rawValue))}
        Thread.sleep(forTimeInterval:0.8)
        func isOpen() -> Bool {nodes(window).contains{(read($0,"AXPlaceholderValue").0 as? String ?? "").contains("Search actions")}}
        if !isOpen() {
            guard let p=read(actions,"AXPosition").0,let s=read(actions,"AXSize").0 else {throw NSError(domain:"Actions frame unavailable",code:1)}
            var point=CGPoint.zero,size=CGSize.zero
            AXValueGetValue(p as! AXValue,.cgPoint,&point);AXValueGetValue(s as! AXValue,.cgSize,&size)
            point.x += size.width/2;point.y += size.height/2
            // Research-only targeted click because AXPress can return success
            // without opening this Notion control. Never used by the extractor.
            CGEvent(mouseEventSource:nil,mouseType:.leftMouseDown,mouseCursorPosition:point,mouseButton:.left)?.post(tap:.cghidEventTap)
            CGEvent(mouseEventSource:nil,mouseType:.leftMouseUp,mouseCursorPosition:point,mouseButton:.left)?.post(tap:.cghidEventTap)
            Thread.sleep(forTimeInterval:1)
            data["reopenMethod"]="AXPress then targeted click"
        } else {data["reopenMethod"]="AXPress"}
        guard isOpen() else {throw NSError(domain:"Menu did not reopen; retained-handle comparison invalid",code:1)}
        data["reopened"]=snapshot(app)
        data["retainedBodyTraversalCount"]=nodes(body).count
        data["retainedNodes"]=zip(retained,before).map{e,text -> [String:Any] in
            let (v,error)=read(e,"AXValue")
            return ["beforeText":text,"afterText":v as? String ?? "","valueError":error,
                    "role":query(e,"AXRole"),"position":query(e,"AXPosition"),"size":query(e,"AXSize"),"hidden":query(e,"AXHidden")]
        }
    }
    try JSONSerialization.data(withJSONObject:data,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
    print("saved",CommandLine.arguments[1])
}
do{try run()}catch{fputs("\(error)\n",stderr);exit(1)}
