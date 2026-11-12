// Research only. Marker APIs below are declared in the current Apple SDK
// (AXUIElement.h / AXWebConstants.h); attribute support remains app-specific.
import AppKit
import ApplicationServices
func markerStart(_ range: CFTypeRef) -> CFTypeRef? {
    guard CFGetTypeID(range) == AXTextMarkerRangeGetTypeID() else { return nil }
    return AXTextMarkerRangeCopyStartMarker(range as! AXTextMarkerRange)
}
var calls = 0
var recordTrace=false
var trace:[[String:Any]]=[]
func q(_ e:AXUIElement,_ key:String,_ input:CFTypeRef? = nil)->CFTypeRef? {
    calls += 1; var value:CFTypeRef?
    let error = input.map { AXUIElementCopyParameterizedAttributeValue(e,key as CFString,$0,&value) } ?? AXUIElementCopyAttributeValue(e,key as CFString,&value)
    if recordTrace { trace.append(["attribute":key,"error":error.rawValue,"output":String(describing:value).prefix(250).description]) }
    return error == .success ? value:nil
}
func rect(_ b:CGRect)->[String:Double] {["x":b.minX,"y":b.minY,"width":b.width,"height":b.height]}
func bounds(_ value:CFTypeRef?)->CGRect? {
    guard let value,CFGetTypeID(value)==AXValueGetTypeID() else{return nil}
    var b=CGRect.zero
    guard AXValueGetValue(value as! AXValue,.cgRect,&b),b.width>0,b.height>0,b.minX.isFinite,b.minY.isFinite,b.width.isFinite,b.height.isFinite else{return nil};return b
}
func range(_ value:CFTypeRef?)->CFRange? {
    guard let value,CFGetTypeID(value)==AXValueGetTypeID() else{return nil};var r=CFRange();return AXValueGetValue(value as! AXValue,.cfRange,&r) ? r:nil
}
func scan(_ app:AXUIElement)->AXUIElement? {
    var stack=[app],n=0
    while let e=stack.popLast(),n<3500 {n+=1
        if q(e,"AXRole") as? String == "AXStaticText",(q(e,"AXValue") as? String)?.hasPrefix("この依頼は、申請者が") == true{return e}
        stack += q(e,"AXChildren") as? [AXUIElement] ?? []
    };return nil
}
func lines(_ node:AXUIElement,_ text:String,_ method:String)->[[String:Any]] {
    var result:[[String:Any]]=[],offset=0;let total=(text as NSString).length
    if method=="characters" {
        var groups:[(Int,Int,CGRect)]=[]
        for scalar in text.unicodeScalars {let length=scalar.value>0xffff ? 2:1;var r=CFRange(location:offset,length:length)
            guard let b=bounds(q(node,"AXBoundsForRange",AXValueCreate(.cfRange,&r))) else {return []}
            if let last=groups.last,abs(last.2.minY-b.minY)<=1,abs(last.2.height-b.height)<=1 {groups[groups.count-1]=(last.0,last.1+length,last.2.union(b))}else{groups.append((offset,length,b))};offset+=length
        }
        return groups.map {start,length,b in ["start":start,"length":length,"text":(text as NSString).substring(with:NSRange(location:start,length:length)),"box":rect(b)]}
    }
    if method=="standard" {
        while offset<total,result.count<128 {
            guard let index=q(node,"AXLineForIndex",NSNumber(value:offset)) as? NSNumber,index.intValue != NSNotFound,
                  var r=range(q(node,"AXRangeForLine",index)),r.location==offset,r.length>0,r.length<=total-offset else{return result}
            guard let string=q(node,"AXStringForRange",AXValueCreate(.cfRange,&r)) as? String,
                  string==(text as NSString).substring(with:NSRange(location:r.location,length:r.length)),
                  let b=bounds(q(node,"AXBoundsForRange",AXValueCreate(.cfRange,&r))) else{return result}
            result.append(["start":offset,"length":r.length,"text":string,"box":rect(b)]);offset+=r.length
        };return result
    }
    if method=="marker-indexed" {
        var index=0
        while offset<total,index<128 {
            guard let pair=q(node,"AXTextMarkerRangeForLine",NSNumber(value:index)),
                  let string=q(node,"AXStringForTextMarkerRange",pair) as? String,!string.isEmpty else{return result}
            let length=(string as NSString).length
            guard length<=total-offset,string==(text as NSString).substring(with:NSRange(location:offset,length:length)),
                  let b=bounds(q(node,"AXBoundsForTextMarkerRange",pair)) else{return result}
            result.append(["start":offset,"length":length,"text":string,"box":rect(b)]);offset+=length;index+=1
        };return result
    }
    guard let whole=q(node,"AXTextMarkerRangeForUIElement",node),var start=markerStart(whole) else{return []}
    while offset<total,result.count<128 {
        guard let end=q(node,"AXNextLineEndTextMarkerForTextMarker",start),
              CFGetTypeID(start)==AXTextMarkerGetTypeID(),CFGetTypeID(end)==AXTextMarkerGetTypeID() else{return result}
        let pair: CFTypeRef?
        if method=="markers-local" {
            pair=AXTextMarkerRangeCreate(nil,start as! AXTextMarker,end as! AXTextMarker)
        } else { pair=q(node,"AXTextMarkerRangeForUnorderedTextMarkers",[start,end] as CFArray) }
        guard let pair,let string=q(node,"AXStringForTextMarkerRange",pair) as? String,!string.isEmpty else{return result}
        let length=(string as NSString).length
        guard length<=total-offset,string==(text as NSString).substring(with:NSRange(location:offset,length:length)),
              let b=bounds(q(node,"AXBoundsForTextMarkerRange",pair)) else{return result}
        result.append(["start":offset,"length":length,"text":string,"box":rect(b)]);offset+=length;start=end
    };return result
}
func run() throws {
    guard CommandLine.arguments.count==3,AXIsProcessTrusted(),let process=NSRunningApplication.runningApplications(withBundleIdentifier:"notion.id").first else{throw NSError(domain:"Usage: compare OUTPUT.json manual|enhanced|both",code:1)}
    let app=AXUIElementCreateApplication(process.processIdentifier),mode=CommandLine.arguments[2]
    let keys=mode=="manual" ? ["AXManualAccessibility"] : mode=="both" ? ["AXManualAccessibility","AXEnhancedUserInterface"] : ["AXEnhancedUserInterface"]
    let old=keys.map {q(app,$0)}
    defer{for (key,value) in zip(keys,old){if let value{AXUIElementSetAttributeValue(app,key as CFString,value)}}}
    var errors:[String:Int32]=[:];for key in keys{errors[key]=AXUIElementSetAttributeValue(app,key as CFString,kCFBooleanTrue).rawValue}
    let deadline=Date().addingTimeInterval(5);var found:AXUIElement?
    repeat {Thread.sleep(forTimeInterval:0.1);if let n=scan(app){var r=CFRange(location:0,length:1);if let b=bounds(q(n,"AXBoundsForRange",AXValueCreate(.cfRange,&r))),b.width<40,b.height<40{found=n;break}}}while Date()<deadline
    guard let node=found,let text=q(node,"AXValue") as? String else{throw NSError(domain:"No usable paragraph",code:1)}
    var nodes=[node];if let parent=q(node,"AXParent"),CFGetTypeID(parent)==AXUIElementGetTypeID(){nodes.append(parent as! AXUIElement)}
    var rows:[[String:Any]]=[]
    for n in nodes {var names:CFArray?;AXUIElementCopyParameterizedAttributeNames(n,&names)
        for method in ["standard","marker-indexed","markers","markers-local","characters"] {for iteration in 0..<10 {
            calls=0;let started=Date();let result=lines(n,text,method);let elapsed=Date().timeIntervalSince(started),count=calls
            var row:[String:Any]=["role":q(n,"AXRole") as? String ?? "","method":method,"iteration":iteration,"calls":count,"seconds":elapsed,"lines":result,"complete":result.map{$0["text"] as! String}.joined()==text,"parameterizedAttributes":names as? [String] ?? []]
            if iteration==0 { trace=[];recordTrace=true;_ = lines(n,text,method);recordTrace=false;row["diagnosticTraceOutsideTiming"]=trace }
            rows.append(row)
        }}
    }
    let output:[String:Any]=["mode":mode,"settingErrors":errors,"pid":process.processIdentifier,"text":text,"measurements":rows]
    try JSONSerialization.data(withJSONObject:output,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
}
do{try run()}catch{fputs("\(error)\n",stderr);exit(1)}
