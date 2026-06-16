import Foundation
import SwiftData
import Observation

@Observable
class CardSwapService {
    var state: SwapState = .scanning
    var newCard: Card? = nil
    var errorMessage: String? = nil

    enum SwapState {
        case scanning
        case fetching
        case confirming
        case error
        case completed
    }

    private let imageCache = ImageCacheService()

    // MARK: - Handle a card already in the local DB (matched by scanner)

    func handleScannedCard(_ card: Card, replacing oldCard: Card) {
        if card.scryfallId == oldCard.scryfallId {
            errorMessage = "That's the same card"
            state = .error
            return
        }

        newCard = card
        state = .confirming
    }

    // MARK: - Handle a card identified by set/collector number (not yet in DB)

    @MainActor
    func handleNewCardFromScan(
        setCode: String,
        collectorNumber: String,
        replacing oldCard: Card,
        modelContext: ModelContext
    ) async {
        state = .fetching

        do {
            let scryfallCard = try await ScryfallAPI.shared.fetchCardBySetAndNumber(
                setCode: setCode,
                collectorNumber: collectorNumber
            )

            let card = createCard(from: scryfallCard)
            modelContext.insert(card)

            let rulings = try await ScryfallAPI.shared.fetchRulings(scryfallId: scryfallCard.id)
            for ruling in rulings {
                let rulingObj = Ruling(date: ruling.publishedAt, source: ruling.source, comment: ruling.comment)
                modelContext.insert(rulingObj)
                card.rulings.append(rulingObj)
            }

            try await cacheImages(for: card, from: scryfallCard)

            let printings = try await ScryfallAPI.shared.fetchAllPrintings(oracleId: scryfallCard.oracleId)
            for printing in printings {
                let entry = CollectorNumberEntry(
                    setCode: printing.set,
                    collectorNumber: printing.collectorNumber,
                    cardName: printing.name
                )
                modelContext.insert(entry)
            }

            try? modelContext.save()

            newCard = card
            state = .confirming

        } catch {
            errorMessage = error.localizedDescription
            state = .error
        }
    }

    // MARK: - Handle a card selected from search results

    @MainActor
    func handleSearchResult(
        _ scryfallCard: ScryfallCard,
        replacing oldCard: Card,
        modelContext: ModelContext
    ) async {
        if scryfallCard.oracleId == oldCard.oracleId {
            errorMessage = "That's the same card"
            state = .error
            return
        }

        state = .fetching

        do {
            let card = createCard(from: scryfallCard)
            modelContext.insert(card)

            let rulings = try await ScryfallAPI.shared.fetchRulings(scryfallId: scryfallCard.id)
            for ruling in rulings {
                let rulingObj = Ruling(date: ruling.publishedAt, source: ruling.source, comment: ruling.comment)
                modelContext.insert(rulingObj)
                card.rulings.append(rulingObj)
            }

            try await cacheImages(for: card, from: scryfallCard)

            let printings = try await ScryfallAPI.shared.fetchAllPrintings(oracleId: scryfallCard.oracleId)
            for printing in printings {
                let entry = CollectorNumberEntry(
                    setCode: printing.set,
                    collectorNumber: printing.collectorNumber,
                    cardName: printing.name
                )
                modelContext.insert(entry)
            }

            try? modelContext.save()

            newCard = card
            state = .confirming

        } catch {
            errorMessage = error.localizedDescription
            state = .error
        }
    }

    // MARK: - Confirm the swap in the deck

