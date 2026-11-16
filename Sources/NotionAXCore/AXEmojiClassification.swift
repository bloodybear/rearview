import Foundation

package enum AXEmojiClassification {
    package static func isSingleEmoji(_ text: String) -> Bool {
        var iterator=text.makeIterator()
        guard let character=iterator.next(),iterator.next()==nil else{return false}
        let scalars=character.unicodeScalars
        if scalars.contains(where:{$0.value==0xFE0E}){return false}
        return scalars.contains{$0.properties.isEmojiPresentation} ||
            (scalars.contains{$0.value==0xFE0F || $0.value==0x20E3} && scalars.contains{$0.properties.isEmoji})
    }
}
