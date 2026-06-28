import SwiftUI

struct CategoryCards: Hashable {
    let cards: [Card]
    let selectedID: String
}

struct CardPagerView: View {
    let cards: [Card]
    var onReplace: ((Card) -> Void)?

    @State private var currentID: String

    init(cards: [Card], selectedID: String, onReplace: ((Card) -> Void)? = nil) {
        self.cards = cards
        self._currentID = State(initialValue: selectedID)
        self.onReplace = onReplace
    }

    private var currentCard: Card? {
        cards.first { $0.scryfallId == currentID }
    }

    var body: some View {
        // The swap button lives on the pager rather than each page: a TabView shares
        // one navigation bar, so per-page toolbars stack their items during swipes,
        // duplicating the button. One toolbar keyed to the current card avoids that.
        TabView(selection: $currentID) {
            ForEach(cards) { card in
                CardDetailView(card: card, allowRefresh: true)
                    .tag(card.scryfallId)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .background(MTGTheme.darkBg)
        .toolbar {
            if let onReplace, let currentCard {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: { onReplace(currentCard) }) {
                        Image(systemName: "arrow.triangle.swap")
                    }
                    .tint(MTGTheme.goldDim)
                }
            }
        }
    }
}
