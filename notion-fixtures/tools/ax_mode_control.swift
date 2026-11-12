// Research process-scoped mode control and read-only lifetime observations.
import AppKit
import ApplicationServices
func q(_ e:AXUIElement,_ k:String,_ p:CFTypeRef?=nil)->CFTypeRef?{var v:CFTypeRef?;let err=p.map{AXUIElementCopyParameterizedAttributeValue(e,k as CFString,$0,&v)} ?? AXUIElementCopyAttributeValue(e,k as CFString,&v);return err == .success ? v:nil}
guard AXIsProcessTrusted(),let process=NSRunningApplication.runningApplications(withBundleIdentifier:"notion.id").first else{exit(1)}
let app=AXUIElementCreateApplication(process.processIdentifier)
var out:[String:Any]=["pid":process.processIdentifier]
let windowInfo = CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements],kCGNullWindowID) as? [[String:Any]] ?? []
out["windowIDs"] = windowInfo.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == process.processIdentifier && ($0[kCGWindowLayer as String] as? Int) == 0 }.compactMap { $0[kCGWindowNumber as String] as? Int }
out["windows"] = (q(app,"AXWindows") as? [AXUIElement] ?? []).map {String(describing:$0)}
if let w=q(app,"AXFocusedWindow"),CFGetTypeID(w)==AXUIElementGetTypeID(){out["windowTitle"]=String(describing:q(w as! AXUIElement,"AXTitle"))}
let args=Array(CommandLine.arguments.dropFirst())
if args.count==2,args[0]=="set" {out["setterError"]=AXUIElementSetAttributeValue(app,"AXManualAccessibility" as CFString,args[1]=="true" ? kCFBooleanTrue:kCFBooleanFalse).rawValue}
if args==["new-window"],let raw=q(app,"AXMenuBar"),CFGetTypeID(raw)==AXUIElementGetTypeID(){
 let bar=raw as! AXUIElement
 if let file=(q(bar,"AXChildren") as? [AXUIElement] ?? []).first(where:{q($0,"AXTitle") as? String == "File"}) {
  var stack=[file]
  while let e=stack.popLast(){if q(e,"AXTitle") as? String == "New Window" {out["newWindowError"]=AXUIElementPerformAction(e,"AXPress" as CFString).rawValue;break};stack += q(e,"AXChildren") as? [AXUIElement] ?? []}
 }
}
if args==["close-window"],let raw=q(app,"AXFocusedWindow"),CFGetTypeID(raw)==AXUIElementGetTypeID(),let close=q(raw as! AXUIElement,"AXCloseButton"),CFGetTypeID(close)==AXUIElementGetTypeID(){out["closeError"]=AXUIElementPerformAction(close as! AXUIElement,"AXPress" as CFString).rawValue}
for key in ["AXManualAccessibility","AXEnhancedUserInterface"]{out[key]=String(describing:q(app,key))}
let scanRoot = q(app,"AXFocusedWindow").map { $0 as! AXUIElement } ?? app
var stack=[scanRoot],count=0
while let e=stack.popLast(),count<3500{count+=1
 if q(e,"AXRole") as? String == "AXStaticText",(q(e,"AXValue") as? String)?.hasPrefix("この依頼は、申請者が") == true {
  out["samplePosition"] = String(describing:q(e,"AXPosition"));out["sampleSize"] = String(describing:q(e,"AXSize"))
  var r=CFRange(location:0,length:1);out["firstBounds"]=String(describing:q(e,"AXBoundsForRange",AXValueCreate(.cfRange,&r)));break
 };stack += q(e,"AXChildren") as? [AXUIElement] ?? []
}
print(String(data:try! JSONSerialization.data(withJSONObject:out,options:[.sortedKeys]),encoding:.utf8)!)
