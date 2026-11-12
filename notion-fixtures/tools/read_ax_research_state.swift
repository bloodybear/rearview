import AppKit
import ApplicationServices
guard AXIsProcessTrusted(),let p=NSRunningApplication.runningApplications(withBundleIdentifier:"notion.id").first else { fputs("Notion or AX permission unavailable\n",stderr);exit(1) }
let app=AXUIElementCreateApplication(p.processIdentifier)
AXUIElementSetMessagingTimeout(app,0.35)
func q(_ e:AXUIElement,_ k:String)->CFTypeRef? {var v:CFTypeRef?;let err=AXUIElementCopyAttributeValue(e,k as CFString,&v);return err == .success ? v:nil}
print("trusted",AXIsProcessTrusted(),p.processIdentifier)
var stack=[app];var count=0
while let e=stack.popLast(),count<3500 {count+=1;if q(e,"AXRole") as? String == "AXWebArea" {print("web",q(e,"AXURL") as Any)};stack += q(e,"AXChildren") as? [AXUIElement] ?? []}
print(count)
