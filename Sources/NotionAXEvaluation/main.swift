import AppKit
import ApplicationServices
import NotionScenarioCore

func get(_ e: AXUIElement, _ key: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(e, key as CFString, &value) == .success ? value : nil
}
func frame(_ e: AXUIElement) -> CGRect? {
    guard let p = get(e, "AXPosition"), let s = get(e, "AXSize"), CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
    var point = CGPoint.zero, size = CGSize.zero
    guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
    return CGRect(origin: point, size: size)
}
// Product policy, not proof of invisibility: Chromium can clamp fully clipped
// nodes to a 1-unit edge rectangle. Even a genuinely visible <=1pt text sliver
// is not useful translation input. Filter using the already-read frame to avoid
// additional cross-process AX range queries. Units are screen points (1pt = 2px
// on a 2x display), not pixels. Revisit this threshold if tiny fragments become
// useful; preserve the raw node and exclusion reason for that investigation.
// Rationale: https://github.com/chromium/chromium/blob/main/docs/accessibility/browser/offscreen.md
let minimumUsefulTextExtent: CGFloat = 1
func isTinyTextFrame(_ frame: CGRect) -> Bool {
    frame.width <= minimumUsefulTextExtent || frame.height <= minimumUsefulTextExtent
}

func rect(_ r: CGRect) -> [String: Double] { ["x":r.minX,"y":r.minY,"width":r.width,"height":r.height] }
func escape(_ s: String) -> String { s.replacingOccurrences(of:"&",with:"&amp;").replacingOccurrences(of:"<",with:"&lt;").replacingOccurrences(of:"\"",with:"&quot;") }
func save(_ value: Any, _ url: URL) throws { try JSONSerialization.data(withJSONObject:value, options:[.prettyPrinted,.sortedKeys]).write(to:url) }
func run() throws {
    let args = Array(CommandLine.arguments.dropFirst())
    func option(_ name: String) throws -> String { guard let i = args.firstIndex(of:name), i+1 < args.count else { throw NSError(domain:"Missing \(name)",code:1) }; return args[i+1] }
    guard args.first == "collect" else { throw NSError(domain:"Usage: collect --root PATH --run-id ID",code:1) }
    let root = URL(fileURLWithPath:try option("--root")), id = try option("--run-id")
    guard !id.contains("/"), id != ".." else { throw NSError(domain:"Invalid run ID",code:1) }
    let source = root.appendingPathComponent("runs/\(id)")
    let decoder = JSONDecoder()
    let result = try decoder.decode(RunResult.self, from:Data(contentsOf:source.appendingPathComponent("result.json")))
    let request = try decoder.decode(RunRequest.self, from:Data(contentsOf:source.appendingPathComponent("request.json")))
    guard ["layout-wrap-1024-closed","layout-wrap-640-closed"].contains(result.scenarioId), let capture = result.screenshot,
          result.status == "verified" || (result.status == "partial" && result.steps.filter({$0.status != "verified"}).allSatisfy({$0.item == "zoom" && $0.status == "unsupported"})) else { throw NSError(domain:"Ineligible replay",code:1) }
    guard AXIsProcessTrusted(), let process = NSRunningApplication.runningApplications(withBundleIdentifier:"notion.id").first else { throw NSError(domain:"Accessibility permission or Notion unavailable",code:1) }
    let app = AXUIElementCreateApplication(process.processIdentifier)
    AXUIElementSetMessagingTimeout(app,0.35)
    guard let focused = get(app,"AXFocusedWindow") else { throw NSError(domain:"No focused window",code:1) }
    let window = focused as! AXUIElement
    guard let before = frame(window), Rect(before).near(capture.frame) else { throw NSError(domain:"Window changed",code:1) }
    let started = Date(), deadline = started.addingTimeInterval(15)
    var stack: [(AXUIElement,Int,Int?)] = [(window,0,nil)], seen: [AXUIElement] = [], rows: [[String:Any]] = [], candidates: [[String:Any]] = [], html = "", pageFound = false
    while let (node,depth,parent) = stack.popLast() {
        if rows.count >= 3500 || Date() > deadline { stack.append((node,depth,parent)); break }
        if seen.contains(where:{CFEqual($0,node)}) { continue }; seen.append(node)
        let n = rows.count
        let role = get(node,"AXRole") as? String ?? ""
        let value = get(node,"AXValue") as? String ?? "", title = get(node,"AXTitle") as? String ?? ""
        let url = String(describing:get(node,"AXURL") ?? "" as CFString).replacingOccurrences(of:"-",with:"").lowercased()
        if url.contains(request.pageId.replacingOccurrences(of:"-",with:"").lowercased()) { pageFound = true }
        var names: CFArray?; AXUIElementCopyAttributeNames(node,&names)
        var parameters: CFArray?; AXUIElementCopyParameterizedAttributeNames(node,&parameters)
        var row: [String:Any] = ["id":n,"role":role,"value":value,"title":title,"attributes":names as? [String] ?? [],"parameterizedAttributes":parameters as? [String] ?? []]
        if let parent { row["parent"] = parent }
        let nodeFrame = frame(node)
        let excludedTinyText = !value.isEmpty && nodeFrame.map(isTinyTextFrame) == true
        if excludedTinyText { row["exclusionReason"] = "text_extent_at_most_1pt" }
        if let f = nodeFrame {
            row["frame"] = rect(f)
            if role == "AXStaticText", !value.isEmpty, !excludedTinyText, f.intersects(capture.viewport?.cgRect ?? before) {
                candidates.append(["node":n,"text":value,"box":rect(f),"uncertainty":"Full AX value; glyph visibility unverified"])
                html += "<div class='box' style='left:\(f.minX-before.minX)px;top:\(f.minY-before.minY)px;width:\(f.width)px;height:\(f.height)px'><span class='number'>\(n)</span></div>"
            }
        }
        if !value.isEmpty && !excludedTinyText {
            var range = CFRange(location:0,length:(value as NSString).length)
            var bounds: CFTypeRef?
            let error = AXUIElementCopyParameterizedAttributeValue(node,"AXBoundsForRange" as CFString,AXValueCreate(.cfRange,&range)!,&bounds)
            row["boundsForFullRangeError"] = error.rawValue
            if let bounds, CFGetTypeID(bounds) == AXValueGetTypeID() { var r = CGRect.zero; if AXValueGetValue(bounds as! AXValue,.cgRect,&r) { row["boundsForFullRange"] = rect(r) } }
        }
        rows.append(row)
        let children = get(node,"AXChildren") as? [AXUIElement] ?? []
        if depth < 40 { stack.append(contentsOf:children.reversed().map{($0,depth+1,n)}) }
        else if !children.isEmpty { row["depthLimitReached"] = true; rows[n] = row }
    }
    let valid = pageFound && frame(window).map{Rect($0).near(Rect(before))} == true
    let output = root.appendingPathComponent("evaluations/\(id)/\(UUID().uuidString)")
    try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
    try FileManager.default.copyItem(at:source.appendingPathComponent(capture.file),to:output.appendingPathComponent("screen.png"))
    try save(rows,output.appendingPathComponent("rawAx.json")); try save(candidates,output.appendingPathComponent("candidate.json"))
    try save(["status":"comparison_unverified","targetAndFrameMatch":valid,"screenIdentity":"Not established; manual comparison required","truncated": !stack.isEmpty || rows.contains{$0["depthLimitReached"] as? Bool == true},"elapsed":Date().timeIntervalSince(started),"limits":["nodes":3500,"depth":40,"seconds":15],"runId":id] as [String:Any],output.appendingPathComponent("metadata.json"))
    let list = candidates.map{"<li>\($0["node"]!): \(escape($0["text"] as! String)) — AXValue; visibility unknown</li>"}.joined()
    let report = "<meta charset='utf-8'><style>.screen{position:relative}.box{position:absolute;border:1px solid red;color:blue;box-sizing:border-box;pointer-events:none}.number{position:absolute;left:0;top:0;z-index:2;background:white;color:#a00000;border:2px solid #a00000;border-radius:4px;padding:2px 5px;font:bold 18px/1.2 monospace;box-shadow:0 1px 4px #0008}</style><h1>AX prototype — comparison unverified</h1><p>Target/frame match: \(valid). Screen state identity requires manual review. Full strings and overlapping boxes are experimental; no accuracy verdict.</p><div class='screen' style='width:\(before.width)px;height:\(before.height)px'><img src='screen.png' style='width:100%;height:100%'>\(html)</div><ol>\(list)</ol><p>See rawAx.json for API support/errors and metadata.json for limits.</p>"
    try report.write(to:output.appendingPathComponent("index.html"),atomically:true,encoding:.utf8)
    print(output.path)
}
do { try run() } catch { fputs("\(error)\n",stderr); exit(1) }
