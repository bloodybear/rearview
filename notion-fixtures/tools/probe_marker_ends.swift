// Research only: compare node-end/line-end ranges without decoding marker bytes.
import AppKit
import ApplicationServices

var events: [[String: Any]] = []
func q(_ node: AXUIElement, _ key: String, _ input: CFTypeRef? = nil) -> CFTypeRef? {
    var value: CFTypeRef?
    let error = input.map { AXUIElementCopyParameterizedAttributeValue(node, key as CFString, $0, &value) }
        ?? AXUIElementCopyAttributeValue(node, key as CFString, &value)
    events.append(["attribute": key, "error": error.rawValue, "output": String(describing: value)])
    return error == .success ? value : nil
}
func box(_ value: CFTypeRef?) -> [String: Double]? {
    guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    var r = CGRect.zero
    guard AXValueGetValue(value as! AXValue, .cgRect, &r) else { return nil }
    return ["x": r.minX, "y": r.minY, "width": r.width, "height": r.height]
}
func run() throws {
    guard CommandLine.arguments.count == 2, AXIsProcessTrusted(),
          let process = NSRunningApplication.runningApplications(withBundleIdentifier: "notion.id").first else {
        throw NSError(domain: "probe_marker_ends OUTPUT.json requires Notion and AX permission", code: 1)
    }
    let app = AXUIElementCreateApplication(process.processIdentifier)
    AXUIElementSetMessagingTimeout(app, 0.35)
    let prior = q(app, "AXManualAccessibility")
    defer { if let prior { AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, prior) } }
    let activation = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    Thread.sleep(forTimeInterval: 2.5)
    var stack = [app], nodes = 0, results: [[String: Any]] = []
    let deadline = Date().addingTimeInterval(15)
    while let node = stack.popLast(), nodes < 3500, Date() < deadline {
        nodes += 1
        let role = q(node, "AXRole") as? String
        let text = q(node, "AXValue") as? String ?? ""
        if role == "AXStaticText", !text.isEmpty,
           text == "この機能は" || text == "📌" || text.hasPrefix("この依頼は、申請者が") || text.hasPrefix("申請は受け付けましたが、") {
            events = []
            var item: [String: Any] = ["text": text]
            if let whole = q(node, "AXTextMarkerRangeForUIElement", node), CFGetTypeID(whole) == AXTextMarkerRangeGetTypeID() {
                let whole = whole as! AXTextMarkerRange
                var start = AXTextMarkerRangeCopyStartMarker(whole)
                // Local SDK helper: no extra AX IPC to obtain the node end.
                let nodeEnd = AXTextMarkerRangeCopyEndMarker(whole)
                item["nodeString"] = q(node, "AXStringForTextMarkerRange", whole) as? String
                item["nodeLength"] = q(node, "AXLengthForTextMarkerRange", whole) as? NSNumber
                item["nodeEndIndex"] = q(node, "AXIndexForTextMarker", nodeEnd) as? NSNumber
                var lines: [[String: Any]] = [], offset = 0
                while offset < (text as NSString).length, lines.count < 128 {
                    guard let rawEnd = q(node, "AXNextLineEndTextMarkerForTextMarker", start), CFGetTypeID(rawEnd) == AXTextMarkerGetTypeID() else { break }
                    var end = rawEnd as! AXTextMarker
                    var range = AXTextMarkerRangeCreate(nil, start, end)
                    let rawString = q(node, "AXStringForTextMarkerRange", range) as? String
                    let length = q(node, "AXLengthForTextMarkerRange", range) as? NSNumber
                    let endIndex = q(node, "AXIndexForTextMarker", end) as? NSNumber
                    let remaining = (text as NSString).substring(from: offset)
                    var clipped = false
                    // Probe both representations; accept a clamp only if the resulting
                    // source slice verifies exactly. This is not a character fallback.
                    if let rawString, (rawString as NSString).length > (remaining as NSString).length, rawString.hasPrefix(remaining) {
                        end = nodeEnd; range = AXTextMarkerRangeCreate(nil, start, end); clipped = true
                    }
                    let string = clipped ? q(node, "AXStringForTextMarkerRange", range) as? String : rawString
                    var line: [String: Any] = ["rawLineString": rawString as Any? ?? NSNull(), "clampedToNodeEnd": clipped,
                                               "rawRangeLength": length as Any? ?? NSNull(), "lineEndIndex": endIndex as Any? ?? NSNull()]
                    guard let string, !string.isEmpty, remaining.hasPrefix(string) else {
                        line["status"] = "string_mismatch_or_unavailable"; lines.append(line); break
                    }
                    line["text"] = string; line["rangeStart"] = offset; line["rangeLength"] = (string as NSString).length
                    line["box"] = box(q(node, "AXBoundsForTextMarkerRange", range)) as Any? ?? NSNull()
                    line["status"] = "verified_string"
                    lines.append(line); offset += (string as NSString).length; start = end
                }
                item["coveredUTF16Length"] = offset
                item["complete"] = offset == (text as NSString).length
                item["lines"] = lines
            }
            item["trace"] = events; results.append(item)
        }
        stack += q(node, "AXChildren") as? [AXUIElement] ?? []
    }
    let data: [String: Any] = ["activation": "manual", "activationError": activation.rawValue, "nodesScanned": nodes,
                              "truncated": !stack.isEmpty, "results": results]
    try JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
}
do { try run() } catch { fputs("\(error)\n", stderr); exit(1) }
