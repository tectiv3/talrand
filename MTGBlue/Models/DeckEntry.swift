import Foundation
import SwiftData

@Model
class DeckEntry {
    var quantity: Int

    @Relationship(deleteRule: .nullify)
    var card: Card?

    init(quantity: Int, card: Card? = nil) {
        self.quantity = quantity
        self.card = card
    }
}
