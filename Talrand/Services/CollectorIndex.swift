import Foundation
import SwiftData

/// Single source of truth for a card's collector-number index. Pure SwiftData
/// logic with no network, so the setup and pull-to-refresh paths share it and it
/// can be unit-tested with an in-memory store.
enum CollectorIndex {
    /// Replace every `CollectorNumberEntry` for `cardName` with `entries`.
    /// Idempotent: `CollectorNumberEntry` has no `Card` relationship, so rows are
    /// matched by name; clearing them before inserting means a repeated refresh
    /// never accumulates duplicates.
    static func replace(cardName: String, with entries: [CollectorNumberEntry], in modelContext: ModelContext) {
        let existing = (try? modelContext.fetch(
            FetchDescriptor<CollectorNumberEntry>(predicate: #Predicate { $0.cardName == cardName })
        )) ?? []
        for entry in existing {
            modelContext.delete(entry)
        }
        for entry in entries {
            modelContext.insert(entry)
        }
    }
}
