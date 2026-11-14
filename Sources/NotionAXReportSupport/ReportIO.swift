import AppKit
import NotionAXCore

// Replay/files/screenshots are adapters, never inputs to the product extractor.
public struct AXReportInput {
    public let root: URL
    public let runID: String
    public let request: AXExtractionRequest
    public init(arguments: [String]) throws {
        func option(_ name: String) throws -> String {
            guard let i = arguments.firstIndex(of:name), i+1 < arguments.count else { throw CocoaError(.fileReadInvalidFileName) }
            return arguments[i+1]
        }
        root = URL(fileURLWithPath:try option("--root")); runID = try option("--run-id")
        guard !runID.contains("/"), runID != ".." else { throw CocoaError(.fileReadInvalidFileName) }
        let result = try JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("runs/\(runID)/result.json"))) as! [String:Any]
        let steps = result["steps"] as? [[String:Any]] ?? []
        guard ["verified","partial"].contains(result["status"] as? String ?? ""), steps.allSatisfy({$0["status"] as? String == "verified" || ($0["item"] as? String == "zoom" && $0["status"] as? String == "unsupported")}),
              let screenshot = result["screenshot"] as? [String:Any], let f = screenshot["frame"],
              let process = NSRunningApplication.runningApplications(withBundleIdentifier:"notion.id").first else { throw AXExtractionError.targetTerminated }
        func rect(_ value: Any) -> CGRect {
            let r = value as! [String:Double]
            return CGRect(x:r["x"]!,y:r["y"]!,width:r["width"]!,height:r["height"]!)
        }
        let frame = rect(f)
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements],kCGNullWindowID) as? [[String:Any]] ?? []
        let matches = windows.filter {
            guard ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == process.processIdentifier,
                  let bounds = $0[kCGWindowBounds as String] as? [String:Any], let r = CGRect(dictionaryRepresentation:bounds as CFDictionary) else { return false }
            return abs(r.minX-frame.minX)<2 && abs(r.minY-frame.minY)<2 && abs(r.width-frame.width)<2 && abs(r.height-frame.height)<2
        }
        guard matches.count == 1, let id = matches[0][kCGWindowNumber as String] as? NSNumber else { throw AXExtractionError.windowMappingFailed }
        let geometry = result["observedGeometry"] as? [String:Any] ?? [:]
        request = AXExtractionRequest(processID:process.processIdentifier, windowID:id.uint32Value, windowFrame:frame,
            selectionRegion:geometry["captureRegion"].map(rect) ?? screenshot["viewport"].map(rect) ?? frame, collectParentTextDiagnostics:CommandLine.arguments.contains("--ax-collect-parent-values"))
    }
    public func write(_ snapshot: AXExtractionSnapshot, collector: String, frameID: UInt64? = nil, sessionCollections: [[String:Any]] = []) throws -> URL {
        let output = root.appendingPathComponent("evaluations/\(runID)/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        try snapshot.nodes.write(to:output.appendingPathComponent("rawAx.json"))
        try snapshot.selected.write(to:output.appendingPathComponent("candidate.json"))
        try snapshot.paragraphs.write(to:output.appendingPathComponent("native-paragraphs.json"))
        var metadata = try JSONSerialization.jsonObject(with:snapshot.metadata) as! [String:Any]
        metadata["sessionCollections"] = sessionCollections
        metadata["runId"] = runID; metadata["collector"] = collector
        metadata["screenshotSource"] = "post_collection_window_screencapture"
        metadata["screenshotStartedAt"] = ISO8601DateFormatter().string(from:Date())
        metadata["frameID"] = frameID
        func verifyWindow() throws {
            let windows = CGWindowListCopyWindowInfo([.optionIncludingWindow],request.windowID) as? [[String:Any]] ?? []
            guard windows.contains(where: {
                guard ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == request.windowID,
                      ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == request.processID,
                      let bounds = $0[kCGWindowBounds as String] as? [String:Any],
                      let f = CGRect(dictionaryRepresentation:bounds as CFDictionary) else { return false }
                let expected = request.windowFrame
                return abs(f.minX-expected.minX)<2 && abs(f.minY-expected.minY)<2 && abs(f.width-expected.width)<2 && abs(f.height-expected.height)<2
            }) else { throw AXExtractionError.windowChanged }
        }
        try verifyWindow()
        let task = Process(); task.executableURL = URL(fileURLWithPath:"/usr/sbin/screencapture")
        task.arguments = ["-x","-o","-l",String(request.windowID),output.appendingPathComponent("screen.png").path]
        try task.run(); task.waitUntilExit()
        guard task.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
        try verifyWindow()
        if let image = NSImage(contentsOf:output.appendingPathComponent("screen.png")), let rep = image.representations.first {
            metadata["pixelsPerPointX"] = Double(rep.pixelsWide)/request.windowFrame.width
            metadata["pixelsPerPointY"] = Double(rep.pixelsHigh)/request.windowFrame.height
        }
        metadata["screenshotFinishedAt"] = ISO8601DateFormatter().string(from:Date())
        try JSONSerialization.data(withJSONObject:metadata,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("metadata.json"))
        return output
    }
}
