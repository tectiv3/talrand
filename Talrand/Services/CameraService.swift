import AVFoundation
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
    var imageMatchResult: Card?
    var scanFeedback: String?
    let captureSession = AVCaptureSession()

    let cardMatcher = CardImageMatcher()
    private let processingQueue = DispatchQueue(label: "com.talrand.camera.processing")
    private var isConfigured = false
    private var lastProcessedTime: CFAbsoluteTime = 0
    private let minimumFrameInterval: CFAbsoluteTime = 0.2
    private var cachedSetCodes: [String] = []
    private var knownSetCodesSet: Set<String> = []
    private var lastCandidate: CollectorNumberCandidate?
    private var consecutiveMatchCount = 0
    private let requiredConsecutiveMatches = 2
    private var cardNameMap: [String: String] = [:]
    private var cardMap: [String: Card] = [:]
    private var lastFeedbackTime: CFAbsoluteTime = 0

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
        let cardData = cards.map { (scryfallId: $0.scryfallId, name: $0.name, card: $0) }
        processingQueue.async { [weak self] in
            guard let self else { return }
            var nameMap: [String: String] = [:]
            var objMap: [String: Card] = [:]
            for item in cardData {
                nameMap[item.scryfallId] = item.name
                objMap[item.scryfallId] = item.card
            }
            self.cardNameMap = nameMap
            self.cardMap = objMap
            self.cardMatcher.loadReferences(cards)
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
            self?.captureSession.stopRunning()
            Task { @MainActor in
                self?.isRunning = false
            }
        }
    }

    private func preferredCamera() -> AVCaptureDevice? {
        // Virtual devices auto-switch to ultra-wide for macro when close to subject
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

        if cardMatcher.isReady {
            if let match = cardMatcher.findBestMatch(in: pixelBuffer),
               let card = cardMap[match.scryfallId] {
                Task { @MainActor in
                    self.scanFeedback = nil
                    self.imageMatchResult = card
                }
                return
            }

            if let nearMatch = cardMatcher.findNearMatch(in: pixelBuffer),
               let name = cardNameMap[nearMatch.scryfallId] {
                if now - lastFeedbackTime > 1.0 {
                    lastFeedbackTime = now
                    Task { @MainActor in
                        self.scanFeedback = "Maybe: \(name)?"
                    }
                }
            } else if now - lastFeedbackTime > 2.0 {
                lastFeedbackTime = now
                Task { @MainActor in
                    self.scanFeedback = "Scanning..."
                }
            }
        }

        let request = VNRecognizeTextRequest { [weak self] request, _ in
            self?.handleRecognitionResults(request.results as? [VNRecognizedTextObservation])
        }
        request.recognitionLevel = .accurate
        // Vision uses bottom-left origin; this captures the bottom 25% of the frame
        request.regionOfInterest = CGRect(x: 0, y: 0, width: 1, height: 0.25)
        request.customWords = cachedSetCodes
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.02

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        try? handler.perform([request])
    }

    private func handleRecognitionResults(_ observations: [VNRecognizedTextObservation]?) {
        guard let observations else { return }

        let confident = observations.filter { $0.confidence >= 0.5 }
        guard !confident.isEmpty else { return }

        let ocrText = confident
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: " ")

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
