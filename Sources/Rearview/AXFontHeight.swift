import Foundation
import NotionAXCore

enum AXFontHeight {
    struct Decision: Codable { let originalHeight: Double; let selectedHeight: Double?; let nodeIDs: [Int]; let reason: String }
    static func emojiNode(_ text:String)->Bool {
        var iterator=text.makeIterator()
        guard let character=iterator.next(),iterator.next()==nil else{return false}
        let scalars=character.unicodeScalars
        if scalars.contains(where:{$0.value==0xFE0E}){return false}
        return scalars.contains{$0.properties.isEmojiPresentation} ||
            (scalars.contains{$0.value==0xFE0F || $0.value==0x20E3} && scalars.contains{$0.properties.isEmoji})
    }
    static func select(lines:[AXLine],source:String,ids:[Int],nodes:[Int:AXNode],clips:[CGRect],record: ((Decision)->Void)? = nil)->Double {
        let original=lines.map{$0.box.height}.min() ?? 0
        guard original>=8 else{return original}
        let records=ids.compactMap{nodes[$0]}
        let flags=records.map{emojiNode($0.recoveredText ?? $0.value)}
        guard flags.contains(true) else{return original}
        let texts=records.map{$0.recoveredText ?? $0.value}
        guard records.count==ids.count,texts.joined().utf16.elementsEqual(source.utf16) else{return original}
        var offset=0
        let spans=records.indices.map{i -> (Int,Int,AXNode,Bool,Bool) in
            let count=texts[i].utf16.count;defer{offset+=count}
            let visible=texts[i].unicodeScalars.contains{!CharacterSet.whitespacesAndNewlines.contains($0) && !$0.properties.isDefaultIgnorableCodePoint}
            return(offset,offset+count,records[i],flags[i],visible)
        }
        let native = source as NSString
        var heights:[Double]=[],cursor=0
        for line in lines {
            let start=line.rangeStart,end=start+line.rangeLength
            guard start>=0,line.rangeLength>0,end<=offset,native.substring(with:NSRange(location:start,length:line.rangeLength))==line.text else {
                heights.append(line.box.height)
                record?(.init(originalHeight:line.box.height,selectedHeight:line.box.height,nodeIDs:[],reason:"fallback_range_mismatch"));continue
            }
            while cursor<spans.count && spans[cursor].1<=start{cursor+=1}
            var i=cursor,hasEmoji=false,hasText=false,candidates:[Double]=[]
            var lineNodeIDs:[Int]=[]
            while i<spans.count && spans[i].0<end {
                let (a,b,node,emoji,visible)=spans[i];i+=1;lineNodeIDs.append(node.id)
                hasEmoji = hasEmoji || emoji
                if !emoji && visible {
                    hasText=true
                    guard a>=start,b<=end,let frame=node.frame?.cgRect,
                          [frame.minX,frame.minY,frame.width,frame.height].allSatisfy(\.isFinite),frame.width>1,frame.height>=8 else{continue}
                    let clipped=clips.contains{clip in
                        !clip.isNull && ((abs(frame.minY-clip.minY)<=1 && line.box.y<clip.minY-1) ||
                        (abs(frame.maxY-clip.maxY)<=1 && line.box.cgRect.maxY>clip.maxY+1))
                    }
                    if !clipped{candidates.append(Double(frame.height))}
                }
            }
            if !hasEmoji{heights.append(line.box.height)}
            else if hasText{heights.append(min(line.box.height,candidates.max() ?? line.box.height))}
            record?(.init(originalHeight:line.box.height,selectedHeight:hasEmoji && !hasText ? nil : heights.last,nodeIDs:lineNodeIDs,reason:!hasEmoji ? "native_line" : !hasText ? "emoji_only" : candidates.isEmpty ? "fallback_no_valid_node" : "max_text_node"))
        }
        return heights.min() ?? original
    }
}
