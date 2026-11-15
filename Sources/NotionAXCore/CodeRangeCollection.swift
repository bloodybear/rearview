import AppKit
import ApplicationServices

/// Uses leaf-local integer ranges; no marker bytes, per-character AX calls or box unions.
package enum AXCodeRangeCollection {
    static func collect(paragraph: [String:Any], rows: [[String:Any]], elements: [AXUIElement],
                        attributed: [Int:NSAttributedString], investigator: RangeInvestigator) -> [[String:Any]] {
        guard paragraph["inlineContent"] == nil,
              paragraph["lineRangeStatus"] as? String == "complete_unverified",
              let source = paragraph["lineSourceText"] as? String,
              let ids = paragraph["lineSourceNodes"] as? [Int], !ids.isEmpty else { return [] }
        let leaves = ids.map { ($0, (rows[$0]["recoveredText"] ?? rows[$0]["value"]) as? String ?? "") }
        guard leaves.map({ $0.1 }).joined().utf16.elementsEqual(source.utf16) else { return [] }
        let lines = paragraph["lineRanges"] as? [[String:Any]] ?? []
        let q = NativeParagraphLines.Queries(investigator)
        return AXCodeTextSegments.split(source).enumerated().map { index, segment in
            var pieces: [[String:Any]] = [], styles: [NSAttributedString] = []
            var base = 0
            for (id,text) in leaves {
                let leafRange = NSRange(location:base,length:text.utf16.count)
                defer { base += leafRange.length }
                let part = NSIntersectionRange(segment.range,leafRange)
                guard part.length > 0 else { continue }
                let local = NSRange(location:part.location-base,length:part.length)
                if let native = attributed[id], native.string.utf16.elementsEqual(text.utf16) {
                    styles.append(native.attributedSubstring(from:local))
                } else { styles.append(NSAttributedString(string:(source as NSString).substring(with:part))) }
                for line in lines {
                    guard let start = line["rangeStart"] as? Int, let length = line["rangeLength"] as? Int else { continue }
                    let overlap = NSIntersectionRange(part,NSRange(location:start,length:length))
                    guard overlap.length > 0 else { continue }
                    // Hard delimiters are selection text, never paint/geometry capacity.
                    let chunk = (source as NSString).substring(with:overlap)
                    for logical in AXLogicalLines.pieces(chunk) where logical.0.length > 0 {
                        let range = NSRange(location:overlap.location+logical.0.location,length:logical.0.length)
                        let value = (source as NSString).substring(with:range)
                        var row: [String:Any] = ["sourceNode":id,"rangeStart":range.location,"rangeLength":range.length,"text":value,"status":"bounds_unavailable"]
                        if range.location == start, range.length == length, let box = line["box"] as? [String:Double] {
                            row["box"]=box;row["status"]="complete";row["boundsSource"]="existing_native_line"
                            pieces.append(row);continue
                        }
                        var r = CFRange(location:range.location-base,length:range.length)
                        if let arg = AXValueCreate(.cfRange,&r), let raw = q.get(elements[id],"AXBoundsForRange",arg), CFGetTypeID(raw)==AXValueGetTypeID() {
                            var box = CGRect.zero
                            if AXValueGetValue(raw as! AXValue,.cgRect,&box), [box.minX,box.minY,box.width,box.height].allSatisfy({ $0.isFinite }),box.width>0,box.height>0 {
                                row["box"] = rect(box); row["status"] = "complete"
                            }
                        }
                        if row["box"] == nil && value.unicodeScalars.allSatisfy({ CharacterSet.whitespaces.contains($0) }) {
                            row["status"]="nonrendering_text"
                        }
                        pieces.append(row)
                    }
                }
            }
            let native = NSMutableAttributedString(string:"")
            styles.forEach { native.append($0) }
            var style: [String:Any] = ["foregroundColorStatus":"mixed_or_unavailable"]
            if let color = AXForegroundStyle.uniformColor(in:native,matching:segment.text) {
                style["foregroundColor"] = ["red":color.red,"green":color.green,"blue":color.blue,"alpha":color.alpha]
                style["foregroundColorStatus"] = "uniform"
            }
            for (name,key) in [("underline","AXUnderline"),("strikethrough","AXStrikethrough")] {
                var values: [Bool] = [], valid = true
                native.enumerateAttribute(NSAttributedString.Key(key),in:NSRange(location:0,length:native.length)) { value,_,_ in
                    if let n = value as? NSNumber { values.append(n.boolValue) } else { valid=false }
                }
                if valid,let first=values.first,values.allSatisfy({$0==first}) { style[name]=first }
            }
            var bold: [Bool] = [], italic: [Bool] = [], fontsValid = true
            native.enumerateAttribute(NSAttributedString.Key("AXFont"),in:NSRange(location:0,length:native.length)) { value,_,_ in
                guard let font = value as? [String:Any], let name = font["AXFontName"] as? String,
                      let nativeFont = NSFont(name:name,size:12) else { fontsValid=false;return }
                let traits = nativeFont.fontDescriptor.symbolicTraits
                bold.append(traits.contains(.bold));italic.append(traits.contains(.italic))
            }
            if fontsValid,let first=bold.first,bold.allSatisfy({$0==first}) { style["bold"]=first }
            if fontsValid,let first=italic.first,italic.allSatisfy({$0==first}) { style["italic"]=first }
            let meaningful = segment.text.trimmingCharacters(in:.whitespacesAndNewlines)
            let covered = pieces.reduce(0) { $0 + ($1["rangeLength"] as? Int ?? 0) }
            let expected = AXLogicalLines.pieces(segment.text).reduce(0) { $0+$1.0.length }
            let status = meaningful.isEmpty && pieces.isEmpty ? "nonrendering_text" :
                (covered==expected && pieces.allSatisfy({["complete","nonrendering_text"].contains($0["status"] as? String ?? "")}) ? "complete" : "partial")
            return ["id":index,"rangeStart":segment.range.location,"rangeLength":segment.range.length,
                    "text":segment.text,"translates":segment.translates,"pieces":pieces,"style":style,"status":status]
        }
    }
}
