// Research only: compare AX-only visibility signals. Does not move the pointer,
// inspect pixels, mutate documents or change production selection rules.
import AppKit
import ApplicationServices

func read(_ element: AXUIElement, _ key: String, _ argument: CFTypeRef? = nil) -> (CFTypeRef?, Int32) {
    var value: CFTypeRef?
    let error = argument.map { AXUIElementCopyParameterizedAttributeValue(element, key as CFString, $0, &value) }
        ?? AXUIElementCopyAttributeValue(element, key as CFString, &value)
    return (error == .success ? value : nil, error.rawValue)
}
func box(_ element: AXUIElement) -> CGRect? {
    guard let p=read(element,"AXPosition").0, let s=read(element,"AXSize").0,
          CFGetTypeID(p)==AXValueGetTypeID(), CFGetTypeID(s)==AXValueGetTypeID() else { return nil }
    var point=CGPoint.zero, size=CGSize.zero
    guard AXValueGetValue(p as! AXValue,.cgPoint,&point), AXValueGetValue(s as! AXValue,.cgSize,&size) else{return nil}
    return CGRect(origin:point,size:size)
}
func encode(_ value: CFTypeRef) -> Any {
    if CFGetTypeID(value)==AXValueGetTypeID() {
        let ax=value as! AXValue
        switch AXValueGetType(ax) {
        case .cfRange:
            var range=CFRange();AXValueGetValue(ax,.cfRange,&range)
            return ["location":range.location,"length":range.length]
        case .cgRect:
            var r=CGRect.zero;AXValueGetValue(ax,.cgRect,&r)
            return ["x":r.minX,"y":r.minY,"width":r.width,"height":r.height]
        default:return String(describing:value)
        }
    }
    if let text=value as? NSAttributedString {
        var runs:[[String:Any]]=[]
        text.enumerateAttributes(in:NSRange(location:0,length:text.length)){ attrs,range,_ in
            runs.append(["location":range.location,"length":range.length,
                "attributes":Dictionary(uniqueKeysWithValues:attrs.map{($0.key.rawValue,String(describing:$0.value))})])
        }
        return ["text":text.string,"runs":runs]
    }
    if CFGetTypeID(value)==AXUIElementGetTypeID() {
        let e=value as! AXUIElement
        return ["role":read(e,"AXRole").0 as? String ?? "","title":read(e,"AXTitle").0 as? String ?? ""]
    }
    if let array=value as? [AXUIElement] {
        return array.map{["role":read($0,"AXRole").0 as? String ?? "","title":read($0,"AXTitle").0 as? String ?? ""]}
    }
    return String(describing:value)
}
func query(_ e:AXUIElement,_ key:String,_ arg:CFTypeRef? = nil)->[String:Any]{
    let (value,error)=read(e,key,arg);var r:[String:Any]=["error":error]
    if let value{r["value"]=encode(value)};return r
}
func allAttributes(_ element: AXUIElement) -> [String: Any] {
    var names: CFArray?
    let namesError = AXUIElementCopyAttributeNames(element, &names)
    guard namesError == .success, let keys = names as? [String] else {
        return ["namesError": namesError.rawValue]
    }
    var values: CFArray?
    let error = AXUIElementCopyMultipleAttributeValues(element, keys as CFArray,
        AXCopyMultipleAttributeOptions(rawValue: 0), &values)
    guard error == .success, let array = values as? [CFTypeRef], array.count == keys.count else {
        return ["multipleError": error.rawValue, "names": keys]
    }
    return Dictionary(uniqueKeysWithValues: zip(keys, array).map { ($0, encode($1)) })
}
func run() throws {
    guard CommandLine.arguments.count>=2, AXIsProcessTrusted(),
          let process=NSRunningApplication.runningApplications(withBundleIdentifier:"notion.id").first else{throw NSError(domain:"Notion/AX unavailable",code:1)}
    let observedAt=ISO8601DateFormatter().string(from:Date()),pointerBefore=NSEvent.mouseLocation
    let app=AXUIElementCreateApplication(process.processIdentifier)
    AXUIElementSetMessagingTimeout(app,0.3)
    let prior=read(app,"AXManualAccessibility").0
    defer{if let prior{AXUIElementSetAttributeValue(app,"AXManualAccessibility" as CFString,prior)}}
    AXUIElementSetAttributeValue(app,"AXManualAccessibility" as CFString,kCFBooleanTrue)
    Thread.sleep(forTimeInterval:1)
    guard let window=read(app,"AXFocusedWindow").0 else{throw NSError(domain:"No focused window",code:1)}
    let w=window as! AXUIElement,before=box(w),deadline=Date().addingTimeInterval(35)
    // Probe every titled control; labels do not select or exclude study outcomes.
    var stack=[w],results:[[String:Any]]=[],count=0
    var webArea:AXUIElement?
    let full = CommandLine.arguments.contains("--full")
    var ancestorCache: [CFHashCode: [String: Any]] = [:]
    while let e=stack.popLast(),count<3500,Date()<deadline {
        count+=1
        let role=read(e,"AXRole").0 as? String ?? "",title=read(e,"AXTitle").0 as? String ?? ""
        if role=="AXWebArea",webArea==nil || title.contains("project-database"){webArea=e}
        if ["AXButton","AXPopUpButton","AXRadioButton"].contains(role),!title.isEmpty {
            var item:[String:Any]=["role":role,"title":title]
            if full { item["allAttributes"] = allAttributes(e) }
            for key in ["AXHidden","AXVisible","AXVisibleCharacterRange","AXNumberOfCharacters","AXVisibleText","AXAlternateUIVisible","AXTitleUIElement","AXEnabled","AXFocused","AXSelected","AXCustomContent","AXDOMClassList"] {
                item[key]=query(e,key)
            }
            var range=CFRange(location:0,length:title.utf16.count)
            let arg=AXValueCreate(.cfRange,&range)!
            item["attributedRange"]=query(e,"AXAttributedStringForRange",arg)
            item["boundsRange"]=query(e,"AXBoundsForRange",arg)
            let (marker,error)=read(e,"AXTextMarkerRangeForUIElement",e)
            item["elementMarkerError"]=error
            if let marker {
                item["attributedMarker"]=query(e,"AXAttributedStringForTextMarkerRange",marker)
                item["boundsMarker"]=query(e,"AXBoundsForTextMarkerRange",marker)
            }
            var ancestors:[[String:Any]]=[],child=e
            while let p=read(child,"AXParent").0,CFGetTypeID(p)==AXUIElementGetTypeID(),ancestors.count<10 {
                let parent=p as! AXUIElement
                let (visible,ve)=read(parent,"AXVisibleChildren")
                let children=visible as? [AXUIElement]
                var ancestorInfo:[String:Any] = ["role":read(parent,"AXRole").0 as? String ?? "",
                    "hidden":query(parent,"AXHidden"),"alternateVisible":query(parent,"AXAlternateUIVisible"),
                    "visibleChildrenError":ve,"visibleChildrenCount":children?.count as Any? ?? NSNull(),
                    "childInVisibleChildren":children.map{$0.contains{CFEqual($0,child)}} as Any? ?? NSNull()]
                if full {
                    let key = CFHash(parent)
                    if ancestorCache[key] == nil { ancestorCache[key] = allAttributes(parent) }
                    ancestorInfo["allAttributes"] = ancestorCache[key]
                }
                ancestors.append(ancestorInfo)
                child=parent
            }
            item["ancestors"]=ancestors
            if let f=box(e) {
                item["frame"]=["x":f.minX,"y":f.minY,"width":f.width,"height":f.height]
                var hit:AXUIElement?
                let error=AXUIElementCopyElementAtPosition(app,Float(f.midX),Float(f.midY),&hit)
                var matched=false,path:[[String:String]]=[]
                while let h=hit,path.count<12 {
                    if CFEqual(h,e){matched=true}
                    path.append(["role":read(h,"AXRole").0 as? String ?? "","title":read(h,"AXTitle").0 as? String ?? ""])
                    if let parent=read(h,"AXParent").0,CFGetTypeID(parent)==AXUIElementGetTypeID(){hit=(parent as! AXUIElement)}else{hit=nil}
                }
                item["hitTest"]=["error":error.rawValue,"targetInPath":matched,"path":path]
                if CommandLine.arguments.contains("--grid"),f.width>1,f.height>1,before?.intersects(f)==true {
                    var samples:[[String:Any]]=[]
                    // Re-query each point after allowing Chromium's async hit-test
                    // response to arrive. A first reply may be a geometric guess.
                    let points = CommandLine.arguments.contains("--center-only")
                        ? [(0.5,0.5)] : [(0.2,0.5),(0.5,0.5),(0.8,0.5),(0.5,0.25),(0.5,0.75)]
                    for (dx,dy) in points {
                        var attempts:[[String:Any]]=[]
                        for attempt in 0..<6 {
                            var hit:AXUIElement?
                            let error=AXUIElementCopyElementAtPosition(app,Float(f.minX+f.width*dx),Float(f.minY+f.height*dy),&hit)
                            let first=hit
                            var matched=false,depth=0
                            while let h=hit,depth<16 {
                                if CFEqual(h,e){matched=true};depth+=1
                                if let p=read(h,"AXParent").0,CFGetTypeID(p)==AXUIElementGetTypeID(){hit=(p as! AXUIElement)}else{hit=nil}
                            }
                            attempts.append(["attempt":attempt,"error":error.rawValue,"targetInPath":matched,
                                "hit":first.map(encode) as Any? ?? NSNull()])
                            Thread.sleep(forTimeInterval:0.04)
                        }
                        samples.append(["relativeX":dx,"relativeY":dy,"attempts":attempts])
                    }
                    item["hitGrid"]=samples
                }
            }
            results.append(item)
        }
        stack.append(contentsOf:(read(e,"AXChildren").0 as? [AXUIElement] ?? []).reversed())
    }
    var visibleSearch:[String:Any]=[:]
    if let webArea {
        for visible in [false,true] {
            let predicate:[String:Any]=["AXSearchKey":"AXAnyTypeSearchKey","AXResultsLimit":3000,"AXVisibleOnly":visible,"AXDirection":"AXDirectionNext","AXImmediateDescendantsOnly":false]
            visibleSearch[String(visible)]=query(webArea,"AXUIElementsForSearchPredicate",predicate as CFDictionary)
        }
    }
    let pointerAfter=NSEvent.mouseLocation
    let data:[String:Any]=["startedAt":observedAt,"finishedAt":ISO8601DateFormatter().string(from:Date()),"pointerBefore":["x":pointerBefore.x,"y":pointerBefore.y],"pointerAfter":["x":pointerAfter.x,"y":pointerAfter.y],"pointerUnchanged":pointerBefore==pointerAfter,"focusedUIElement":query(app,"AXFocusedUIElement"),"visibleOnlySearch":visibleSearch,"windowTitle":read(w,"AXTitle").0 as? String ?? "","windowFrameUnchanged":before==box(w),
        "truncated":!stack.isEmpty || Date()>=deadline,"nodes":count,"controls":results,"method":"AX only; no pointer movement or pixel inspection"]
    try JSONSerialization.data(withJSONObject:data,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
    print("nodes \(count); controls \(results.count)")
}
do{try run()}catch{fputs("\(error)\n",stderr);exit(1)}
