import Foundation

struct DiagnosticOCRBatch: Encodable {
    struct Line: Codable {
        let id: UUID
        let source: String
        let box: CGRect
        let confidence: Float
        let sourceLanguage: Bool
        let fragments: [RecognizedTextFragment]
        let background, foreground: RGBAColor
    }
    let batch: OCRService.RecognitionBatch
    let mode: OCRMode
    let roi: CGRect?
    let direction: TranslationDirection
    init(_ batch:OCRService.RecognitionBatch,mode:OCRMode,roi:CGRect?,direction:TranslationDirection) {
        self.batch=batch;self.mode=mode;self.roi=roi;self.direction=direction
    }
    enum Keys:String,CodingKey { case mode,roi,rawObservations,missingCandidates,lines,rejected,debug }
    func encode(to encoder:any Encoder) throws {
        var c=encoder.container(keyedBy:Keys.self)
        try c.encode(mode.rawValue,forKey:.mode);try c.encodeIfPresent(roi,forKey:.roi)
        try c.encode(batch.rawObservationCount,forKey:.rawObservations);try c.encode(batch.missingCandidateCount,forKey:.missingCandidates)
        let lines=batch.lines.map { Line(id:$0.id,source:$0.sourceText,box:$0.normalizedRect,confidence:$0.confidence,
            sourceLanguage:LanguageProtector.containsSourceLanguage($0.sourceText,direction:direction),
            fragments:$0.selectionFragments.isEmpty ? $0.selectionGeometrySource?.fragments() ?? [] : $0.selectionFragments,
            background:$0.background,foreground:$0.foreground) }
        try c.encode(lines,forKey:.lines);try c.encode(batch.confidenceRejected,forKey:.rejected);try c.encode(batch.debugItems,forKey:.debug)
    }
}
