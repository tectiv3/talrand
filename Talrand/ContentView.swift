import SwiftUI
import SwiftData

extension Card: Identifiable {
    var id: String { scryfallId }
}

struct ContentView: View {
    @Query private var decks: [Deck]
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab = 0
    @State private var navigationPath = NavigationPath()
    @State private var cardForSwap: Card?
    @State private var scannedCard: Card?
    @State private var backfillInProgress = false

    private var deck: Deck? { decks.first }

    var body: some View {
        if let deck, deck.setupComplete {
            mainTabView
                .task {
                    await backfillSideboardIfNeeded(deck: deck)
                    #if DEBUG
                    if UserDefaults.standard.bool(forKey: "scannerDebug") {
                        DebugExport.deckIndex(modelContext: modelContext)
                    }
                    #endif
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background { autoBackup(deck: deck) }
                }
        } else {
            SetupView()
        }
    }

    private func backfillSideboardIfNeeded(deck: Deck) async {
        guard !backfillInProgress else { return }
        backfillInProgress = true
        let service = SetupService()
        await service.performBackfill(deck: deck, modelContext: modelContext)
    }

    private var mainTabView: some View {
        TabView(selection: $selectedTab) {
            deckTab
                .tabItem {
                    Label("Deck", systemImage: "rectangle.stack.fill")
                }
                .tag(0)

            scanTab
                .tabItem {
                    Label("Scan", systemImage: "camera.viewfinder")
                }
                .tag(1)

            HistoryView()
                .tabItem {
                    Label("History", systemImage: "clock.arrow.circlepath")
                }
                .tag(2)
        }
        .sheet(item: $cardForSwap) { card in
            CardSwapView(oldCard: card, onCompleted: { newCard in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    scannedCard = newCard
                }
            })
        }
        .sheet(item: $scannedCard) { card in
            NavigationStack {
                CardDetailView(card: card, onReplace: {
                    let cardToSwap = card
                    scannedCard = nil
                    // Delay to let the sheet dismiss before presenting the next one
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        cardForSwap = cardToSwap
                    }
                })
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") {
                            scannedCard = nil
                        }
                    }
                }
            }
        }
    }

    // MARK: - Deck Tab

    private var deckTab: some View {
        NavigationStack(path: $navigationPath) {
            DeckListView()
                .navigationDestination(for: Card.self) { card in
                    CardDetailView(card: card, onReplace: {
                        cardForSwap = card
                    }, allowRefresh: true)
                }
                .navigationDestination(for: CategoryCards.self) { nav in
                    CardPagerView(cards: nav.cards, selectedID: nav.selectedID) { card in
                        cardForSwap = card
                    }
                }
        }
    }

    // MARK: - Scan Tab

    private var scanTab: some View {
        CameraScannerView(
            mode: .lookup,
            onCardMatched: { card in
                recordScan(card)
                scannedCard = card
            }
        )
    }

    /// Stamp a scanned card so it surfaces in the History tab (newest-first,
    /// auto-deduped — a re-scan just refreshes the timestamp).
    private func recordScan(_ card: Card) {
        card.lastScannedAt = .now
        try? modelContext.save()
    }

    /// On backgrounding, write the deck snapshot to the iCloud Drive container so
    /// a backup exists without the user having to think about it. The snapshot is
    /// built on the main actor (it reads SwiftData), then the slow iCloud file
    /// write is handed off the main thread.
    private func autoBackup(deck: Deck) {
        let backup = BackupService.makeBackup(deck: deck)
        guard let data = try? BackupCodec.encode(backup) else { return }
        Task.detached(priority: .background) {
            ICloudBackup.write(data)
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(
            for: [Card.self, Deck.self, DeckEntry.self, CollectorNumberEntry.self, Ruling.self],
            inMemory: true
        )
}
