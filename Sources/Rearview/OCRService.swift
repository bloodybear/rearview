import AppKit
import Vision

enum OCRMode: String, Codable, Sendable {
    case realtime
    case refinement
}

enum OCRRecognitionPolicy {
    static let minimumConfidenceKey = "ocr.filter.minimumConfidence"
    static let defaultMinimumConfidence = AppDefaults.ocrMinimumConfidence
    static let minimumConfidenceRange: ClosedRange<Float> = 0...1

    static var minimumConfidence: Float { load() }

    static func load(from defaults: UserDefaults = .standard) -> Float {
        guard defaults.object(forKey: minimumConfidenceKey) != nil else {
            return defaultMinimumConfidence
        }
        return clamp(defaults.float(forKey: minimumConfidenceKey))
    }

    static func save(_ confidence: Float, to defaults: UserDefaults = .standard) {
        defaults.set(clamp(confidence), forKey: minimumConfidenceKey)
    }

    static func clamp(_ confidence: Float) -> Float {
        min(minimumConfidenceRange.upperBound, max(minimumConfidenceRange.lowerBound, confidence))
    }

    static func accepts(
        text: String, confidence: Float, visionLanguages: [Locale.Language]? = nil,
        minimumConfidence: Float? = nil,
        direction: TranslationDirection = .japaneseToKorean
    ) -> Bool {
        confidence >= (minimumConfidence ?? Self.minimumConfidence)
            || LanguageProtector.containsSourceLanguage(
                text, direction: direction, visionLanguages: visionLanguages
            )
    }
}

final class OCRService: @unchecked Sendable {
    private struct CandidateValue: Sendable {
        let text: String
        let confidence: Float
    }

    private struct ParsedObservation: Sendable {
        let normalizedRect: CGRect
        let recognitionLanguages: [Locale.Language]
        let candidates: [CandidateValue]
        let selectionGeometrySource: OCRSelectionGeometrySource?
    }

    struct RejectedCandidate: Sendable {
        struct Alternative: Sendable {
            let text: String
            let confidence: Float
        }
        let text: String
        let normalizedRect: CGRect
        let confidence: Float
        let alternatives: [Alternative]
    }

    struct RecognitionBatch: Sendable {
        let lines: [RecognizedLine]
        let debugItems: [OCRDebugItem]
        let rawObservationCount: Int
        let missingCandidateCount: Int
        let confidenceRejected: [RejectedCandidate]
    }

