import AVFoundation
import CoreImage
import Vision

struct ScanResult: Equatable {
    let ocrText: String
    let candidates: [CollectorNumberCandidate]
}

@Observable
class CameraService: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    var lastScanResult: ScanResult?
    var isRunning = false
    var permissionGranted = false
    var permissionDenied = false
    var imageMatchResult: String?
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
    private let requiredVisionConsecutive = 3
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
        let refData = cards.map {
            CardReferenceData(scryfallId: $0.scryfallId, name: $0.name, localFrontImagePath: $0.localFrontImagePath)
        }
        processingQueue.async { [weak self] in
            guard let self else { return }
            var nameMap: [String: String] = [:]
            for item in refData {
                nameMap[item.scryfallId] = item.name
            }
            self.cardNameMap = nameMap
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
            if now - lastFeedbackTime > 2.0 {
                lastFeedbackTime = now
                Task { @MainActor in
                    self.scanFeedback = "Scanning..."
                }
            }
            return
        }

        if cardMatcher.isReady {
            if let match = cardMatcher.findMatch(in: cardImage) {
                if verbose {
                    let name = cardNameMap[match.scryfallId] ?? match.scryfallId
                    print("[scan] best match: \(name) d=\(String(format: "%.1f", match.distance)) strong=\(match.isStrong)")
                }
                if match.isStrong {
                    if match.scryfallId == lastVisionMatchId {
                        visionConsecutiveCount += 1
                    } else {
                        lastVisionMatchId = match.scryfallId
                        visionConsecutiveCount = 1
                    }

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
                } else {
                    lastVisionMatchId = nil
                    visionConsecutiveCount = 0
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
                if now - lastFeedbackTime > 2.0 {
                    lastFeedbackTime = now
                    Task { @MainActor in
                        self.scanFeedback = "Scanning..."
                    }
                }
            }
        }

        let request = VNRecognizeTextRequest { [weak self] request, _ in
            self?.handleRecognitionResults(request.results as? [VNRecognizedTextObservation])
        }
        request.recognitionLevel = .accurate
        // Cropped card is upright; collector number sits in the bottom band.
        request.regionOfInterest = CGRect(x: 0, y: 0, width: 1, height: 0.25)
        request.recognitionLanguages = ["ja-JP", "en-US"]
        request.customWords = cachedSetCodes
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.02

        let handler = VNImageRequestHandler(cgImage: cardImage, options: [:])
        try? handler.perform([request])
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

        let confident = observations.filter { $0.confidence >= 0.5 }
        guard !confident.isEmpty else { return }

        let ocrText = confident
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: " ")

        if verbose { print("[scan] OCR: \(ocrText)") }

        let candidates = CollectorNumberParser.parse(ocrText: ocrText, knownSetCodes: knownSetCodesSet)
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
            self.lastScanResult = ScanResult(ocrText: ocrText, candidates: candidates)
        }
    }
}
