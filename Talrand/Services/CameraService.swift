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
    private var cardTypeMap: [String: String] = [:]
    // Normalized title (EN name + JP printed name) → scryfallId, for the
    // title-OCR recognition path.
    private var nameLookup: [(name: String, id: String)] = []
    // Name votes accumulate within a window (like the feature-print path) instead
    // of requiring a strict unbroken run, so one unreadable frame doesn't reset
    // progress toward a confirmed title match.
    private var lastNameMatchId: String?
    private var nameConsecutiveCount = 0
    private var lastNameVoteTime: CFAbsoluteTime = 0
    private let nameVoteWindow: CFAbsoluteTime = 1.5
    // Type-corroboration ("different category" rule) vote state.
    private var lastTypeMatchId: String?
    private var typeConsecutiveCount = 0
    private var lastTypeVoteTime: CFAbsoluteTime = 0
    private let typeVoteWindow: CFAbsoluteTime = 1.5
    // Feature-print must be at least this close before a type read is allowed to
    // confirm it — a totally-lost match (~1.0) can't be rubber-stamped by a lucky
    // type read.
    private let typeCorroborationMaxDistance: Float = 0.90
    // The current frame's feature-print result, captured synchronously so the
    // OCR stage below can fuse it with the title/type reads.
    private var frameNearestId: String?
    private var frameRunnerUpId: String?
    private var frameNearestDistance: Float = 1.0
    private let ciContext = CIContext()
    // Back-camera sample buffers arrive in the sensor's native landscape
    // orientation. In the portrait scanner UI the card is rotated 90° CW
    // relative to "upright", so every Vision request must be told this or
    // rectangle detection rejects the card (wrong aspect ratio) and OCR /
    // feature-print matching run on sideways pixels → garbage.
    private let imageOrientation: CGImagePropertyOrientation = .right
    // Scanner diagnostics ([scan]/[name]/[fire]/[match] prints + scan_crop/strip
    // image dumps) are off by default and toggled at runtime from the deck's gear
    // menu — the sole user installs Debug builds, so a compile-time gate wouldn't
    // help. Read live so flipping the switch takes effect without a restart.
    private var verbose: Bool { UserDefaults.standard.bool(forKey: "scannerDebug") }
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
        let types: [(id: String, type: String)] = cards.map { ($0.scryfallId, $0.typeLine) }
        processingQueue.async { [weak self] in
            guard let self else { return }
            var nameMap: [String: String] = [:]
            for item in names { nameMap[item.id] = item.name }
            var typeMap: [String: String] = [:]
            for item in types { typeMap[item.id] = item.type }
            self.cardNameMap = nameMap
            self.cardTypeMap = typeMap
            self.nameLookup = ScanOCR.nameLookup(for: names)
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
            lastTypeMatchId = nil
            typeConsecutiveCount = 0
            frameNearestId = nil
            frameRunnerUpId = nil
            frameNearestDistance = 1.0
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
                frameNearestId = match.scryfallId
                frameRunnerUpId = match.runnerUpId
                frameNearestDistance = match.distance
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
                        fire(match.scryfallId, via: .image)
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
                frameNearestId = nil
                frameRunnerUpId = nil
                frameNearestDistance = 1.0
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

        // Read the title and fuse it with feature-print. Each signal is weak on a
        // foreign / different-printing card, but two independent ones agreeing is
        // strong — so we fire on corroboration rather than waiting for any single
        // signal to clear a high bar alone.
        let titleText = ScanOCR.titleText(in: cardImage)
        let nameId = CardNameMatcher.match(ocrText: titleText, candidates: nameLookup)
        if let nameId, verbose {
            print("[name] OCR=\(titleText) -> \(cardNameMap[nameId] ?? nameId)")
        }

        // (1) Title and feature-print's nearest agree → fire immediately. Two
        // independent recognitions on the same card; an out-of-deck card can't
        // produce a name match, so this can't false-fire.
        if let nameId, nameId == frameNearestId {
            if verbose { print("[fire] name+art agree -> \(cardNameMap[nameId] ?? nameId)") }
            fire(nameId, via: .name)
            return
        }

        // (2) Title alone, window-voted — a single unreadable frame no longer
        // resets progress.
        if let nameId {
            if nameId == lastNameMatchId, now - lastNameVoteTime < nameVoteWindow {
                nameConsecutiveCount += 1
            } else {
                lastNameMatchId = nameId
                nameConsecutiveCount = 1
            }
            lastNameVoteTime = now
            if nameConsecutiveCount >= 2 {
                fire(nameId, via: .name)
                return
            }
        }

        // (3) "Different category" rule: confirm feature-print's nearest with the
        // OCR'd type, but only when the type actually *discriminates* — the nearest
        // matches it and the runner-up does NOT. (If both shared the type, e.g.
        // Counterspell vs Negate are both Instants, the type proves nothing and we
        // must fall through.) Voted over two frames and distance-guarded for safety.
        let nearType = frameNearestId.flatMap { cardTypeMap[$0] }
        let runnerType = frameRunnerUpId.flatMap { cardTypeMap[$0] }
        if let nearId = frameNearestId, frameNearestDistance < typeCorroborationMaxDistance,
           let ocrType = lastDetectedType,
           nearType?.localizedCaseInsensitiveContains(ocrType) == true,
           runnerType?.localizedCaseInsensitiveContains(ocrType) != true {
            if nearId == lastTypeMatchId, now - lastTypeVoteTime < typeVoteWindow {
                typeConsecutiveCount += 1
            } else {
                lastTypeMatchId = nearId
                typeConsecutiveCount = 1
            }
            lastTypeVoteTime = now
            if typeConsecutiveCount >= 2 {
                if verbose { print("[fire] type corroboration -> \(cardNameMap[nearId] ?? nearId) type=\(ocrType)") }
                fire(nearId, via: .image)
                return
            }
        } else {
            lastTypeMatchId = nil
            typeConsecutiveCount = 0
        }

        if verbose, now - lastStripDumpTime > 1.0,
           let strip = ScanOCR.collectorStrip(from: cardImage, ciContext: ciContext) {
            lastStripDumpTime = now
            saveDebugStrip(strip)
        }

        let (ocrText, candidates) = ScanOCR.collectorReadout(
            in: cardImage,
            knownSetCodes: knownSetCodesSet,
            customWords: cachedSetCodes,
            ciContext: ciContext
        )
        handleRecognitionResults(ocrText: ocrText, candidates: candidates)
    }

    /// The type line sits just below the art (~52–64% down). Read it into a
    /// Scryfall type keyword cached for the collector-number disambiguation.
    private func recognizeCardType(in image: CGImage) {
        let type = ScanOCR.typeReadout(in: image).type
        if type != nil { lastDetectedType = type }
    }

    private enum FireChannel { case name, image }

    /// Confirm a match: clear every vote streak (so the next scan starts clean)
    /// and publish the id on the channel the view observes.
    private func fire(_ id: String, via channel: FireChannel) {
        visionConsecutiveCount = 0; lastVisionMatchId = nil
        nameConsecutiveCount = 0; lastNameMatchId = nil
        typeConsecutiveCount = 0; lastTypeMatchId = nil
        nearConsecutiveCount = 0; lastNearMatchId = nil
        Task { @MainActor in
            self.scanFeedback = nil
            switch channel {
            case .name: self.nameMatchResult = id
            case .image: self.imageMatchResult = id
            }
        }
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
        let card = ScanOCR.detectCard(in: CIImage(cvPixelBuffer: pixelBuffer),
                                      orientation: imageOrientation,
                                      ciContext: ciContext)
        if card == nil, verbose { print("[scan] no card rectangle detected") }
        return card
    }

    private func handleRecognitionResults(ocrText: String, candidates: [CollectorNumberCandidate]) {
        // A frame with no legible collector text shouldn't reset the vote streak.
        guard !ocrText.isEmpty else { return }

        if verbose { print("[scan] OCR: \(ocrText)") }

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
