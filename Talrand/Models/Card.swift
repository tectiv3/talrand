import Foundation
import SwiftData

@Model
class Card: Hashable {
    var scryfallId: String
    var oracleId: String
    var name: String
    var setCode: String
    var collectorNumber: String
    var oracleText: String
    var manaCost: String
    var typeLine: String
    var power: String?
    var toughness: String?
    var colorIdentity: String
    var rarity: String
    var layout: String
    var frontImageUrl: String
    var backImageUrl: String?
    var localFrontImagePath: String?
    var localBackImagePath: String?

    @Relationship(deleteRule: .cascade)
    var rulings: [Ruling]

    init(
        scryfallId: String,
        oracleId: String,
        name: String,
        setCode: String,
        collectorNumber: String,
        oracleText: String,
        manaCost: String,
        typeLine: String,
        colorIdentity: String = "",
        power: String? = nil,
        toughness: String? = nil,
        rarity: String,
        layout: String,
        frontImageUrl: String,
        backImageUrl: String? = nil,
        localFrontImagePath: String? = nil,
        localBackImagePath: String? = nil,
        rulings: [Ruling] = []
    ) {
        self.scryfallId = scryfallId
        self.oracleId = oracleId
        self.name = name
        self.setCode = setCode
        self.collectorNumber = collectorNumber
        self.oracleText = oracleText
        self.manaCost = manaCost
        self.typeLine = typeLine
        self.power = power
        self.toughness = toughness
        self.colorIdentity = colorIdentity
        self.rarity = rarity
        self.layout = layout
        self.frontImageUrl = frontImageUrl
        self.backImageUrl = backImageUrl
        self.localFrontImagePath = localFrontImagePath
        self.localBackImagePath = localBackImagePath
        self.rulings = rulings
    }

    var isBasicLand: Bool {
        typeLine.contains("Basic Land")
    }

    private static let imageCache = ImageCacheService()

    var resolvedFrontImagePath: String? {
        guard let path = localFrontImagePath, !path.isEmpty else { return nil }
        return Self.imageCache.resolvedPath(path)
    }

    var resolvedBackImagePath: String? {
        guard let path = localBackImagePath, !path.isEmpty else { return nil }
        return Self.imageCache.resolvedPath(path)
    }

    static func == (lhs: Card, rhs: Card) -> Bool {
        lhs.scryfallId == rhs.scryfallId
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(scryfallId)
    }
}
