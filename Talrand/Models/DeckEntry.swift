import Foundation
import SwiftData

@Model
class DeckEntry {
    var quantity: Int
    var board: String

    @Relationship(deleteRule: .nullify)
    var card: Card?

    init(quantity: Int, board: String = "mainboard", card: Card? = nil) {
        self.quantity = quantity
        self.board = board
        self.card = card
    }
}