    @MainActor
    func confirmSwap(oldCard: Card, in deck: Deck, modelContext: ModelContext) {
        guard let newCard else { return }

        // Find the DeckEntry referencing the old card and replace it
        if let entryIndex = deck.cards.firstIndex(where: { $0.card?.scryfallId == oldCard.scryfallId }) {
            let oldEntry = deck.cards[entryIndex]
            let quantity = oldEntry.quantity

            let newEntry = DeckEntry(quantity: quantity, card: newCard)
            modelContext.insert(newEntry)
            deck.cards.remove(at: entryIndex)
            deck.cards.append(newEntry)

            modelContext.delete(oldEntry)
        }

        // Clean up old card's cached images
        if let frontPath = oldCard.localFrontImagePath {
            let frontFilename = (frontPath as NSString).lastPathComponent
            imageCache.deleteImage(filename: frontFilename)
        }
        if let backPath = oldCard.localBackImagePath {
            let backFilename = (backPath as NSString).lastPathComponent
            imageCache.deleteImage(filename: backFilename)
        }

        // Remove old card's CollectorNumberEntry records only if no other card shares the oracle ID
        let oldOracleId = oldCard.oracleId
        let oldCardName = oldCard.name
        var descriptor = FetchDescriptor<Card>(
            predicate: #Predicate<Card> { card in
                card.oracleId == oldOracleId
            }
        )
        descriptor.fetchLimit = 2
        let remainingCards = (try? modelContext.fetch(descriptor)) ?? []
        // The old card is still in context until deleted; if it's the only one, clean up entries
        let othersExist = remainingCards.contains { $0.scryfallId != oldCard.scryfallId }
        if !othersExist {
            var entryDescriptor = FetchDescriptor<CollectorNumberEntry>(
                predicate: #Predicate<CollectorNumberEntry> { entry in
                    entry.cardName == oldCardName
                }
            )
            entryDescriptor.fetchLimit = 500
            if let entries = try? modelContext.fetch(entryDescriptor) {
                for entry in entries {
                    modelContext.delete(entry)
                }
            }
        }

        modelContext.delete(oldCard)
        try? modelContext.save()

        state = .completed
    }

    // MARK: - Retry after error

    func retry() {
        errorMessage = nil
        state = .scanning
    }

    // MARK: - Search

    func searchCards(query: String) async throws -> [ScryfallCard] {
        try await ScryfallAPI.shared.searchCards(query: query)
    }

    // MARK: - Private Helpers

    private func createCard(from scryfall: ScryfallCard) -> Card {
        let frontURL = resolveFrontImageUrl(for: scryfall)
        let backURL = resolveBackImageUrl(for: scryfall)

        return Card(
            scryfallId: scryfall.id,
            oracleId: scryfall.oracleId,
            name: scryfall.name,
            setCode: scryfall.set,
            collectorNumber: scryfall.collectorNumber,
            oracleText: scryfall.oracleText ?? "",
            manaCost: scryfall.manaCost ?? "",
            typeLine: scryfall.typeLine,
            power: scryfall.power,
            toughness: scryfall.toughness,
            rarity: scryfall.rarity,
            layout: scryfall.layout,
            frontImageUrl: frontURL,
            backImageUrl: backURL
        )
    }

    private func resolveFrontImageUrl(for card: ScryfallCard) -> String {
        let dualFaceLayouts: Set<String> = ["transform", "modal_dfc"]
        if dualFaceLayouts.contains(card.layout) {
            return card.cardFaces?.first?.imageUris?.normal ?? ""
        }
        return card.imageUris?.normal ?? ""
    }

    private func resolveBackImageUrl(for card: ScryfallCard) -> String? {
        let dualFaceLayouts: Set<String> = ["transform", "modal_dfc"]
        if dualFaceLayouts.contains(card.layout) {
            return card.cardFaces?.dropFirst().first?.imageUris?.normal
        }
        return nil
    }

    private func cacheImages(for card: Card, from scryfall: ScryfallCard) async throws {
        if !card.frontImageUrl.isEmpty {
            let frontFilename = "\(card.scryfallId)_front.jpg"
            let frontPath = try await imageCache.cacheImage(from: card.frontImageUrl, filename: frontFilename)
            card.localFrontImagePath = frontPath
        }

        let isDualFace = card.layout == "transform" || card.layout == "modal_dfc"
        if isDualFace, let backURL = card.backImageUrl, !backURL.isEmpty {
            let backFilename = "\(card.scryfallId)_back.jpg"
            let backPath = try await imageCache.cacheImage(from: backURL, filename: backFilename)
            card.localBackImagePath = backPath
        }
    }
}
