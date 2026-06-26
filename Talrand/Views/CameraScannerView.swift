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
    @State private var noMatchStreak = 0
    @State private var lastMatchTime: Date = .distantPast
    @State private var isPulsing = false
    @State private var showingSearch = false
    @State private var searchText = ""

    private let matchCooldown: TimeInterval = 2

    var body: some View {
        ZStack {
            if cameraService.permissionDenied {
                permissionDeniedView
            } else if showingSearch {
                localSearchView
            } else {
                cameraLayer
                scanOverlay
                controlsOverlay
                feedbackOverlay
                searchButtonOverlay
            }
        }
        .task {
            loadCardReferencesIfNeeded()
        }
        .onAppear {
            cameraService.checkPermission()
            if cameraService.permissionGranted {
                cameraService.startSession()
            }
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
        .onChange(of: cameraService.imageMatchResult) { _, scryfallId in
            guard let scryfallId else { return }
            cameraService.imageMatchResult = nil
            fireMatch(scryfallId: scryfallId)
        }
        .onChange(of: cameraService.nameMatchResult) { _, scryfallId in
            guard let scryfallId else { return }
            cameraService.nameMatchResult = nil
            fireMatch(scryfallId: scryfallId)
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
            // Standard MTG card aspect (2.5 : 3.5). The detector finds the card
            // anywhere in frame, so the guide just helps the user fit the whole
            // card — not cram it into a strip.
            let guideWidth = min(geometry.size.width * 0.82, geometry.size.height * 0.62 * (2.5 / 3.5))
            let guideHeight = guideWidth * (3.5 / 2.5)

            VStack(spacing: 14) {
                if let feedback = cameraService.scanFeedback {
                    Text(feedback)
                        .font(.caption)
                        .foregroundStyle(MTGTheme.textPrimary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(MTGTheme.cardBg.opacity(0.85), in: Capsule())
                }

                RoundedRectangle(cornerRadius: 12)
                    .stroke(.white, lineWidth: 2)
                    .frame(width: guideWidth, height: guideHeight)
                    .opacity(isPulsing ? 0.5 : 1.0)
                    .animation(
                        .easeInOut(duration: 1.2).repeatForever(autoreverses: true),
                        value: isPulsing
                    )
                    .onAppear { isPulsing = true }

                Text("Fit the whole card in the frame")
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.6), in: Capsule())
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .ignoresSafeArea()
    }

    // MARK: - Controls

    private var controlsOverlay: some View {
        VStack {
            HStack {
                Button {
                    cameraService.toggleTorch()
                } label: {
                    Image(systemName: cameraService.torchOn ? "flashlight.on.fill" : "flashlight.off.fill")
                        .font(.title3)
                        .padding(10)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .padding(.leading, 16)
                .padding(.top, 8)

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

    // MARK: - Search Button

    private var searchButtonOverlay: some View {
        VStack {
            Spacer()
            Button {
                cameraService.stopSession()
                showingSearch = true
            } label: {
                Label("Search by Name", systemImage: "magnifyingglass")
                    .font(.subheadline.bold())
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .padding(.bottom, 24)
        }
    }

    // MARK: - Local Search

    private var filteredCards: [Card] {
        guard !searchText.isEmpty else { return [] }
        let query = searchText.lowercased()
        let descriptor = FetchDescriptor<Card>()
        guard let allCards = try? modelContext.fetch(descriptor) else { return [] }
        return allCards.filter { $0.name.lowercased().contains(query) }
    }

    private var localSearchView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("Card name", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()

                Button {
                    searchText = ""
                    showingSearch = false
                    cameraService.startSession()
                } label: {
                    Label("Scanner", systemImage: "camera")
                        .font(.subheadline)
                }
                .buttonStyle(.bordered)
            }
            .padding()
            .background(MTGTheme.darkBg)

            if searchText.isEmpty {
                Spacer()
                Text("Type a card name to search your deck")
                    .font(.subheadline)
                    .foregroundStyle(MTGTheme.textSecondary)
                Spacer()
            } else if filteredCards.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                List(filteredCards, id: \.scryfallId) { card in
                    Button {
                        onCardMatched?(card)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(card.name)
                                .font(.body)
                                .foregroundStyle(MTGTheme.textPrimary)
                            Text("\(card.setCode.uppercased()) #\(card.collectorNumber) — \(card.typeLine)")
                                .font(.caption)
                                .foregroundStyle(MTGTheme.textSecondary)
                        }
                        .padding(.vertical, 2)
                    }
                    .listRowBackground(MTGTheme.cardBg)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(MTGTheme.darkBg)
            }
        }
        .background(MTGTheme.darkBg)
    }

    // MARK: - Load References

    private func loadCardReferencesIfNeeded() {
        let descriptor = FetchDescriptor<Card>()
        guard let cards = try? modelContext.fetch(descriptor) else { return }

        // Lands (generic/near-identical art) and the commander (always known)
        // only add false-positive surface to the feature-print matcher.
        let commanderIds = Set(
            ((try? modelContext.fetch(FetchDescriptor<Deck>())) ?? [])
                .compactMap { $0.commander?.scryfallId }
        )
        let scannable = cards.filter { card in
            !card.typeLine.contains("Land") && !commanderIds.contains(card.scryfallId)
        }
        cameraService.loadCardReferences(scannable)
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

    /// Confirms a recognized card (from feature-print or the name path), honoring
    /// the cooldown so the two paths can't double-fire on the same card.
    private func fireMatch(scryfallId: String) {
        guard Date.now.timeIntervalSince(lastMatchTime) >= matchCooldown else { return }
        guard let card = fetchCard(scryfallId: scryfallId) else { return }
        lastMatchTime = .now
        noMatchStreak = 0
        matchedCardName = card.name
        Task {
            try? await Task.sleep(for: .seconds(matchCooldown))
            matchedCardName = nil
        }
        onCardMatched?(card)
    }

    private func processCandidates(_ result: ScanResult) {
        let candidates = result.candidates
        guard !candidates.isEmpty else { return }
        guard Date.now.timeIntervalSince(lastMatchTime) >= matchCooldown else { return }

        for candidate in candidates {
            if let card = findCard(for: candidate, type: result.cardType, nearestId: cameraService.nearestMatchId) {
                lastMatchTime = .now
                noMatchStreak = 0
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

        // Only surface "not in deck" once an unresolved read persists — a single
        // garbled OCR frame shouldn't flash it while feature-print is still
        // homing in on the right card.
        noMatchStreak += 1
        if noMatchStreak >= 4, !showNoMatch {
            showNoMatch = true
            Task {
                try? await Task.sleep(for: .seconds(2))
                showNoMatch = false
            }
        }
    }

    private func findCard(for candidate: CollectorNumberCandidate, type: String?, nearestId: String?) -> Card? {
        // Set code + number is unique — trust it directly.
        if let setCode = candidate.setCode,
           let name = findCardName(setCode: setCode, collectorNumber: candidate.collectorNumber) {
            return fetchCard(named: name)
        }

        // Number alone can map to several deck cards (each has a printing with
        // that number). Accept only when it resolves to exactly one — otherwise
        // disambiguate before guessing.
        let cards = findCards(collectorNumber: candidate.collectorNumber)
        print("[match] #\(candidate.collectorNumber) type=\(type ?? "?") near=\(nearestId ?? "?") -> \(cards.map { "\($0.name)|\($0.typeLine)" })")
        if cards.count == 1 { return cards.first }
        guard cards.count > 1 else { return nil }

        // Fusion: feature-print can't fire on its own for a different-printing
        // card, but its nearest neighbour still ranks the right card first.
        // Constraining that hint to the number's candidate set makes it safe
        // (a free feature-print match previously mis-fired, e.g. Negate).
        if let nearestId, let hit = cards.first(where: { $0.scryfallId == nearestId }) {
            return hit
        }

        // Fall back to the OCR'd card type to break the tie.
        if let type {
            let matched = cards.filter { $0.typeLine.localizedCaseInsensitiveContains(type) }
            if matched.count == 1 { return matched.first }
        }
        return nil
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

    private func findCards(collectorNumber: String) -> [Card] {
        let descriptor = FetchDescriptor<CollectorNumberEntry>(
            predicate: #Predicate<CollectorNumberEntry> { entry in
                entry.collectorNumber == collectorNumber
            }
        )
        let names = Set((try? modelContext.fetch(descriptor))?.map(\.cardName) ?? [])
        return names.compactMap { fetchCard(named: $0) }
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

    private func fetchCard(scryfallId: String) -> Card? {
        var descriptor = FetchDescriptor<Card>(
            predicate: #Predicate<Card> { card in
                card.scryfallId == scryfallId
            }
        )
        descriptor.fetchLimit = 1
        return (try? modelContext.fetch(descriptor))?.first
    }
}
