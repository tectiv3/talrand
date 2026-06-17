import SwiftUI
import SwiftData

extension Card: Identifiable {
    var id: String { scryfallId }
}

struct ContentView: View {
    @Query private var decks: [Deck]
    @Environment(\.modelContext) private var modelContext
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
                    })
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
                scannedCard = card
            },
            onBrowseDeck: {
                selectedTab = 0
            }
        )
    }
}

#Preview {
    ContentView()
        .modelContainer(
            for: [Card.self, Deck.self, DeckEntry.self, CollectorNumberEntry.self, Ruling.self],
            inMemory: true
        )
}
