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
    // Once set, every subsequent fetch failure auto-skips without prompting, so a
    // rate-limit storm can't force one tap per failing card.
    private var skipAll = false

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

    func skipAllRemaining() {
        skipAll = true
        error = nil
        errorContinuation?.resume(returning: .skip)
        errorContinuation = nil
    }

    /// Resolve a fetch failure: auto-skip when "Skip All" is active, otherwise
    /// surface the error screen and wait for the user's choice.
    private func resolveFailure(_ setupError: SetupError) async -> ErrorResolution {
        if skipAll { return .skip }
        error = setupError
        return await waitForUserResolution()
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
    func performBackfill(deck: Deck, modelContext: ModelContext) async {
        let bundled = DeckLoader.loadBundledDeck()
        let addedSideboard = backfillSideboard(deck: deck, bundled: bundled, modelContext: modelContext)
        if addedSideboard {
            let sideboardCards = deck.cards.filter { $0.board == "sideboard" }.compactMap(\.card)
            for card in sideboardCards where card.frontImageUrl.isEmpty {
                await fetchCardData(card: card, modelContext: modelContext)
            }
        }
        await backfillPrintedNames(deck: deck, modelContext: modelContext)
    }

    /// One-time-per-card fetch of the Japanese printed name. Runs on launch for
    /// existing installs (the schema default is "") so the name-scan path works
    /// without a full re-sync; only cards still missing a name hit the network.
    @MainActor
    private func backfillPrintedNames(deck: Deck, modelContext: ModelContext) async {
        let cards = deck.cards.compactMap(\.card)
        for card in cards where card.printedName.isEmpty && !card.oracleId.isEmpty {
            if let jp = await ScryfallAPI.shared.fetchLocalizedName(oracleId: card.oracleId, lang: "ja") {
                card.printedName = jp
                try? modelContext.save()
            }
            try? await Task.sleep(for: .milliseconds(120))
        }
    }

    @MainActor
    func refetchCards(_ cards: [Card], modelContext: ModelContext) async {
        for card in cards {
            await refetchCard(card, modelContext: modelContext)
        }
    }

    /// Self-contained refresh that never blocks on the setup error-resolution
    /// continuation (that only has a UI driver during initial setup, so reusing
    /// it here would deadlock the spinner forever). New images are downloaded
    /// into hand before anything is overwritten, so a failed/slow fetch leaves
    /// the existing card and its image untouched.
    @MainActor
    private func refetchCard(_ card: Card, modelContext: ModelContext) async {
        do {
            let scryfallCard = try await ScryfallAPI.shared.fetchCard(scryfallId: card.scryfallId)

            let frontURL = await ScryfallAPI.shared.imageUrl(for: scryfallCard, face: .front) ?? ""
            let backURL = await ScryfallAPI.shared.imageUrl(for: scryfallCard, face: .back)

            // Download every image and printing into hand before mutating the
            // model, so a mid-refresh failure throws and leaves the existing
            // card + cached image intact (commit only after network success).
            let images = try await cacheImages(for: card, scryfallCard: scryfallCard, frontURL: frontURL, backURL: backURL)
            let printings = try await fetchPrintings(oracleId: scryfallCard.oracleId ?? "")
            let rulings = try await ScryfallAPI.shared.fetchRulings(scryfallId: card.scryfallId)

            // Every network op succeeded — now it is safe to commit.
            applyScryfallFields(scryfallCard, to: card, frontURL: frontURL, backURL: backURL)
            if let path = images.front { card.localFrontImagePath = path }
            if let path = images.back { card.localBackImagePath = path }
            applyRulings(rulings, to: card, modelContext: modelContext)
            applyPrintings(printings, to: card, modelContext: modelContext)

            try? modelContext.save()
        } catch {
            // Leave the existing card data and cached image intact.
            print("[refetch] \(card.name) failed: \(error.localizedDescription)")
        }
    }

    /// Copy the Scryfall payload onto the persisted Card. Pure model mutation,
    /// no network — callers fetch images/URLs separately.
    private func applyScryfallFields(_ scryfallCard: ScryfallCard, to card: Card, frontURL: String, backURL: String?) {
        card.oracleId = scryfallCard.oracleId ?? ""
        card.oracleText = scryfallCard.oracleText ?? ""
        card.manaCost = scryfallCard.manaCost ?? ""
        card.typeLine = scryfallCard.typeLine ?? card.typeLine
        card.power = scryfallCard.power
        card.toughness = scryfallCard.toughness
        card.colorIdentity = (scryfallCard.colorIdentity ?? []).joined(separator: ",")
        card.rarity = scryfallCard.rarity
        card.layout = scryfallCard.layout
        card.frontImageUrl = frontURL
        card.backImageUrl = backURL
    }

    /// Download front/back images for the card. Returns the cached local paths
    /// without touching the model, so callers can defer the commit until after
    /// every network op has succeeded.
    private func cacheImages(
        for card: Card,
        scryfallCard: ScryfallCard,
        frontURL: String,
        backURL: String?
    ) async throws -> (front: String?, back: String?) {
        var frontPath: String?
        if !frontURL.isEmpty {
            frontPath = try await imageCache.cacheImage(from: frontURL, filename: "\(card.scryfallId)_front.jpg")
        }

        let isDualFace = scryfallCard.layout == "transform" || scryfallCard.layout == "modal_dfc"
        var backPath: String?
        if isDualFace, let backURL {
            backPath = try await imageCache.cacheImage(from: backURL, filename: "\(card.scryfallId)_back.jpg")
        }

        return (frontPath, backPath)
    }

    private func fetchPrintings(oracleId: String) async throws -> [ScryfallCard] {
        oracleId.isEmpty ? [] : try await ScryfallAPI.shared.fetchAllPrintings(oracleId: oracleId)
    }

    @MainActor
    private func applyRulings(_ rulings: [ScryfallRuling], to card: Card, modelContext: ModelContext) {
        for existing in card.rulings {
            modelContext.delete(existing)
        }
        card.rulings.removeAll()
        for ruling in rulings {
            let rulingObj = Ruling(date: ruling.publishedAt, source: ruling.source, comment: ruling.comment)
            modelContext.insert(rulingObj)
            card.rulings.append(rulingObj)
        }
    }

    @MainActor
    private func applyPrintings(_ printings: [ScryfallCard], to card: Card, modelContext: ModelContext) {
        let entries = printings.map {
            CollectorNumberEntry(setCode: $0.set, collectorNumber: $0.collectorNumber, cardName: $0.name)
        }
        CollectorIndex.replace(cardName: card.name, with: entries, in: modelContext)
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

    @MainActor
    private func backfillSideboard(deck: Deck, bundled: BundledDeck, modelContext: ModelContext) -> Bool {
        let hasSideboard = deck.cards.contains { $0.board == "sideboard" }
        guard !hasSideboard, !bundled.sideboard.isEmpty else { return false }

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
        return true
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

                let frontURL = await ScryfallAPI.shared.imageUrl(for: scryfallCard, face: .front) ?? ""
                let backURL = await ScryfallAPI.shared.imageUrl(for: scryfallCard, face: .back)

                applyScryfallFields(scryfallCard, to: card, frontURL: frontURL, backURL: backURL)

                let rulings = try await ScryfallAPI.shared.fetchRulings(scryfallId: card.scryfallId)
                applyRulings(rulings, to: card, modelContext: modelContext)

                let printings = try await fetchPrintings(oracleId: scryfallCard.oracleId ?? "")
                applyPrintings(printings, to: card, modelContext: modelContext)

                let images = try await cacheImages(for: card, scryfallCard: scryfallCard, frontURL: frontURL, backURL: backURL)
                if let path = images.front { card.localFrontImagePath = path }
                if let path = images.back { card.localBackImagePath = path }

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

                let resolution = await resolveFailure(setupError)
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
                let resolution = await resolveFailure(setupError)
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
