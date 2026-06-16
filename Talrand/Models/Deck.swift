import Foundation
import SwiftData

@Model
class Deck {
    var id: String
    var name: String
    var format: String
    var lastSynced: Date
    var setupComplete: Bool

    @Relationship(deleteRule: .nullify)
    var commander: Card?

    @Relationship(deleteRule: .cascade)
    var cards: [DeckEntry]

    init(
        id: String,
        name: String,
        format: String,
        lastSynced: Date = .now,
        setupComplete: Bool = false,
        commander: Card? = nil,
        cards: [DeckEntry] = []
    ) {
        self.id = id
        self.name = name
        self.format = format
        self.lastSynced = lastSynced
        self.setupComplete = setupComplete
        self.commander = commander
        self.cards = cards
    }
}
