import Foundation
import SwiftData
import Observation

enum SetupError: Equatable {
    case networkError(cardName: String, underlying: String)
    case decodingError(cardName: String, underlying: String)

    static func == (lhs: SetupError, rhs: SetupError) -> Bool {
        switch (lhs, rhs) {
        case let (.networkError(lName, lErr), .networkError(rName, rErr)):
            return lName == rName && lErr == rErr
        case let (.decodingError(lName, lErr), .decodingError(rName, rErr)):
            return lName == rName && lErr == rErr
        default:
            return false
        }
    }

    var cardName: String {
        switch self {
        case .networkError(let name, _): return name
        case .decodingError(let name, _): return name
        }
    }

    var description: String {
        switch self {
        case .networkError(_, let underlying): return "Network error: \(underlying)"
        case .decodingError(_, let underlying): return "Decoding error: \(underlying)"
        }
    }
}

@Observable
class SetupService {
    var totalCards: Int = 0
    var completedCards: Int = 0
    var currentCardName: String = ""
    var error: SetupError? = nil
    var isComplete: Bool = false

    private let imageCache = ImageCacheService()
    private var errorContinuation: CheckedContinuation<ErrorResolution, Never>?

    private enum ErrorResolution {
        case retry
        case skip
    }

    func retryCurrentCard() {
        error = nil
        errorContinuation?.resume(returning: .retry)
        errorContinuation = nil
    }

    func skipCurrentCard() {
        error = nil
        errorContinuation?.resume(returning: .skip)
        errorContinuation = nil
    }

    @MainActor
    func performSetup(modelContext: ModelContext) async {
        let bundled = DeckLoader.loadBundledDeck()

        let existingDeck = try? modelContext.fetch(FetchDescriptor<Deck>()).first

        if let deck = existingDeck, deck.setupComplete {
            isComplete = true
            return
        }

        let deck = existingDeck ?? createDeckShell(from: bundled, modelContext: modelContext)

        let allCards = collectUniqueCards(from: deck)
        totalCards = allCards.count

        for card in allCards {
            guard card.frontImageUrl.isEmpty else {
                completedCards += 1
                continue
            }

            await fetchCardData(card: card, modelContext: modelContext)
        }

        deck.setupComplete = true
        try? modelContext.save()
        isComplete = true
    }

    @MainActor
    func refetchCards(_ cards: [Card], modelContext: ModelContext) async {
        for card in cards {
            card.frontImageUrl = ""
            card.localFrontImagePath = nil
            card.localBackImagePath = nil
            await fetchCardData(card: card, modelContext: modelContext)
        }
    }

    @MainActor
    private func createDeckShell(from bundled: BundledDeck, modelContext: ModelContext) -> Deck {
        let commanderCard = Card(
            scryfallId: bundled.commander.scryfallId,
            oracleId: "",
            name: bundled.commander.name,
            setCode: bundled.commander.setCode,
            collectorNumber: bundled.commander.collectorNumber,
            oracleText: bundled.commander.oracleText ?? "",
            manaCost: bundled.commander.manaCost ?? "",
            typeLine: bundled.commander.typeLine,
            power: bundled.commander.power,
            toughness: bundled.commander.toughness,
            rarity: bundled.commander.rarity,
            layout: bundled.commander.layout,
            frontImageUrl: ""
        )
        modelContext.insert(commanderCard)

        let deck = Deck(
            id: bundled.id,
            name: bundled.name,
            format: bundled.format,
            commander: commanderCard
        )
        modelContext.insert(deck)

        for bundledEntry in bundled.cards {
            let card = Card(
                scryfallId: bundledEntry.scryfallId,
                oracleId: "",
                name: bundledEntry.name,
                setCode: bundledEntry.setCode,
                collectorNumber: bundledEntry.collectorNumber,
                oracleText: bundledEntry.oracleText ?? "",
                manaCost: bundledEntry.manaCost ?? "",
                typeLine: bundledEntry.typeLine,
                power: bundledEntry.power,
                toughness: bundledEntry.toughness,
                rarity: bundledEntry.rarity,
                layout: bundledEntry.layout,
                frontImageUrl: ""
            )
            modelContext.insert(card)

            let entry = DeckEntry(quantity: bundledEntry.quantity, card: card)
            modelContext.insert(entry)
            deck.cards.append(entry)
        }

        for bundledEntry in bundled.sideboard {
            let card = Card(
                scryfallId: bundledEntry.scryfallId,
                oracleId: "",
                name: bundledEntry.name,
                setCode: bundledEntry.setCode,
                collectorNumber: bundledEntry.collectorNumber,
                oracleText: bundledEntry.oracleText ?? "",
                manaCost: bundledEntry.manaCost ?? "",
                typeLine: bundledEntry.typeLine,
                power: bundledEntry.power,
                toughness: bundledEntry.toughness,
                rarity: bundledEntry.rarity,
                layout: bundledEntry.layout,
                frontImageUrl: ""
            )
            modelContext.insert(card)

            let entry = DeckEntry(quantity: bundledEntry.quantity, board: "sideboard", card: card)
            modelContext.insert(entry)
            deck.cards.append(entry)
        }

        try? modelContext.save()
        return deck
    }

