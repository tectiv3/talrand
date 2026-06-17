import SwiftUI
import SwiftData

struct CollapsedSections: RawRepresentable {
    var sections: Set<String>

    init(_ sections: Set<String> = []) { self.sections = sections }
    init?(rawValue: String) {
        sections = rawValue.isEmpty ? [] : Set(rawValue.components(separatedBy: ","))
    }
    var rawValue: String { sections.sorted().joined(separator: ",") }

    func contains(_ s: String) -> Bool { sections.contains(s) }
    mutating func insert(_ s: String) { sections.insert(s) }
    mutating func remove(_ s: String) { sections.remove(s) }
}

struct DeckListView: View {
    @Query private var decks: [Deck]
    @State private var searchText = ""
    @AppStorage("collapsedSections") private var collapsedSections = CollapsedSections(["Sideboard"])

    private var deck: Deck? { decks.first }

    private var mainboardEntries: [DeckEntry] {
        guard let deck else { return [] }
        let entries = deck.cards.filter { $0.board == "mainboard" }
        if searchText.isEmpty { return entries }
        return entries.filter { $0.card?.name.localizedCaseInsensitiveContains(searchText) == true }
    }

    private var sideboardEntries: [DeckEntry] {
        guard let deck else { return [] }
        let entries = deck.cards.filter { $0.board == "sideboard" }
        if searchText.isEmpty { return entries }
        return entries.filter { $0.card?.name.localizedCaseInsensitiveContains(searchText) == true }
    }

    private var groupedEntries: [(category: String, entries: [DeckEntry])] {
        let categories = ["Creature", "Planeswalker", "Instant", "Sorcery", "Artifact", "Enchantment", "Battle", "Land", "Other"]
        let grouped = Dictionary(grouping: mainboardEntries) { entry in
            primaryCategory(for: entry.card?.typeLine ?? "")
        }
        return categories.compactMap { category in
            guard let entries = grouped[category], !entries.isEmpty else { return nil }
            return (category: category, entries: entries.sorted { ($0.card?.name ?? "") < ($1.card?.name ?? "") })
        }
    }

    var body: some View {
        Group {
            if let deck {
                deckContent(deck)
            } else {
                ContentUnavailableView("No deck loaded", systemImage: "rectangle.stack")
            }
        }
        .navigationTitle("Talrand")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }

    @ViewBuilder
    private func deckContent(_ deck: Deck) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                commanderHeader(deck)
                ForEach(groupedEntries, id: \.category) { group in
                    categorySection(group.category, entries: group.entries)
                }
                if !sideboardEntries.isEmpty {
                    sideboardSectionView
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 20)
        }
        .background(MTGTheme.darkBg)
        .searchable(text: $searchText, prompt: "Search cards")
    }

    // MARK: - Commander

    @ViewBuilder
    private func commanderHeader(_ deck: Deck) -> some View {
        if let commander = deck.commander {
            NavigationLink(value: commander) {
                HStack(spacing: 12) {
                    CardThumbnail(card: commander, size: CGSize(width: 48, height: 67))

                    VStack(alignment: .leading, spacing: 3) {
                        Text("COMMANDER")
                            .font(.caption2)
                            .fontWeight(.heavy)
                            .tracking(1.5)
                            .foregroundStyle(MTGTheme.gold)
                        Text(commander.name)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundStyle(MTGTheme.textPrimary)
                            .lineLimit(1)
                        if !commander.manaCost.isEmpty {
                            ManaCostView(manaCost: commander.manaCost, size: 14)
                        }
                    }

                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(MTGTheme.cardBg)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(MTGTheme.gold.opacity(0.3), lineWidth: 1)
                        )
                )
            }
            .buttonStyle(.plain)
            .padding(.vertical, 4)
        }
    }

    // MARK: - Category Section

    private func categorySection(_ category: String, entries: [DeckEntry]) -> some View {
        let isCollapsed = collapsedSections.contains(category)
        let count = entries.reduce(0) { $0 + $1.quantity }
        let cards = entries.compactMap(\.card)

        return VStack(spacing: 0) {
            sectionHeader(category, count: count, isCollapsed: isCollapsed)
            if !isCollapsed {
                VStack(spacing: 1) {
                    ForEach(entries, id: \.persistentModelID) { entry in
                        if let card = entry.card {
                            NavigationLink(value: CategoryCards(cards: cards, selectedID: card.scryfallId)) {
                                cardRow(card, quantity: entry.quantity)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    @ViewBuilder
    private var sideboardSectionView: some View {
        let isCollapsed = collapsedSections.contains("Sideboard")
        let count = sideboardEntries.reduce(0) { $0 + $1.quantity }
        let sorted = sideboardEntries.sorted { ($0.card?.name ?? "") < ($1.card?.name ?? "") }
        let cards = sorted.compactMap(\.card)

        VStack(spacing: 0) {
            sectionHeader("Sideboard", count: count, isCollapsed: isCollapsed)
            if !isCollapsed {
                VStack(spacing: 1) {
                    ForEach(sorted, id: \.persistentModelID) { entry in
                        if let card = entry.card {
                            NavigationLink(value: CategoryCards(cards: cards, selectedID: card.scryfallId)) {
                                cardRow(card, quantity: entry.quantity)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    // MARK: - Section Header

    private func sectionHeader(_ title: String, count: Int, isCollapsed: Bool) -> some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(MTGTheme.categoryColor(title))
                .frame(width: 3, height: 16)
                .clipShape(Capsule())

            Text(title.uppercased())
                .font(.caption)
                .fontWeight(.heavy)
                .tracking(1.5)
                .foregroundStyle(MTGTheme.gold)

            Text("\(count)")
                .font(.caption2)
                .fontWeight(.bold)
                .foregroundStyle(MTGTheme.darkBg)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(MTGTheme.goldDim, in: Capsule())

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(MTGTheme.textSecondary)
                .rotationEffect(.degrees(isCollapsed ? 0 : 90))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) {
                if isCollapsed {
                    collapsedSections.remove(title)
                } else {
                    collapsedSections.insert(title)
                }
            }
        }
    }

    // MARK: - Card Row

    private func cardRow(_ card: Card, quantity: Int) -> some View {
        HStack(spacing: 10) {
            CardThumbnail(card: card, size: CGSize(width: 48, height: 67))

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

            if quantity > 1 {
                Text("\(quantity)×")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(MTGTheme.goldDim)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(MTGTheme.cardBg)
    }

    // MARK: - Helpers

    private func primaryCategory(for typeLine: String) -> String {
        if typeLine.contains("Creature") { return "Creature" }
        if typeLine.contains("Planeswalker") { return "Planeswalker" }
        if typeLine.contains("Instant") { return "Instant" }
        if typeLine.contains("Sorcery") { return "Sorcery" }
        if typeLine.contains("Artifact") { return "Artifact" }
        if typeLine.contains("Enchantment") { return "Enchantment" }
        if typeLine.contains("Battle") { return "Battle" }
        if typeLine.contains("Land") { return "Land" }
        return "Other"
    }
}

#Preview {
    NavigationStack {
        DeckListView()
    }
    .modelContainer(for: [Card.self, Deck.self, DeckEntry.self], inMemory: true)
    .preferredColorScheme(.dark)
}