    func recognize(
        image: CGImage, mode: OCRMode, regionOfInterest: CGRect? = nil,
        includeRejectedAlternatives: Bool = false,
        settings: OCRSettings? = nil,
        direction: TranslationDirection = .japaneseToKorean
    ) async throws -> RecognitionBatch {
        let effectiveSettings = settings ?? OCRSettings.defaultProfile(for: mode)
        if effectiveSettings.engine == .document {
            if #available(macOS 26.0, *) {
                return try await recognizeDocument(
                    image: image,
                    regionOfInterest: regionOfInterest,
                    includeRejectedAlternatives: includeRejectedAlternatives,
                    settings: effectiveSettings, direction: direction
                )
            }
        }
        return try await recognizeText(
            image: image,
            regionOfInterest: regionOfInterest,
            includeRejectedAlternatives: includeRejectedAlternatives,
            settings: effectiveSettings, direction: direction
        )
    }

    private func recognizeText(
        image: CGImage, regionOfInterest: CGRect?,
        includeRejectedAlternatives: Bool, settings: OCRSettings,
        direction: TranslationDirection
    ) async throws -> RecognitionBatch {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                autoreleasepool {
                let preparedImage = self.scaledImage(image, by: settings.imageScale)
                let request = VNRecognizeTextRequest { request, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
                    let candidateLimit = includeRejectedAlternatives ? 10 : 1
                    let parsed = observations.map { observation in
                        let candidates = observation.topCandidates(candidateLimit)
                        return ParsedObservation(
                            normalizedRect: observation.boundingBox,
                            recognitionLanguages: self.recognizedLanguages(for: observation),
                            candidates: candidates.map {
                                CandidateValue(text: $0.string, confidence: $0.confidence)
                            },
                            selectionGeometrySource: candidates.first.map {
                                OCRSelectionGeometrySource(
                                    candidate: $0, fallbackRect: observation.boundingBox
                                )
                            }
                        )
                    }
                    continuation.resume(returning: self.makeBatch(
                        observations: parsed, image: image, direction: direction
                    ))
                }
                request.recognitionLevel = .accurate
                request.revision = VNRecognizeTextRequest.currentRevision
                // Vision applies one dominant language model to an observation. The
                // user can choose either supported ordering, or let Vision decide.
                if let languages = OCRRecognitionLanguageChoice.load().languages {
                    request.recognitionLanguages = languages
                }
                request.automaticallyDetectsLanguage = settings.automaticallyDetectsLanguage
                request.usesLanguageCorrection = settings.usesLanguageCorrection
                request.minimumTextHeight = settings.minimumTextHeight
                if let regionOfInterest { request.regionOfInterest = regionOfInterest }
                do {
                    try VNImageRequestHandler(cgImage: preparedImage, options: [:]).perform([request])
                } catch {
                    continuation.resume(throwing: error)
                }
                }
            }
        }
    }

    @available(macOS 26.0, *)
    private func recognizeDocument(
        image: CGImage, regionOfInterest: CGRect?,
        includeRejectedAlternatives: Bool, settings: OCRSettings,
        direction: TranslationDirection
    ) async throws -> RecognitionBatch {
        let preparedImage = scaledImage(image, by: settings.imageScale)
        var request = RecognizeDocumentsRequest()
        request.textRecognitionOptions.minimumTextHeightFraction = settings.minimumTextHeight
        request.textRecognitionOptions.automaticallyDetectLanguage =
            settings.automaticallyDetectsLanguage
        request.textRecognitionOptions.useLanguageCorrection = settings.usesLanguageCorrection
        request.textRecognitionOptions.maximumCandidateCount =
            includeRejectedAlternatives ? 10 : 1
        request.textRecognitionOptions.recognitionLanguages =
            (OCRRecognitionLanguageChoice.load().languages ?? []).map {
                Locale.Language(identifier: $0)
            }
        request.barcodeDetectionOptions.enabled = false
        if let regionOfInterest {
            request.regionOfInterest = NormalizedRect(normalizedRect: regionOfInterest)
        }
        let documents = try await request.perform(on: preparedImage)
        let observations = documents.flatMap(\.document.text.lines)
        let candidateLimit = includeRejectedAlternatives ? 10 : 1
        let parsed = observations.map { observation in
            let candidates = observation.topCandidates(candidateLimit)
            let rect = observation.boundingBox.cgRect
            return ParsedObservation(
                normalizedRect: rect,
                recognitionLanguages: observation.recognitionLanguages,
                candidates: candidates.map {
                    CandidateValue(text: $0.string, confidence: $0.confidence)
                },
                selectionGeometrySource: candidates.first.map {
                    OCRSelectionGeometrySource(candidate: $0, fallbackRect: rect)
                }
            )
        }
        return makeBatch(observations: parsed, image: image, direction: direction)
    }

    private func makeBatch(
        observations: [ParsedObservation], image: CGImage,
        direction: TranslationDirection = .japaneseToKorean
    ) -> RecognitionBatch {
        var lines: [RecognizedLine] = []
        var debugItems: [OCRDebugItem] = []
        var missingCandidateCount = 0
        var confidenceRejected: [RejectedCandidate] = []
        let minimumConfidence = OCRRecognitionPolicy.minimumConfidence
        for observation in observations {
            let visionLanguages = observation.recognitionLanguages
            let languageIdentifiers = visionLanguages.compactMap {
                $0.languageCode?.identifier
            }
            guard let candidate = observation.candidates.first else {
                missingCandidateCount += 1
                debugItems.append(OCRDebugItem(
                    id: UUID(), status: .noCandidate, rawText: nil,
                    confidence: nil, recognitionLanguages: languageIdentifiers,
                    normalizedRect: observation.normalizedRect
                ))
                continue
            }
            guard OCRRecognitionPolicy.accepts(
                text: candidate.text, confidence: candidate.confidence,
                visionLanguages: visionLanguages,
                minimumConfidence: minimumConfidence, direction: direction
            ) else {
                confidenceRejected.append(RejectedCandidate(
                    text: candidate.text,
                    normalizedRect: observation.normalizedRect,
                    confidence: candidate.confidence,
                    alternatives: observation.candidates.dropFirst().map {
                        RejectedCandidate.Alternative(
                            text: $0.text, confidence: $0.confidence
                        )
                    }
                ))
                debugItems.append(OCRDebugItem(
                    id: UUID(), status: .lowConfidence, rawText: candidate.text,
                    confidence: candidate.confidence,
                    recognitionLanguages: languageIdentifiers,
                    normalizedRect: observation.normalizedRect
                ))
                continue
            }
            let isSourceLanguage = LanguageProtector.containsSourceLanguage(
                candidate.text, direction: direction, visionLanguages: visionLanguages
            )
            let lineID = UUID()
            let colors = isSourceLanguage
                ? ColorSampler.colors(in: image, normalizedRect: observation.normalizedRect)
                : (.lightBackground, .darkText)
            lines.append(RecognizedLine(
                id: lineID,
                sourceText: candidate.text,
                normalizedRect: observation.normalizedRect,
                confidence: candidate.confidence,
                background: colors.background,
                foreground: colors.foreground,
                selectionGeometrySource: observation.selectionGeometrySource
            ))
            debugItems.append(OCRDebugItem(
                id: lineID,
                status: isSourceLanguage ? .translationPending : .nonJapanese,
                rawText: candidate.text,
                confidence: candidate.confidence,
                recognitionLanguages: languageIdentifiers,
                normalizedRect: observation.normalizedRect
            ))
        }
        return RecognitionBatch(
            lines: lines,
            debugItems: debugItems,
            rawObservationCount: observations.count,
            missingCandidateCount: missingCandidateCount,
            confidenceRejected: confidenceRejected
        )
    }

    private func recognizedLanguages(for observation: VNRecognizedTextObservation) -> [Locale.Language] {
        guard #available(macOS 26.0, *) else { return [] }
        return RecognizedTextObservation(observation).recognitionLanguages
    }

    private func scaledImage(_ image: CGImage, by scale: Float) -> CGImage {
        guard scale > 1.001 else { return image }
        let width = max(1, Int((CGFloat(image.width) * CGFloat(scale)).rounded()))
        let height = max(1, Int((CGFloat(image.height) * CGFloat(scale)).rounded()))
        guard let colorSpace = image.colorSpace,
              let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: image.bitsPerComponent,
                                      bytesPerRow: 0, space: colorSpace,
                                      bitmapInfo: image.bitmapInfo.rawValue) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

}

