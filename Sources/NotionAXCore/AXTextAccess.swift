import AppKit
import ApplicationServices

// Capture-scoped AX access shared by selection and opt-in research.
package class AXTextAccess {
    typealias Entry = [String: Any]
    var queryCount = 0
    var lastParameterizedResult: Int32?

    func attr(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
        if (Thread.current.threadDictionary["rearview.ax.cancellation"] as? AXCancellation)?.isCancelled == true { return nil }
        recordAXQuery()
        queryCount += 1
        var value: CFTypeRef?
        let result=AXUIElementCopyAttributeValue(e, name as CFString, &value)
        recordAXResult(name,result)
        return result == .success ? value : nil
    }

    func param(_ e: AXUIElement, _ name: String, _ input: CFTypeRef) -> CFTypeRef? {
        lastParameterizedResult = nil
        if (Thread.current.threadDictionary["rearview.ax.cancellation"] as? AXCancellation)?.isCancelled == true { return nil }
        recordAXQuery()
        queryCount += 1
        var value: CFTypeRef?
        let result = AXUIElementCopyParameterizedAttributeValue(e, name as CFString, input, &value)
        lastParameterizedResult = result.rawValue
        recordAXResult(name,result)
        return result == .success ? value : nil
    }

    func asElement(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    func asRect(_ value: CFTypeRef?) -> CGRect? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        return AXValueGetValue(value as! AXValue, .cgRect, &rect) ? rect : nil
    }

    func rectArray(_ rect: CGRect?) -> [CGFloat] {
        guard let rect, [rect.minX,rect.minY,rect.width,rect.height].allSatisfy(\.isFinite) else { return [] }
        return [rect.minX,rect.minY,rect.width,rect.height]
    }

    func many(_ element: AXUIElement, _ names: [String]) -> Entry {
        if (Thread.current.threadDictionary["rearview.ax.cancellation"] as? AXCancellation)?.isCancelled == true { return [:] }
        recordAXQuery()
        queryCount += 1
        var raw: CFArray?
        let result=AXUIElementCopyMultipleAttributeValues(element, names as CFArray, [], &raw)
        recordAXResult("multipleAttributes",result)
        guard result == .success,
              let values = raw as? [Any] else { return [:] }
        return Dictionary(uniqueKeysWithValues: zip(names, values))
    }

    func sameMarkerBytes(_ first: AXTextMarker, _ second: AXTextMarker) -> Bool {
        let length = AXTextMarkerGetLength(first)
        guard length == AXTextMarkerGetLength(second) else { return false }
        let firstBytes = UnsafeBufferPointer(start: AXTextMarkerGetBytePtr(first), count: length)
        let secondBytes = UnsafeBufferPointer(start: AXTextMarkerGetBytePtr(second), count: length)
        return firstBytes.elementsEqual(secondBytes)
    }

    func endpoints(_ raw: CFTypeRef?) -> [(String, CFTypeRef)] {
        guard let raw else { return [] }
        if CFGetTypeID(raw) == AXTextMarkerGetTypeID() { return [("",raw)] }
        guard CFGetTypeID(raw) == AXTextMarkerRangeGetTypeID() else { return [] }
        let range = raw as! AXTextMarkerRange
        return [(".start", AXTextMarkerRangeCopyStartMarker(range)), (".end", AXTextMarkerRangeCopyEndMarker(range))]
    }

    // Chromium 156 only. Read the serialized children and label relations to
    // determine whether a text node exists underneath macOS AX's platform tree.
    // This diagnostic follows reported live child IDs within the current tree.
    func internalTree(_ origin: AXUIElement, _ rootMarker: CFTypeRef, _ rootDescription: String,
                      lookup: (AXUIElement) -> Entry) -> (nodes: [Entry], complete: Bool, diagnostics: Entry) {
        guard CFGetTypeID(rootMarker) == AXTextMarkerGetTypeID() else { return ([], false, ["reasons":["unsupported_marker_format"]]) }
        let marker = rootMarker as! AXTextMarker
        let length = AXTextMarkerGetLength(marker)
        let parts = rootDescription.split(separator: " ", maxSplits: 2)
        guard length == 56, parts.count >= 2, parts[0].hasPrefix("id="),
              let ownID = Int32(parts[0].dropFirst(3)) else { return ([], false, ["reasons":["unsupported_marker_format"]]) }
        let bytes = AXTextMarkerGetBytePtr(marker)
        let raw = UnsafeRawBufferPointer(start: bytes, count: length)
        guard raw.loadUnaligned(fromByteOffset:0,as:Int32.self) == 2,
              raw.loadUnaligned(fromByteOffset:4,as:Int32.self) == ownID,
              raw.loadUnaligned(fromByteOffset:8,as:Int32.self) == -2,
              raw.loadUnaligned(fromByteOffset:12,as:Int32.self) == 0,
              raw.loadUnaligned(fromByteOffset:16,as:Int32.self) == 1,
              raw[52] == 0, raw[20..<52].allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) })
        else { return ([], false, ["reasons":["unsupported_marker_format"]]) }

        func ids(_ description: String, _ field: String) -> [Int32] {
            guard let match = description.range(of: " " + field + "=") else { return [] }
            return description[match.upperBound...].prefix { $0 == "-" || $0 == "," || $0.isASCII && $0.isNumber }
                .split(separator:",").compactMap { Int32($0) }.filter { $0 != 0 }
        }

        func branches(_ description: String, _ depth: Int, _ inherited: String) -> [(Int32, Int, String)] {
            ids(description, "labelledby_ids").map { ($0, depth, "labelledby") } +
            ids(description, "child_ids").map { ($0, depth, inherited) }
        }

        var pending = branches(rootDescription, 1, "child")
        var read = Set([ownID]), found: [Entry] = []
        var incomplete = false
        var issues: [Entry] = []
        var maximumDepth = 0
        while !pending.isEmpty, read.count <= 64 {
            let (id, depth, relation) = pending.removeFirst()
            guard read.insert(id).inserted else { continue }
            maximumDepth = max(maximumDepth, depth)
            var copied = Array(raw)
            let childBytes = withUnsafeBytes(of:id.littleEndian) { Array($0) }
            copied.replaceSubrange(4..<8,with:childBytes)
            let child = copied.withUnsafeBufferPointer({ AXTextMarkerCreate(nil, $0.baseAddress!, length) })
            let descriptionResult = param(origin,"AXTextMarkerNodeDebugDescription",child) as? String
            guard let description = descriptionResult, description.hasPrefix("id=\(id) ") else {
                issues.append(["reason":descriptionResult == nil ? "description_unavailable" : "description_id_mismatch", "id":id, "depth":depth, "response":descriptionResult ?? "", "axResult":lastParameterizedResult.map { String($0) } ?? "not_called"])
                incomplete = true
                continue
            }
            var row: Entry = ["id":id,"depth":depth,"relation":relation,"description":description]
            if description.hasPrefix("id=\(id) staticText"),
               let element = asElement(param(origin,"AXUIElementForTextMarker",child)) {
                row["node"] = lookup(element)
            }
            found.append(row)
            if !description.hasPrefix("id=\(id) staticText") {
                let children = branches(description, depth + 1, relation)
                if depth < 16 { pending += children }
                else if !children.isEmpty {
                    incomplete = true
                    issues.append(["reason":"depth_limit", "id":id, "depth":depth, "pendingChildIDs":children.map { $0.0 }])
                }
            }
        }
        if !pending.isEmpty { issues.append(["reason":"node_limit"]) }
        return (found, pending.isEmpty && !incomplete, [
            "reasons":Array(Set(issues.compactMap { $0["reason"] as? String })).sorted(),
            "issues":issues, "visitedNodes":read.count, "maximumDepth":maximumDepth,
            "pendingNodeIDs":pending.map { $0.0 }, "nodeLimit":64, "depthLimit":16,
            "rootDescription":rootDescription, "nodes":found])
    }

}