    private func collectUniqueCards(from deck: Deck) -> [Card] {
        var cards: [Card] = []
        if let commander = deck.commander {
            cards.append(commander)
        }
        for entry in deck.cards {
            if let card = entry.card {
                cards.append(card)
            }
        }
        return cards
    }

    @MainActor
    private func fetchCardData(card: Card, modelContext: ModelContext) async {
        guard card.frontImageUrl.isEmpty else {
            completedCards += 1
            return
        }

        currentCardName = card.name

        var shouldRetry = true
        while shouldRetry {
            shouldRetry = false

            do {
                let scryfallCard = try await ScryfallAPI.shared.fetchCard(scryfallId: card.scryfallId)

                card.oracleId = scryfallCard.oracleId ?? ""
                card.oracleText = scryfallCard.oracleText ?? ""
                card.manaCost = scryfallCard.manaCost ?? ""
                card.typeLine = scryfallCard.typeLine ?? card.typeLine
                card.power = scryfallCard.power
                card.toughness = scryfallCard.toughness
                card.colorIdentity = (scryfallCard.colorIdentity ?? []).joined(separator: ",")
                card.rarity = scryfallCard.rarity
                card.layout = scryfallCard.layout

                let frontURL = await ScryfallAPI.shared.imageUrl(for: scryfallCard, face: .front) ?? ""
                let backURL = await ScryfallAPI.shared.imageUrl(for: scryfallCard, face: .back)

                card.frontImageUrl = frontURL
                card.backImageUrl = backURL

                for existing in card.rulings {
                    modelContext.delete(existing)
                }
                card.rulings.removeAll()

                let rulings = try await ScryfallAPI.shared.fetchRulings(scryfallId: card.scryfallId)
                for ruling in rulings {
                    let rulingObj = Ruling(date: ruling.publishedAt, source: ruling.source, comment: ruling.comment)
                    modelContext.insert(rulingObj)
                    card.rulings.append(rulingObj)
                }

                let oracleId = scryfallCard.oracleId ?? ""
                let printings = oracleId.isEmpty ? [] : try await ScryfallAPI.shared.fetchAllPrintings(oracleId: oracleId)
                for printing in printings {
                    let entry = CollectorNumberEntry(
                        setCode: printing.set,
                        collectorNumber: printing.collectorNumber,
                        cardName: printing.name
                    )
                    modelContext.insert(entry)
                }

                if !frontURL.isEmpty {
                    let frontFilename = "\(card.scryfallId)_front.jpg"
                    let frontPath = try await imageCache.cacheImage(from: frontURL, filename: frontFilename)
                    card.localFrontImagePath = frontPath
                }

                let isDualFace = card.layout == "transform" || card.layout == "modal_dfc"
                if isDualFace, let backURL {
                    let backFilename = "\(card.scryfallId)_back.jpg"
                    let backPath = try await imageCache.cacheImage(from: backURL, filename: backFilename)
                    card.localBackImagePath = backPath
                }

                try? modelContext.save()
                completedCards += 1

            } catch let scryfallError as ScryfallError {
                let setupError: SetupError
                switch scryfallError {
                case .decodingError:
                    setupError = .decodingError(
                        cardName: card.name,
                        underlying: scryfallError.localizedDescription
                    )
                default:
                    setupError = .networkError(
                        cardName: card.name,
                        underlying: scryfallError.localizedDescription
                    )
                }

                error = setupError
                let resolution = await waitForUserResolution()
                switch resolution {
                case .retry:
                    shouldRetry = true
                case .skip:
                    // Mark as skipped so we don't re-attempt on resume
                    // Leave frontImageUrl empty -- next launch will retry
                    completedCards += 1
                }

            } catch {
                let setupError = SetupError.networkError(
                    cardName: card.name,
                    underlying: error.localizedDescription
                )
                self.error = setupError
                let resolution = await waitForUserResolution()
                switch resolution {
                case .retry:
                    shouldRetry = true
                case .skip:
                    completedCards += 1
                }
            }
        }
    }

    private func waitForUserResolution() async -> ErrorResolution {
        await withCheckedContinuation { continuation in
            errorContinuation = continuation
        }
    }
}
