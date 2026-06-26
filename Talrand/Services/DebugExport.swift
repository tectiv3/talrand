#if DEBUG
import Foundation
import SwiftData

/// One-time developer helper: dumps the *current* on-device deck (after any
/// card swaps) plus the full all-printings collision table to
/// `Documents/deck_index.json`, so it can be pulled off-device with `devicectl`
/// and used as the regression suite's deck fixture. Pull command:
///   xcrun devicectl device copy from --device soPro \
///     --domain-type appDataContainer --domain-identifier com.talrand.app \
///     --source Documents/deck_index.json --destination <local>
enum DebugExport {
    static func deckIndex(modelContext: ModelContext) {
        let cards = (try? modelContext.fetch(FetchDescriptor<Card>())) ?? []
        let entries = (try? modelContext.fetch(FetchDescriptor<CollectorNumberEntry>())) ?? []
        let payload: [String: Any] = [
            "cards": cards.map {
                ["scryfallId": $0.scryfallId, "name": $0.name, "typeLine": $0.typeLine, "printedName": $0.printedName]
            },
            "printings": entries.map {
                ["setCode": $0.setCode, "collectorNumber": $0.collectorNumber, "cardName": $0.cardName]
            },
        ]
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: dir.appendingPathComponent("deck_index.json"))
        print("[debug] wrote deck_index.json: \(cards.count) cards, \(entries.count) printing rows")
    }
}
#endif
