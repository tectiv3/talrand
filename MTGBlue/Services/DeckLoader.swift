import Foundation

struct BundledCard: Codable {
    let name: String
    let scryfallId: String
    let setCode: String
    let collectorNumber: String
    let layout: String
    let oracleText: String
    let manaCost: String
    let typeLine: String
    let power: String?
    let toughness: String?
    let rarity: String
}

struct BundledCardEntry: Codable {
    let quantity: Int
    let name: String
    let scryfallId: String
    let setCode: String
    let collectorNumber: String
    let layout: String
    let oracleText: String
    let manaCost: String
    let typeLine: String
    let power: String?
    let toughness: String?
    let rarity: String
}

struct BundledDeck: Codable {
    let id: String
    let name: String
    let format: String
    let commander: BundledCard
    let cards: [BundledCardEntry]
}

struct DeckLoader {
    static func loadBundledDeck() -> BundledDeck {
        guard let url = Bundle.main.url(forResource: "deck", withExtension: "json") else {
            fatalError("deck.json not found in app bundle")
        }

        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            return try decoder.decode(BundledDeck.self, from: data)
        } catch {
            fatalError("Failed to decode deck.json: \(error)")
        }
    }
}
