import Foundation
import SwiftData

/// Builds and applies `BackupV1` snapshots. Both methods touch SwiftData models
/// and the `ModelContext`, which are main-actor bound in this app, so the whole
/// enum is `@MainActor`.
@MainActor
enum BackupService {
    static func makeBackup(deck: Deck) -> BackupV1 {
        let entries: [BackupV1.EntrySnapshot] = deck.cards.compactMap { entry in
            guard let card = entry.card else { return nil }
            return BackupV1.EntrySnapshot(
                scryfallId: card.scryfallId,
                quantity: entry.quantity,
                board: entry.board
            )
        }

        // Dedupe every referenced card (commander + entries) by scryfallId; the
        // snapshot only carries identity fields, everything else is re-fetched.
        var seen = Set<String>()
        var cards: [BackupV1.CardSnapshot] = []
        let referenced = [deck.commander].compactMap { $0 } + deck.cards.compactMap(\.card)
        for card in referenced where seen.insert(card.scryfallId).inserted {
            cards.append(
                BackupV1.CardSnapshot(
                    scryfallId: card.scryfallId,
                    oracleId: card.oracleId,
                    name: card.name,
                    setCode: card.setCode,
                    collectorNumber: card.collectorNumber,
                    typeLine: card.typeLine,
                    printedName: card.printedName,
                    lastScannedAt: card.lastScannedAt
                )
            )
        }

        return BackupV1(
            version: 1,
            exportedAt: .now,
            deck: BackupV1.DeckSnapshot(
                id: deck.id,
                name: deck.name,
                format: deck.format,
                commanderScryfallId: deck.commander?.scryfallId,
                entries: entries
            ),
            cards: cards
        )
    }

    /// Replace the entire deck with a snapshot. Wipes all user rows, rebuilds the
    /// identity-only cards/deck/entries, then leaves `setupComplete == false` so
    /// `ContentView` re-enters `SetupView`, whose `.task` runs the setup pipeline
    /// to re-fetch card data, images, rulings and the printings table for every
    /// card with an empty `frontImageUrl`.
    static func restore(_ backup: BackupV1, into modelContext: ModelContext) {
        try? modelContext.delete(model: DeckEntry.self)
        try? modelContext.delete(model: Deck.self)
        try? modelContext.delete(model: Card.self)
        try? modelContext.delete(model: Ruling.self)
        try? modelContext.delete(model: CollectorNumberEntry.self)

        var cardsByScryfallId: [String: Card] = [:]
        for snapshot in backup.cards {
            let card = Card(
                scryfallId: snapshot.scryfallId,
                oracleId: snapshot.oracleId,
                name: snapshot.name,
                setCode: snapshot.setCode,
                collectorNumber: snapshot.collectorNumber,
                oracleText: "",
                manaCost: "",
                typeLine: snapshot.typeLine,
                rarity: "",
                layout: "",
                // Empty image url marks the card for re-fetch by the setup pipeline.
                frontImageUrl: ""
            )
            card.printedName = snapshot.printedName
            card.lastScannedAt = snapshot.lastScannedAt
            modelContext.insert(card)
            cardsByScryfallId[snapshot.scryfallId] = card
        }

        let deck = Deck(
            id: backup.deck.id,
            name: backup.deck.name,
            format: backup.deck.format,
            commander: cardsByScryfallId[backup.deck.commanderScryfallId ?? ""]
        )
        modelContext.insert(deck)

        for snapshot in backup.deck.entries {
            let entry = DeckEntry(
                quantity: snapshot.quantity,
                board: snapshot.board,
                card: cardsByScryfallId[snapshot.scryfallId]
            )
            modelContext.insert(entry)
            deck.cards.append(entry)
        }

        try? modelContext.save()
    }
}
