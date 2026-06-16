import SwiftUI
import SwiftData

struct DeckListView: View {
    @Query private var decks: [Deck]
    @State private var searchText = ""
    @State private var collapsedSections: Set<String> = ["Sideboard"]

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
    }

    @ViewBuilder
    private func deckContent(_ deck: Deck) -> some View {
        List {
            commanderSection(deck)
            ForEach(groupedEntries, id: \.category) { group in
                let isCollapsed = collapsedSections.contains(group.category)
                Section {
                    if !isCollapsed {
                        ForEach(group.entries, id: \.persistentModelID) { entry in
                            if let card = entry.card {
                                NavigationLink(value: card) {
                                    cardRow(card, quantity: entry.quantity)
                                }
                            }
                        }
                    }
                } header: {
                    let count = group.entries.reduce(0) { $0 + $1.quantity }
                    HStack {
                        Text("\(group.category) (\(count))")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation {
                            if isCollapsed {
                                collapsedSections.remove(group.category)
                            } else {
                                collapsedSections.insert(group.category)
                            }
                        }
                    }
                }
            }
            sideboardSection
        }
        .listStyle(.insetGrouped)
        .searchable(text: $searchText, prompt: "Search cards")
    }

    @ViewBuilder
    private func commanderSection(_ deck: Deck) -> some View {
        if let commander = deck.commander {
            Section {
                NavigationLink(value: commander) {
                    HStack(spacing: 12) {
                        cardThumbnail(commander, size: CGSize(width: 80, height: 112))
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Commander")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)
                            Text(commander.name)
                                .font(.headline)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    @ViewBuilder
    private var sideboardSection: some View {
        if !sideboardEntries.isEmpty {
            let isCollapsed = collapsedSections.contains("Sideboard")
            Section {
                if !isCollapsed {
                    ForEach(sideboardEntries.sorted { ($0.card?.name ?? "") < ($1.card?.name ?? "") }, id: \.persistentModelID) { entry in
                        if let card = entry.card {
                            NavigationLink(value: card) {
                                cardRow(card, quantity: entry.quantity)
                            }
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Sideboard (\(sideboardEntries.reduce(0) { $0 + $1.quantity }))")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation {
                        if isCollapsed {
                            collapsedSections.remove("Sideboard")
                        } else {
                            collapsedSections.insert("Sideboard")
                        }
                    }
                }
            }
        }
    }

    private func cardRow(_ card: Card, quantity: Int) -> some View {
        HStack(spacing: 10) {
            cardThumbnail(card, size: CGSize(width: 40, height: 56))
            VStack(alignment: .leading, spacing: 2) {
                Text(card.name)
                    .font(.body)
                if !card.manaCost.isEmpty {
                    Text(card.manaCost)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if quantity > 1 {
                Text("\(quantity)x")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func cardThumbnail(_ card: Card, size: CGSize) -> some View {
        CardThumbnail(card: card, size: size)
    }

    // Priority: Creature > Instant > Sorcery > Artifact > Enchantment > Land
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
    DeckListView()
        .modelContainer(for: [Card.self, Deck.self, DeckEntry.self], inMemory: true)
}
