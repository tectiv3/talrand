import Foundation
import SwiftData

@Model
class CollectorNumberEntry {
    var setCode: String
    var collectorNumber: String
    var cardName: String

    init(setCode: String, collectorNumber: String, cardName: String) {
        self.setCode = setCode
        self.collectorNumber = collectorNumber
        self.cardName = cardName
    }
}