final class OCRSelectionGeometrySource: @unchecked Sendable {
    private let text: String
    private let boundingBoxProvider: (Range<String.Index>) -> CGRect?
    private let fallbackRect: CGRect
    private let lock = NSLock()
    private var cached: [RecognizedTextFragment]?

    init(candidate: VNRecognizedText, fallbackRect: CGRect) {
        text = candidate.string
        boundingBoxProvider = { range in
            (try? candidate.boundingBox(for: range))?.boundingBox
        }
        self.fallbackRect = fallbackRect
    }

    @available(macOS 15.0, *)
    init(candidate: RecognizedText, fallbackRect: CGRect) {
        text = candidate.string
        boundingBoxProvider = { range in
            candidate.boundingBox(for: range)?.boundingBox.cgRect
        }
        self.fallbackRect = fallbackRect
    }

    func fragments() -> [RecognizedTextFragment] {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        guard !text.isEmpty else { return [] }
        let characters = text.indices.map { index in
            (index, text.index(after: index), String(text[index]))
        }
        let count = CGFloat(characters.count)
        var fragments: [RecognizedTextFragment] = []
        fragments.reserveCapacity(characters.count)
        var start = 0
        while start < characters.count {
            let whitespace = characters[start].2.allSatisfy(\.isWhitespace)
            var end = start + 1
            while end < characters.count,
                  characters[end].2.allSatisfy(\.isWhitespace) == whitespace {
                end += 1
            }
            let range = characters[start].0..<characters[end - 1].1
            let runRect = boundingBoxProvider(range) ?? CGRect(
                x: fallbackRect.minX + fallbackRect.width * CGFloat(start) / count,
                y: fallbackRect.minY,
                width: fallbackRect.width * CGFloat(end - start) / count,
                height: fallbackRect.height
            )
            let characterWidth = runRect.width / CGFloat(end - start)
            for offset in start..<end {
                fragments.append(RecognizedTextFragment(
                    text: characters[offset].2,
                    normalizedRect: CGRect(
                        x: runRect.minX + CGFloat(offset - start) * characterWidth,
                        y: runRect.minY, width: characterWidth, height: runRect.height
                    )
                ))
            }
            start = end
        }
        cached = fragments
        return fragments
    }
}

