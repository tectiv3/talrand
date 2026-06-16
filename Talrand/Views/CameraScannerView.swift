import SwiftUI
import SwiftData
import AVFoundation

// MARK: - Scanner Mode

enum ScannerMode {
    case lookup
    case swap
}

// MARK: - Camera Preview

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {}

    class PreviewUIView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

        var previewLayer: AVCaptureVideoPreviewLayer {
            layer as! AVCaptureVideoPreviewLayer
        }
    }
}

// MARK: - Scanner View

struct CameraScannerView: View {
    let mode: ScannerMode
    var onCardMatched: ((Card) -> Void)?
    var onNewCardScanned: ((String, String, String) -> Void)?
    var onBrowseDeck: (() -> Void)?

    @State private var cameraService = CameraService()
    @Environment(\.modelContext) private var modelContext

    @State private var matchedCardName: String?
    @State private var showNoMatch = false
    @State private var lastMatchTime: Date = .distantPast
    @State private var isPulsing = false

    private let matchCooldown: TimeInterval = 2

    var body: some View {
        ZStack {
            if cameraService.permissionDenied {
                permissionDeniedView
            } else {
                cameraLayer
                scanOverlay
                controlsOverlay
                feedbackOverlay
            }
        }
        .onAppear {
            cameraService.checkPermission()
        }
        .onChange(of: cameraService.permissionGranted) { _, granted in
            if granted {
                cameraService.startSession()
            }
        }
        .onChange(of: cameraService.lastScanResult) { _, result in
            guard let result else { return }
            processCandidates(result)
        }
        .onDisappear {
            cameraService.stopSession()
        }
    }

    // MARK: - Camera Layer

    private var cameraLayer: some View {
        CameraPreviewView(session: cameraService.captureSession)
            .ignoresSafeArea()
    }

    // MARK: - Scan Overlay

    private var scanOverlay: some View {
        GeometryReader { geometry in
            let guideHeight = geometry.size.height * 0.25

            VStack(spacing: 0) {
                Rectangle()
                    .fill(.black.opacity(0.5))
                    .frame(height: geometry.size.height - guideHeight)

                ZStack {
                    Rectangle()
                        .fill(.clear)

                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.white, lineWidth: 2)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .opacity(isPulsing ? 0.5 : 1.0)
                        .animation(
                            .easeInOut(duration: 1.2).repeatForever(autoreverses: true),
                            value: isPulsing
                        )
                        .onAppear { isPulsing = true }

                    Text("Position collector number here")
                        .font(.caption)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.black.opacity(0.6), in: Capsule())
                        .offset(y: -guideHeight / 2 + 16)
                }
                .frame(height: guideHeight)
            }
        }
        .ignoresSafeArea()
    }

    // MARK: - Controls

    private var controlsOverlay: some View {
        VStack {
            HStack {
                Spacer()
                if let onBrowseDeck {
                    Button {
                        onBrowseDeck()
                    } label: {
                        Label("Browse Deck", systemImage: "rectangle.stack")
                            .font(.subheadline.bold())
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    .padding(.trailing, 16)
                    .padding(.top, 8)
                }
            }
            Spacer()
        }
    }

    // MARK: - Feedback

    private var feedbackOverlay: some View {
        ZStack {
            if let name = matchedCardName {
                VStack {
                    Spacer()
                    Text(name)
                        .font(.title2.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(.green.opacity(0.85), in: RoundedRectangle(cornerRadius: 12))
                        .padding(.bottom, 60)
                }
                .transition(.opacity)
            }

            if showNoMatch {
                VStack {
                    Spacer()
                    Text("Card not in deck")
                        .font(.subheadline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(.red.opacity(0.7), in: Capsule())
                        .padding(.bottom, 60)
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: matchedCardName)
        .animation(.easeInOut(duration: 0.3), value: showNoMatch)
    }

    // MARK: - Permission Denied

    private var permissionDeniedView: some View {
        VStack(spacing: 20) {
            Image(systemName: "camera.fill")
                .font(.system(size: 60))
                .foregroundStyle(.secondary)

            Text("Camera access required")
                .font(.title2.bold())

            Text("Talrand needs camera access to scan collector numbers on your cards.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Button("Open Settings") {
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(url)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Matching

    private func processCandidates(_ result: ScanResult) {
        let candidates = result.candidates
        guard !candidates.isEmpty else { return }
        guard Date.now.timeIntervalSince(lastMatchTime) >= matchCooldown else { return }

        for candidate in candidates {
            if let card = findCard(for: candidate) {
                lastMatchTime = .now
                matchedCardName = card.name

                Task {
                    try? await Task.sleep(for: .seconds(matchCooldown))
                    matchedCardName = nil
                }

                onCardMatched?(card)
                return
            }
        }

        if mode == .swap {
            for candidate in candidates {
                guard let setCode = candidate.setCode else { continue }
                lastMatchTime = .now
                onNewCardScanned?(setCode, candidate.collectorNumber, result.ocrText)
                return
            }
        }

        if !showNoMatch {
            showNoMatch = true
            Task {
                try? await Task.sleep(for: .seconds(2))
                showNoMatch = false
            }
        }
    }

    private func findCard(for candidate: CollectorNumberCandidate) -> Card? {
        let cardName: String?

        if let setCode = candidate.setCode {
            cardName = findCardName(setCode: setCode, collectorNumber: candidate.collectorNumber)
        } else {
            cardName = findCardName(collectorNumber: candidate.collectorNumber)
        }

        guard let name = cardName else { return nil }
        return fetchCard(named: name)
    }

    private func findCardName(setCode: String, collectorNumber: String) -> String? {
        var descriptor = FetchDescriptor<CollectorNumberEntry>(
            predicate: #Predicate<CollectorNumberEntry> { entry in
                entry.setCode == setCode && entry.collectorNumber == collectorNumber
            }
        )
        descriptor.fetchLimit = 1
        return (try? modelContext.fetch(descriptor))?.first?.cardName
    }

    private func findCardName(collectorNumber: String) -> String? {
        var descriptor = FetchDescriptor<CollectorNumberEntry>(
            predicate: #Predicate<CollectorNumberEntry> { entry in
                entry.collectorNumber == collectorNumber
            }
        )
        descriptor.fetchLimit = 1
        return (try? modelContext.fetch(descriptor))?.first?.cardName
    }

    private func fetchCard(named name: String) -> Card? {
        var descriptor = FetchDescriptor<Card>(
            predicate: #Predicate<Card> { card in
                card.name == name
            }
        )
        descriptor.fetchLimit = 1
        return (try? modelContext.fetch(descriptor))?.first
    }
}
