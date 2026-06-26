import Foundation

/// The deck-resolution decision shared by the live scanner and its tests: given
/// an OCR'd collector-number candidate, pick the single deck card it identifies.
///
/// Pure — the data access (deck-card and all-printings lookups) is injected as
/// closures, so production drives it from SwiftData while tests drive it from a
/// bundled printings snapshot. Keeping the decision here rather than inline in
/// the scanner view means a regression like "Ravenform resolves to Ponder" is
/// caught by a test exercising the exact code production runs.
struct DeckResolver<Card> {
    /// The deck `Card` with this exact name, if any.
    let cardNamed: (String) -> Card?
    /// The card name printed at `setCode`+`collectorNumber` across all printings.
    let nameForSetNumber: (_ setCode: String, _ collectorNumber: String) -> String?
    /// Every deck-card name that has *some* printing at this collector number.
    let namesForNumber: (_ collectorNumber: String) -> Set<String>
    let scryfallId: (Card) -> String
    let typeLine: (Card) -> String

    func resolve(_ candidate: CollectorNumberCandidate, type: String?, nearestId: String?) -> Card? {
        // Set code + number is unique — trust it directly.
        if let setCode = candidate.setCode,
           let name = nameForSetNumber(setCode, candidate.collectorNumber) {
            return cardNamed(name)
        }

        // Number alone can map to several deck cards (each has a printing with
        // that number). Accept only when it resolves to exactly one — otherwise
        // disambiguate before guessing.
        let cards = namesForNumber(candidate.collectorNumber).compactMap(cardNamed)
        if cards.count == 1 { return cards.first }
        guard cards.count > 1 else { return nil }

        // Fusion: feature-print can't fire on its own for a different-printing
        // card, but its nearest neighbour still ranks the right card first.
        // Constraining that hint to the number's candidate set makes it safe.
        if let nearestId, let hit = cards.first(where: { scryfallId($0) == nearestId }) {
            return hit
        }

        // Fall back to the OCR'd card type to break the tie.
        if let type {
            let matched = cards.filter { typeLine($0).localizedCaseInsensitiveContains(type) }
            if matched.count == 1 { return matched.first }
        }
        return nil
    }
}
