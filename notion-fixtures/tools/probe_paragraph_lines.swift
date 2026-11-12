// Research proof only: ordinary paragraph, not a production extractor.
// Build: swiftc notion-fixtures/tools/probe_paragraph_lines.swift -o /tmp/probe-paragraph-lines
// Run immediately after layout-wrap-640-closed replay: /tmp/probe-paragraph-lines OUTPUT.json
// Chromium needs inline-text geometry enabled before AXBoundsForRange is useful.
// AXEnhancedUserInterface is an undocumented AT signal; Notion can report
// kAXErrorNotImplemented (-25208) despite changing its behavior. Verify geometry,
// do not treat that setter return code or a fixed delay as readiness proof.
// Source: https://www.chromium.org/developers/design-documents/accessibility/
import AppKit
import ApplicationServices

func query(_ e: AXUIElement, _ key: String, _ input: CFTypeRef? = nil) -> CFTypeRef? {
    var value: CFTypeRef?
    let error = input.map { AXUIElementCopyParameterizedAttributeValue(e, key as CFString, $0, &value) }
        ?? AXUIElementCopyAttributeValue(e, key as CFString, &value)
    return error == .success ? value : nil
}
func box(_ e: AXUIElement, _ range: CFRange) -> CGRect? {
    var range = range
    guard let value = query(e, "AXBoundsForRange", AXValueCreate(.cfRange, &range)),
          CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    var result = CGRect.zero
    guard AXValueGetValue(value as! AXValue, .cgRect, &result), result.width > 0, result.height > 0,
          result.minX.isFinite, result.minY.isFinite, result.width.isFinite, result.height.isFinite else { return nil }
    return result
}
func rect(_ r: CGRect) -> [String: Double] { ["x":r.minX, "y":r.minY,"width":r.width,"height":r.height] }
let prefix = "この依頼は、申請者が"
func paragraph(_ root: AXUIElement) -> AXUIElement? {
    var stack = [root], count = 0
    while let e = stack.popLast(), count < 3500 {
        count += 1
        if query(e,"AXRole") as? String == "AXStaticText",
           (query(e,"AXValue") as? String)?.hasPrefix(prefix) == true { return e }
        stack.append(contentsOf: query(e,"AXChildren") as? [AXUIElement] ?? [])
    }
    return nil
}
func run() throws {
    guard CommandLine.arguments.count >= 2, AXIsProcessTrusted(),
          let process = NSRunningApplication.runningApplications(withBundleIdentifier:"notion.id").first else {
        throw NSError(domain:"Usage: probe OUTPUT.json; Notion and AX permission required",code:1)
    }
    let app = AXUIElementCreateApplication(process.processIdentifier)
    AXUIElementSetMessagingTimeout(app, 0.5)
    guard let initial = paragraph(app), let previous = query(app,"AXEnhancedUserInterface") else {
        throw NSError(domain:"Replay layout-wrap-640-closed first / missing AT attribute",code:1)
    }
    let statesBefore = Dictionary(uniqueKeysWithValues:["AXManualAccessibility","AXEnhancedUserInterface"].map { ($0,String(describing:query(app,$0))) })
    let before = box(initial,CFRange(location:0,length:1))
    let mode = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "enhanced"
    let keys = mode == "none" ? [] : mode == "manual" ? ["AXManualAccessibility"] : mode == "both" ? ["AXManualAccessibility","AXEnhancedUserInterface"] : ["AXEnhancedUserInterface"]
    let originals = keys.map { query(app,$0) }
    defer { for (key,value) in zip(keys,originals) { if let value { AXUIElementSetAttributeValue(app,key as CFString,value) } } }
    var settingErrors: [String:Int32] = [:]
    for key in keys { settingErrors[key] = AXUIElementSetAttributeValue(app,key as CFString,kCFBooleanTrue).rawValue }
    let setter = AXError(rawValue: settingErrors["AXEnhancedUserInterface"] ?? 0) ?? .success
    var evidence: [String:Any] = ["statesBefore":statesBefore,"mode":mode,"settingErrors":settingErrors,"pid":process.processIdentifier,"setterError":setter.rawValue,"attributeBefore":String(describing:previous)]
    if let before { evidence["firstCharacterBefore"] = rect(before) }
    else { evidence["firstCharacterBefore"] = NSNull() }
    // Reacquire the tree while Chromium asynchronously rebuilds inline geometry.
    // Bound waiting; final full-text and screenshot checks remain necessary.
    let started = Date(), deadline = started.addingTimeInterval(5)
    var ready: AXUIElement?
    repeat {
        Thread.sleep(forTimeInterval:0.1)
        if let node = paragraph(app), let first = box(node,CFRange(location:0,length:1)), first.width < 40, first.height < 40 {
            ready = node; break
        }
    } while Date() < deadline
    do {
        guard let node = ready, let text = query(node,"AXValue") as? String else {
            evidence["waitedSeconds"] = Date().timeIntervalSince(started)
            evidence["statesAfterEnable"] = Dictionary(uniqueKeysWithValues:["AXManualAccessibility","AXEnhancedUserInterface"].map { ($0,String(describing:query(app,$0))) })
            evidence["status"] = "geometry_unavailable"
            try JSONSerialization.data(withJSONObject:evidence,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
            print("Geometry unavailable: \(mode)")
            return
        }
        evidence["statesAfterEnable"] = Dictionary(uniqueKeysWithValues:["AXManualAccessibility","AXEnhancedUserInterface"].map { ($0,String(describing:query(app,$0))) })
        evidence["readyAfterSeconds"] = Date().timeIntervalSince(started)
        evidence["attributeAfterEnable"] = String(describing:query(app,"AXEnhancedUserInterface"))
        var offset = 0, groups: [(Int,Int,CGRect)] = [], characters: [[String:Any]] = []
        let collectStarted = Date()
        for scalar in text.unicodeScalars {
            let length = scalar.value > 0xffff ? 2 : 1
            guard let b = box(node,CFRange(location:offset,length:length)) else {
                throw NSError(domain:"Missing character bounds",code:offset)
            }
            characters.append(["start":offset,"length":length,"box":rect(b)])
            if let last = groups.last, abs(last.2.minY-b.minY) <= 1, abs(last.2.height-b.height) <= 1 {
                groups[groups.count-1] = (last.0,last.1+length,last.2.union(b))
            } else { groups.append((offset,length,b)) }
            offset += length
        }
        evidence["rangeCollectionSeconds"] = Date().timeIntervalSince(collectStarted)
        guard groups.count > 1, offset == (text as NSString).length else { throw NSError(domain:"Not a wrapped paragraph",code:1) }
        evidence["text"] = text; evidence["characters"] = characters
        evidence["lines"] = groups.map { start,length,b in
            ["start":start,"length":length,"text":(text as NSString).substring(with:NSRange(location:start,length:length)),"box":rect(b)] as [String:Any]
        }
        // These are inferred visual lines from exact character geometry; no OCR,
        // DOM, guessed font metrics, marker decoding or private C symbols used.
        evidence["method"] = "\(mode) activation + AXStaticText.AXBoundsForRange per Unicode scalar; group consecutive equal-y/equal-height boxes"
    } catch {
        AXUIElementSetAttributeValue(app,"AXEnhancedUserInterface" as CFString,previous)
        throw error
    }
    for (key,value) in zip(keys,originals) { if let value { AXUIElementSetAttributeValue(app,key as CFString,value) } }
    evidence["statesAfterRestore"] = Dictionary(uniqueKeysWithValues:["AXManualAccessibility","AXEnhancedUserInterface"].map { ($0,String(describing:query(app,$0))) })
    evidence["status"] = "collected"
    evidence["attributeAfterRestore"] = String(describing:query(app,"AXEnhancedUserInterface"))
    try JSONSerialization.data(withJSONObject:evidence,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
    print("Saved paragraph line evidence: \(CommandLine.arguments[1])")
}
do { try run() } catch { fputs("\(error)\n",stderr); exit(1) }
