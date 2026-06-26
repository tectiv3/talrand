import AVFoundation
import CoreImage
import UIKit
import Vision

struct ScanResult: Equatable {
    let ocrText: String
    let candidates: [CollectorNumberCandidate]
    let cardType: String?
}

@Observable
class CameraService: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    var lastScanResult: ScanResult?
    var isRunning = false
    var permissionGranted = false
    var permissionDenied = false
    var imageMatchResult: String?
    // Feature-print's current nearest neighbour, even when it's too weak to
    // auto-fire on its own. Used to disambiguate a collector number that maps to
    // several deck cards (a different-printing card's art still ranks the right
    // card nearest). Cleared when no card is in frame.
    var nearestMatchId: String?
    // A confident, unique title match (EN or JP printed name). The most reliable
    // signal for the user's Japanese cards: printing-independent and collision-free.
    var nameMatchResult: String?
    var scanFeedback: String?
    var torchOn = false
    let captureSession = AVCaptureSession()

    let cardMatcher = CardImageMatcher()
    private let processingQueue = DispatchQueue(label: "com.talrand.camera.processing")
    private var isConfigured = false
    private var activeDevice: AVCaptureDevice?
    private var lastProcessedTime: CFAbsoluteTime = 0
    private let minimumFrameInterval: CFAbsoluteTime = 0.2
    private var cachedSetCodes: [String] = []
    private var knownSetCodesSet: Set<String> = []
    private var lastCandidate: CollectorNumberCandidate?
    private var consecutiveMatchCount = 0
    private let requiredConsecutiveMatches = 2
    private var cardNameMap: [String: String] = [:]
    // Normalized title (EN name + JP printed name) → scryfallId, for the
    // title-OCR recognition path.
    private var nameLookup: [(name: String, id: String)] = []
    private var lastNameMatchId: String?
    private var nameConsecutiveCount = 0
    private let ciContext = CIContext()
    // Back-camera sample buffers arrive in the sensor's native landscape
    // orientation. In the portrait scanner UI the card is rotated 90° CW
    // relative to "upright", so every Vision request must be told this or
    // rectangle detection rejects the card (wrong aspect ratio) and OCR /
    // feature-print matching run on sideways pixels → garbage.
    private let imageOrientation: CGImagePropertyOrientation = .right
    private let verbose = true
    private var lastFeedbackTime: CFAbsoluteTime = 0
    private var lastVisionMatchId: String?
    private var visionConsecutiveCount = 0
    private var lastVisionVoteTime: CFAbsoluteTime = 0
    private var lastDebugDumpTime: CFAbsoluteTime = 0
    private var lastStripDumpTime: CFAbsoluteTime = 0
    private var lastOcrTime: CFAbsoluteTime = 0
    private var lastDetectedType: String?
    // OCR on the upscaled strip is expensive; running it every frame starves the
    // faster feature-print path. The code doesn't change frame-to-frame.
    private let ocrInterval: CFAbsoluteTime = 0.35
    private let requiredVisionConsecutive = 2
    // Strong frames are interspersed with jittery non-strong ones, so votes for
    // the same card accumulate as long as they keep arriving within this window
    // rather than requiring a strict unbroken run.
    private let visionVoteWindow: CFAbsoluteTime = 1.5
    private var lastNearMatchId: String?
    private var nearConsecutiveCount = 0

    func checkPermission() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            permissionGranted = true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor in
                    self?.permissionGranted = granted
                    self?.permissionDenied = !granted
                }
            }
        case .denied, .restricted:
            permissionDenied = true
        @unknown default:
            permissionDenied = true
        }
    }

    func loadCardReferences(_ cards: [Card]) {
        // Read every model property here (caller thread) into value types; the
        // SwiftData objects must not be touched on the processing queue.
        let refData = cards.map {
            CardReferenceData(scryfallId: $0.scryfallId, name: $0.name, localFrontImagePath: $0.localFrontImagePath)
        }
        let names: [(id: String, name: String, printed: String)] = cards.map {
            ($0.scryfallId, $0.name, $0.printedName)
        }
        processingQueue.async { [weak self] in
            guard let self else { return }
            var nameMap: [String: String] = [:]
            var lookup: [(name: String, id: String)] = []
            for item in names {
                nameMap[item.id] = item.name
                lookup.append((name: item.name, id: item.id))
                if !item.printed.isEmpty {
                    lookup.append((name: item.printed, id: item.id))
                }
            }
            self.cardNameMap = nameMap
            self.nameLookup = lookup
            self.cardMatcher.loadReferences(refData)
        }
    }

    func startSession() {
        guard !isRunning else { return }

        if !isConfigured {
            setupSession()
        }

        processingQueue.async { [weak self] in
            self?.captureSession.startRunning()
            Task { @MainActor in
                self?.isRunning = true
            }
        }
    }

    private func setupSession() {
        captureSession.beginConfiguration()
        captureSession.sessionPreset = .high

        let camera = preferredCamera()
        guard let camera,
              let input = try? AVCaptureDeviceInput(device: camera),
              captureSession.canAddInput(input) else {
            captureSession.commitConfiguration()
            return
        }
        captureSession.addInput(input)
        activeDevice = camera

        let output = AVCaptureVideoDataOutput()
        output.setSampleBufferDelegate(self, queue: processingQueue)
        output.alwaysDiscardsLateVideoFrames = true

        guard captureSession.canAddOutput(output) else {
            captureSession.commitConfiguration()
            return
        }
        captureSession.addOutput(output)

        captureSession.commitConfiguration()
        isConfigured = true

        Task {
            cachedSetCodes = await ScryfallAPI.shared.fetchSetCodes()
            knownSetCodesSet = Set(cachedSetCodes)
        }
    }

    func stopSession() {
        guard isRunning else { return }
        processingQueue.async { [weak self] in
            guard let self else { return }
            if let device = self.activeDevice, device.hasTorch, device.isTorchActive {
                try? device.lockForConfiguration()
                device.torchMode = .off
                device.unlockForConfiguration()
            }
            self.captureSession.stopRunning()
            Task { @MainActor in
                self.isRunning = false
                self.torchOn = false
            }
        }
    }

    func toggleTorch() {
        processingQueue.async { [weak self] in
            guard let self,
                  let device = self.activeDevice,
                  device.hasTorch else { return }
            do {
                try device.lockForConfiguration()
                let on = !device.isTorchActive
                device.torchMode = on ? .on : .off
                device.unlockForConfiguration()
                Task { @MainActor in self.torchOn = on }
            } catch {}
        }
    }

    private func preferredCamera() -> AVCaptureDevice? {
        let preferredTypes: [AVCaptureDevice.DeviceType] = [
            .builtInTripleCamera,
            .builtInDualWideCamera,
            .builtInDualCamera,
            .builtInWideAngleCamera,
        ]
        for type in preferredTypes {
            if let device = AVCaptureDevice.default(type, for: .video, position: .back) {
                return device
            }
        }
        return AVCaptureDevice.default(for: .video)
    }

    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastProcessedTime >= minimumFrameInterval else { return }
        lastProcessedTime = now

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        guard let cardImage = detectAndCropCard(from: pixelBuffer) else {
            lastVisionMatchId = nil
            visionConsecutiveCount = 0
            lastNearMatchId = nil
            nearConsecutiveCount = 0
            lastNameMatchId = nil
            nameConsecutiveCount = 0
            Task { @MainActor in self.nearestMatchId = nil }
            if now - lastFeedbackTime > 2.0 {
                lastFeedbackTime = now
                Task { @MainActor in
                    self.scanFeedback = "Scanning..."
                }
            }
            return
        }

        if verbose, now - lastDebugDumpTime > 1.0 {
            lastDebugDumpTime = now
            saveDebugCrop(cardImage)
        }

        if cardMatcher.isReady {
            if let match = cardMatcher.findMatch(in: cardImage) {
                let nearId = match.scryfallId
                Task { @MainActor in self.nearestMatchId = nearId }
                if verbose {
                    let name = cardNameMap[match.scryfallId] ?? match.scryfallId
                    let d = String(format: "%.3f", match.distance)
                    let next = String(format: "%.3f", match.runnerUpDistance)
                    print("[scan] best: \(name) d=\(d) next=\(next) strong=\(match.isStrong)")
                    if now - lastFeedbackTime > 0.4 {
                        lastFeedbackTime = now
                        let shortName = cardNameMap[match.scryfallId] ?? "?"
                        Task { @MainActor in
                            self.scanFeedback = "\(shortName)  d=\(d) / next \(next)"
                        }
                    }
                }
                if match.isStrong {
                    // Accumulate votes across non-strong frames; reset only when
                    // the card changes or the run goes stale, so hand jitter no
                    // longer wipes progress toward a confirmed match.
                    if match.scryfallId == lastVisionMatchId, now - lastVisionVoteTime < visionVoteWindow {
                        visionConsecutiveCount += 1
                    } else {
                        lastVisionMatchId = match.scryfallId
                        visionConsecutiveCount = 1
                    }
                    lastVisionVoteTime = now

                    if visionConsecutiveCount >= requiredVisionConsecutive {
                        visionConsecutiveCount = 0
                        lastVisionMatchId = nil
                        lastNearMatchId = nil
                        nearConsecutiveCount = 0
                        Task { @MainActor in
                            self.scanFeedback = nil
                            self.imageMatchResult = match.scryfallId
                        }
                        return
                    }
                }

                if let name = cardNameMap[match.scryfallId] {
                    if match.scryfallId == lastNearMatchId {
                        nearConsecutiveCount += 1
                    } else {
                        lastNearMatchId = match.scryfallId
                        nearConsecutiveCount = 1
                    }
                    if nearConsecutiveCount >= 2, now - lastFeedbackTime > 1.0 {
                        lastFeedbackTime = now
                        Task { @MainActor in
                            self.scanFeedback = "Maybe: \(name)? (d=\(String(format: "%.1f", match.distance)))"
                        }
                    }
                }
            } else {
                lastVisionMatchId = nil
                visionConsecutiveCount = 0
                lastNearMatchId = nil
                nearConsecutiveCount = 0
                Task { @MainActor in self.nearestMatchId = nil }
                if now - lastFeedbackTime > 2.0 {
                    lastFeedbackTime = now
                    Task { @MainActor in
                        self.scanFeedback = "Scanning..."
                    }
                }
            }
        }

        // The collector code is small and low-contrast (especially on modern JP
        // cards). A regionOfInterest only shrinks the search window — it doesn't
        // make tiny text legible — so instead crop the bottom strip, upscale and
        // boost contrast, then OCR that as a full image.
        guard now - lastOcrTime >= ocrInterval else { return }
        lastOcrTime = now

        // Read the type line first (sync) so it's available as a tiebreaker when
        // the collector number below resolves to more than one deck card.
        recognizeCardType(in: cardImage)

        // Read the title — a confident unique name match is the strongest signal
        // for the user's foreign cards and fires on its own.
        recognizeCardName(in: cardImage)

        guard let strip = collectorStrip(from: cardImage) else { return }

        let request = VNRecognizeTextRequest { [weak self] request, _ in
            self?.handleRecognitionResults(request.results as? [VNRecognizedTextObservation])
        }
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["ja-JP", "en-US"]
        request.customWords = cachedSetCodes
        request.usesLanguageCorrection = false

        let handler = VNImageRequestHandler(cgImage: strip, options: [:])
        try? handler.perform([request])
    }

    /// Bottom strip of the card, upscaled 3× and contrast-boosted to grayscale so
    /// Vision can read the small set code + collector number.
    private func collectorStrip(from image: CGImage) -> CGImage? {
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
        let result = ciContext.createCGImage(processed, from: processed.extent)
        if verbose, let result, CFAbsoluteTimeGetCurrent() - lastStripDumpTime > 1.0 {
            lastStripDumpTime = CFAbsoluteTimeGetCurrent()
            saveDebugStrip(result)
        }
        return result
    }

    /// The type line sits just below the art (~52–64% down). Read it into a
    /// Scryfall type keyword cached for the collector-number disambiguation.
    private func recognizeCardType(in image: CGImage) {
        let h = Double(image.height)
        let rect = CGRect(x: 0, y: Int(h * 0.50), width: image.width, height: Int(h * 0.16))
        guard let cropped = image.cropping(to: rect) else { return }

        let request = VNRecognizeTextRequest { [weak self] request, _ in
            let text = (request.results as? [VNRecognizedTextObservation])?
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: " ") ?? ""
            let type = CardTypeParser.parse(text)
            if type != nil { self?.lastDetectedType = type }
        }
        // Japanese type lines ("インスタント") need .accurate; .fast is Latin-only.
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["ja-JP", "en-US"]
        try? VNImageRequestHandler(cgImage: cropped, options: [:]).perform([request])
    }

    /// The card title sits in the top name bar (~2–11% down). OCR it and match
    /// against the deck's English + Japanese names; a confident, unique match
    /// over two frames fires directly — printing-independent, collision-free.
    private func recognizeCardName(in image: CGImage) {
        let h = Double(image.height)
        let rect = CGRect(x: 0, y: Int(h * 0.02), width: image.width, height: Int(h * 0.10))
        guard let cropped = image.cropping(to: rect) else { return }

        let request = VNRecognizeTextRequest { [weak self] request, _ in
            guard let self else { return }
            let text = (request.results as? [VNRecognizedTextObservation])?
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: " ") ?? ""
            guard let id = CardNameMatcher.match(ocrText: text, candidates: self.nameLookup) else {
                self.lastNameMatchId = nil
                self.nameConsecutiveCount = 0
                return
            }
            if verbose { print("[name] OCR=\(text) -> \(self.cardNameMap[id] ?? id)") }
            if id == self.lastNameMatchId {
                self.nameConsecutiveCount += 1
            } else {
                self.lastNameMatchId = id
                self.nameConsecutiveCount = 1
            }
            if self.nameConsecutiveCount >= 2 {
                self.nameConsecutiveCount = 0
                self.lastNameMatchId = nil
                Task { @MainActor in
                    self.scanFeedback = nil
                    self.nameMatchResult = id
                }
            }
        }
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["ja-JP", "en-US"]
        try? VNImageRequestHandler(cgImage: cropped, options: [:]).perform([request])
    }

    // MARK: - Debug

    /// Writes the perspective-corrected crop to Documents/scan_crop.jpg so it can
    /// be pulled off-device to verify the bottom collector line isn't clipped.
    private func saveDebugCrop(_ image: CGImage) {
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
              let data = UIImage(cgImage: image).jpegData(compressionQuality: 0.9) else { return }
        try? data.write(to: dir.appendingPathComponent("scan_crop.jpg"))
    }

    /// Writes the upscaled collector strip so its legibility can be verified.
    private func saveDebugStrip(_ image: CGImage) {
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
              let data = UIImage(cgImage: image).jpegData(compressionQuality: 0.9) else { return }
        try? data.write(to: dir.appendingPathComponent("scan_strip.jpg"))
    }

    // MARK: - Card Detection

    private func detectAndCropCard(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: imageOrientation, options: [:])
        let request = VNDetectRectanglesRequest()
        request.minimumAspectRatio = 0.5
        request.maximumAspectRatio = 0.85
        request.minimumSize = 0.15
        request.minimumConfidence = 0.8
        request.maximumObservations = 1

        do {
            try handler.perform([request])
        } catch {
            if verbose { print("[scan] rectangle detection error: \(error.localizedDescription)") }
            return nil
        }
        guard let rect = request.results?.first else {
            if verbose { print("[scan] no card rectangle detected") }
            return nil
        }

        // Orient the source to the SAME space the rectangle coordinates live in,
        // otherwise the perspective corners are mapped against rotated extents.
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer).oriented(imageOrientation)
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

    private func handleRecognitionResults(_ observations: [VNRecognizedTextObservation]?) {
        guard let observations else { return }

        // Small low-contrast collector text often scores below 0.5; the parser
        // is strict enough that a looser confidence floor won't add false codes.
        let confident = observations.filter { $0.confidence >= 0.3 }
        guard !confident.isEmpty else { return }

        let ocrText = confident
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: " ")

        if verbose { print("[scan] OCR: \(ocrText)") }

        let candidates = CollectorNumberParser.parse(ocrText: ocrText, knownSetCodes: knownSetCodesSet)
        if verbose {
            let parsed = candidates.map { "\($0.setCode ?? "?")#\($0.collectorNumber)" }.joined(separator: ", ")
            print("[scan] candidates: [\(parsed)] type=\(lastDetectedType ?? "?")")
        }
        guard let topCandidate = candidates.first else {
            lastCandidate = nil
            consecutiveMatchCount = 0
            return
        }

        if topCandidate == lastCandidate {
            consecutiveMatchCount += 1
        } else {
            lastCandidate = topCandidate
            consecutiveMatchCount = 1
        }

        guard consecutiveMatchCount >= requiredConsecutiveMatches else { return }

        Task { @MainActor in
            self.lastScanResult = ScanResult(ocrText: ocrText, candidates: candidates, cardType: self.lastDetectedType)
        }
    }
}
