// Research only. No hit-test, mouse event, pixel inspection, or document mutation.
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
    let activation=AXUIElementSetAttributeValue(app,"AXManualAccessibility" as CFString,kCFBooleanTrue)
    Thread.sleep(forTimeInterval:1)
    guard let w=read(app,"AXFocusedWindow").0 else {throw NSError(domain:"No window",code:1)}
    var elements:[AXUIElement]=[], parents:[Int?]=[], stack:[(AXUIElement,Int?)]=[(w as! AXUIElement,nil)]
    let deadline=Date().addingTimeInterval(25)
    while let (e,parent)=stack.popLast(), elements.count<3500,Date()<deadline {
        if elements.contains(where:{CFEqual($0,e)}) {continue}
        let index=elements.count;elements.append(e);parents.append(parent)
        stack.append(contentsOf:(read(e,"AXChildren").0 as? [AXUIElement] ?? []).reversed().map{($0,index)})
    }
    var searches:[[String:Any]]=[], memberships:[Int:[Bool:[AXUIElement]]]=[:]
    for (index,e) in elements.enumerated() where read(e,"AXRole").0 as? String == "AXWebArea" {
        for visible in [false,true] {
            let predicate:[String:Any]=["AXSearchKey":"AXAnyTypeSearchKey","AXResultsLimit":10000,
                "AXVisibleOnly":visible,"AXDirection":"AXDirectionNext","AXImmediateDescendantsOnly":false]
            let start=Date();let(v,error)=read(e,"AXUIElementsForSearchPredicate",predicate as CFDictionary)
            let found=v as? [AXUIElement] ?? []
            memberships[index,default:[:]][visible]=found
            searches.append(["root":index,"visibleOnly":visible,"error":error,"count":found.count,
                             "elapsedMs":Date().timeIntervalSince(start)*1000])
        }
    }
    let keys=["AXOffscreen","AXOffScreen","AXIsOffscreen","AXHidden","AXVisible","AXClipsChildren",
              "AXVisibleCharacterRange","AXPosition","AXSize"]
    var rows:[[String:Any]]=[]
    for (i,e) in elements.enumerated() {
        let role=read(e,"AXRole").0 as? String ?? ""
        let value=read(e,"AXValue").0 as? String ?? "",title=read(e,"AXTitle").0 as? String ?? ""
        var names:CFArray?;let namesError=AXUIElementCopyAttributeNames(e,&names)
        var row:[String:Any]=["id":i,"role":role,"text":value,"title":title,
            "namesError":namesError.rawValue,"attributes":names as? [String] ?? []]
        if let p=parents[i] {row["parent"]=p}
        if role == "AXStaticText" || role == "AXGroup" || role == "AXWebArea" || !title.isEmpty {
            row["queries"]=Dictionary(uniqueKeysWithValues:keys.map{($0,query(e,$0))})
        }
        row["searchMembership"]=memberships.map { root,lists -> [String:Any] in
            ["root":root,"all":lists[false]?.contains{CFEqual($0,e)} ?? false,
             "visibleOnly":lists[true]?.contains{CFEqual($0,e)} ?? false]
        }
        rows.append(row)
    }
    // Benchmark discovery + identical basic fields, excluding research JSON,
    // text-range calls, translation and screenshots. Alternate order to reduce bias.
    func consume(_ e: AXUIElement) {
        for key in ["AXRole","AXValue","AXTitle","AXPosition","AXSize"] { _ = read(e,key) }
    }
    var benchmarks:[[String:Any]]=[]
    for (root,_) in memberships.sorted(by:{$0.key < $1.key}) {
        let e=elements[root]
        for round in 0..<7 {
            for mode in (round % 2 == 0 ? ["tree","visible-search"] : ["visible-search","tree"]) {
                let started=Date(); var count=0,finished=true,error:Int32=0
                if mode == "tree" {
                    var pending=[e],visited:[CFHashCode:[AXUIElement]]=[:]
                    while let node=pending.popLast() {
                        let hash=CFHash(node)
                        if visited[hash]?.contains(where:{CFEqual($0,node)}) == true {continue}
                        visited[hash,default:[]].append(node)
                        consume(node);count+=1
                        pending.append(contentsOf:(read(node,"AXChildren").0 as? [AXUIElement] ?? []).reversed())
                        if count>=10000 || Date().timeIntervalSince(started)>10 {finished=false;break}
                    }
                } else {
                    let predicate:[String:Any]=["AXSearchKey":"AXAnyTypeSearchKey","AXResultsLimit":10000,
                        "AXVisibleOnly":true,"AXDirection":"AXDirectionNext","AXImmediateDescendantsOnly":false]
                    let(v,err)=read(e,"AXUIElementsForSearchPredicate",predicate as CFDictionary);error=err
                    consume(e);count=1
                    for node in v as? [AXUIElement] ?? [] {consume(node);count+=1}
                }
                benchmarks.append(["root":root,"round":round,"warmup":round==0,"mode":mode,
                    "elapsedMs":Date().timeIntervalSince(started)*1000,"nodes":count,"finished":finished,"error":error])
            }
        }
    }
    let data:[String:Any]=["timestamp":ISO8601DateFormatter().string(from:Date()),"activationError":activation.rawValue,
        "windowTitle":read(w as! AXUIElement,"AXTitle").0 as? String ?? "","truncated":!stack.isEmpty,
        "nodes":rows,"searches":searches,"benchmarks":benchmarks,"method":"AX attributes and search predicate; no hit-test or text-range queries"]
    try JSONSerialization.data(withJSONObject:data,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
    print("nodes \(rows.count); searches \(searches)")
}
do {try run()} catch {fputs("\(error)\n",stderr);exit(1)}
