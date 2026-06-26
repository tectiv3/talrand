import SwiftUI
import SwiftData

/// Quick-access list of cards you've scanned, newest first. Re-scanning a card
/// just floats it back to the top (one row per card), so the list is bounded by
/// the deck's scannable size — no clearing needed.
struct HistoryView: View {
    @Query(filter: #Predicate<Card> { $0.lastScannedAt != nil },
           sort: [SortDescriptor(\Card.lastScannedAt, order: .reverse)])
    private var scannedCards: [Card]
    @AppStorage("thumbnailSize") private var thumbnailSize = ThumbnailSize.normal

    var body: some View {
        NavigationStack {
            Group {
                if scannedCards.isEmpty {
                    ContentUnavailableView(
                        "No scans yet",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("Cards you scan appear here for quick access.")
                    )
                } else {
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            ForEach(scannedCards) { card in
                                NavigationLink(value: card) {
                                    cardRow(card)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 12)
                    }
                }
            }
            .background(MTGTheme.darkBg)
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .navigationDestination(for: Card.self) { card in
                CardDetailView(card: card, onReplace: nil, allowRefresh: true)
            }
        }
    }

    private func cardRow(_ card: Card) -> some View {
        HStack(spacing: 10) {
            CardThumbnail(card: card, size: thumbnailSize.cardSize)

            VStack(alignment: .leading, spacing: 3) {
                Text(card.name)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(MTGTheme.textPrimary)
                    .lineLimit(1)

                if !card.manaCost.isEmpty {
                    ManaCostView(manaCost: card.manaCost, size: 14)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, thumbnailSize.rowPadding)
        .background(MTGTheme.cardBg)
    }
}
