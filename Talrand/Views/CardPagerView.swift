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

    var body: some View {
        TabView(selection: $currentID) {
            ForEach(cards) { card in
                CardDetailView(card: card, onReplace: { onReplace?(card) })
                    .tag(card.scryfallId)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .background(MTGTheme.darkBg)
    }
}