enum ColorSampler {
    static func colors(in image: CGImage, normalizedRect: CGRect) -> (background: RGBAColor, foreground: RGBAColor) {
        let width = image.width
        let height = image.height
        let rect = CGRect(
            x: normalizedRect.minX * CGFloat(width),
            y: (1 - normalizedRect.maxY) * CGFloat(height),
            width: normalizedRect.width * CGFloat(width),
            height: normalizedRect.height * CGFloat(height)
        ).insetBy(dx: -3, dy: -3).integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard rect.width > 2, rect.height > 2, let crop = image.cropping(to: rect) else {
            return (.lightBackground, .darkText)
        }
        let sampleWidth = min(crop.width, 96)
        let sampleHeight = min(crop.height, 48)
        var bytes = [UInt8](repeating: 0, count: sampleWidth * sampleHeight * 4)
        guard let context = CGContext(
            data: &bytes, width: sampleWidth, height: sampleHeight, bitsPerComponent: 8,
            bytesPerRow: sampleWidth * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return (.lightBackground, .darkText) }
        context.draw(crop, in: CGRect(x: 0, y: 0, width: sampleWidth, height: sampleHeight))

        var red = 0, green = 0, blue = 0, count = 0
        for y in 0..<sampleHeight where y < 2 || y >= sampleHeight - 2 {
            for x in 0..<sampleWidth {
                let offset = (y * sampleWidth + x) * 4
                red += Int(bytes[offset]); green += Int(bytes[offset + 1]); blue += Int(bytes[offset + 2]); count += 1
            }
        }
        for y in 2..<(max(2, sampleHeight - 2)) {
            for x in [0, 1, max(0, sampleWidth - 2), max(0, sampleWidth - 1)] {
                let offset = (y * sampleWidth + x) * 4
                red += Int(bytes[offset]); green += Int(bytes[offset + 1]); blue += Int(bytes[offset + 2]); count += 1
            }
        }
        guard count > 0 else { return (.lightBackground, .darkText) }
        let r = CGFloat(red) / CGFloat(count * 255)
        let g = CGFloat(green) / CGFloat(count * 255)
        let b = CGFloat(blue) / CGFloat(count * 255)
        let background = RGBAColor(red: r, green: g, blue: b, alpha: 0.96)
        let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let foreground: RGBAColor = luminance > 0.52
            ? RGBAColor(red: 0.06, green: 0.06, blue: 0.06, alpha: 1)
            : RGBAColor(red: 0.96, green: 0.96, blue: 0.96, alpha: 1)
        return (background, foreground)
    }
}
