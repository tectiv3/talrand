import CoreGraphics
import CoreImage
import Vision

/// Pure, camera-free OCR primitives shared by the live scanner
/// (`CameraService`) and the regression suite. Everything here takes a
/// `CGImage`/`CIImage` and returns plain values, so the same crop → OCR → parse
/// logic that runs on a live frame can be replayed against a fixture image in a
/// unit test — no `AVCaptureSession`, no device.
enum ScanOCR {

    // MARK: - Card detection

    /// Detect the card rectangle and perspective-correct it to an upright crop.
    /// `orientation` is applied to both the detection space and the corrected
    /// image so the corner coordinates and pixels live in the same space (the
    /// live path passes `.right`; a fixture passes its EXIF orientation).
    static func detectCard(in source: CIImage,
                           orientation: CGImagePropertyOrientation,
                           ciContext: CIContext) -> CGImage? {
        let request = VNDetectRectanglesRequest()
        request.minimumAspectRatio = 0.5
        request.maximumAspectRatio = 0.85
        request.minimumSize = 0.15
        request.minimumConfidence = 0.8
        request.maximumObservations = 1

        let handler = VNImageRequestHandler(ciImage: source, orientation: orientation, options: [:])
        guard (try? handler.perform([request])) != nil,
              let rect = request.results?.first else { return nil }

        let ciImage = source.oriented(orientation)
        let ext = ciImage.extent
        func point(_ p: CGPoint) -> CIVector {
            CIVector(cgPoint: CGPoint(x: ext.minX + p.x * ext.width, y: ext.minY + p.y * ext.height))
        }
        let corrected = ciImage.applyingFilter("CIPerspectiveCorrection", parameters: [
            "inputTopLeft": point(rect.topLeft),
            "inputTopRight": point(rect.topRight),
            "inputBottomLeft": point(rect.bottomLeft),
            "inputBottomRight": point(rect.bottomRight),
        ])
        return ciContext.createCGImage(corrected, from: corrected.extent)
    }

    // MARK: - OCR helper

    /// Recognize text in a crop, returning the top candidate per observation
    /// (above `minimumConfidence`). Callers join/parse as they see fit.
    static func recognizedStrings(in image: CGImage,
                                  languages: [String] = ["ja-JP", "en-US"],
                                  customWords: [String] = [],
                                  usesLanguageCorrection: Bool = true,
                                  minimumConfidence: Float = 0) -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = languages
        request.customWords = customWords
        request.usesLanguageCorrection = usesLanguageCorrection
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? [])
            .filter { $0.confidence >= minimumConfidence }
            .compactMap { $0.topCandidates(1).first?.string }
    }

    // MARK: - Collector number (bottom strip)

    /// Bottom strip of the card, upscaled 4× and contrast/sharpen-boosted to
    /// grayscale so Vision can read the small set code + collector number.
    static func collectorStrip(from image: CGImage, ciContext: CIContext) -> CGImage? {
        // Full width: the collector number is bottom-LEFT on modern cards but
        // bottom-RIGHT on pre-2014 cards. The parser's denominator guard handles
        // the power/toughness "4/4" noise, so we don't need to crop it out.
        let stripHeight = Int(Double(image.height) * 0.16)
        let rect = CGRect(x: 0, y: image.height - stripHeight, width: image.width, height: stripHeight)
        guard let cropped = image.cropping(to: rect) else { return nil }

        // Upscale for legibility, desaturate, then *sharpen* rather than
        // hard-contrast — aggressive contrast clips hairline glyphs (the "1" in
        // "0160" was eroded to an apostrophe). Sharpening recovers thin strokes.
        let processed = CIImage(cgImage: cropped)
            .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: 4.0])
            .applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 0.0,
                kCIInputContrastKey: 1.12,
            ])
            .applyingFilter("CISharpenLuminance", parameters: [
                kCIInputSharpnessKey: 0.7,
            ])
        return ciContext.createCGImage(processed, from: processed.extent)
    }

    /// Crop the bottom strip, OCR it, and parse collector-number candidates.
    ///
    /// No `customWords`: Vision only consults that list when
    /// `usesLanguageCorrection` is true, and correction is off here on purpose
    /// (it mangles alphanumeric codes like "69/350"). Passing set codes as custom
    /// words would be silently ignored, so the path doesn't take them.
    static func collectorReadout(in cardImage: CGImage,
                                 knownSetCodes: Set<String>,
                                 ciContext: CIContext) -> (text: String, candidates: [CollectorNumberCandidate]) {
        guard let strip = collectorStrip(from: cardImage, ciContext: ciContext) else { return ("", []) }
        // Small low-contrast collector text often scores below 0.5; the parser
        // is strict enough that a looser confidence floor won't add false codes.
        let text = recognizedStrings(in: strip,
                                     usesLanguageCorrection: false,
                                     minimumConfidence: 0.3).joined(separator: " ")
        let candidates = CollectorNumberParser.parse(ocrText: text, knownSetCodes: knownSetCodes)
        return (text, candidates)
    }

    // MARK: - Title (top name bar)

    /// OCR the top name bar (~2–11% down) where the card title sits.
    static func titleText(in cardImage: CGImage) -> String {
        let h = Double(cardImage.height)
        let rect = CGRect(x: 0, y: Int(h * 0.02), width: cardImage.width, height: Int(h * 0.10))
        guard let cropped = cardImage.cropping(to: rect) else { return "" }
        return recognizedStrings(in: cropped).joined(separator: " ")
    }

    // MARK: - Type line

    /// OCR the type line (~50–66% down) into a Scryfall type keyword, used only
    /// as a tiebreaker when a collector number maps to several deck cards.
    static func typeReadout(in cardImage: CGImage) -> (text: String, type: String?) {
        let h = Double(cardImage.height)
        let rect = CGRect(x: 0, y: Int(h * 0.50), width: cardImage.width, height: Int(h * 0.16))
        guard let cropped = cardImage.cropping(to: rect) else { return ("", nil) }
        let text = recognizedStrings(in: cropped).joined(separator: " ")
        return (text, CardTypeParser.parse(text))
    }

    // MARK: - Name lookup

    /// Build the title-OCR lookup from the deck's cards. Each English name and
    /// Japanese printed name is indexed, and for double-faced cards the pre-"//"
    /// front portion is added too — the physical card only shows the front face
    /// (e.g. 完成態の講師 for "Docent of Perfection // Final Iteration").
    static func nameLookup(for cards: [(id: String, name: String, printed: String)]) -> [(name: String, id: String)] {
        var lookup: [(name: String, id: String)] = []
        for item in cards {
            func add(_ s: String) {
                guard !s.isEmpty else { return }
                lookup.append((name: s, id: item.id))
                if let front = s.components(separatedBy: " // ").first, front != s, !front.isEmpty {
                    lookup.append((name: front, id: item.id))
                }
            }
            add(item.name)
            if !item.printed.isEmpty { add(item.printed) }
        }
        return lookup
    }
}
