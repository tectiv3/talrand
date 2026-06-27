import SwiftUI
import SwiftData

@main
struct TalrandApp: App {
    let container: ModelContainer

    init() {
        let schema = Schema([
            Card.self,
            Deck.self,
            DeckEntry.self,
            CollectorNumberEntry.self,
            Ruling.self,
        ])
        // The iCloud entitlement (used for the iCloud Drive JSON backup) makes
        // SwiftData default to a CloudKit-backed store. This model isn't CloudKit-
        // compatible (non-optional attributes, relationships without inverses), so
        // that store fails to load and SwiftData falls back to an in-memory
        // container — silently losing all persistence. We never want CloudKit sync
        // here, so disable it explicitly and keep a plain on-disk store.
        let config = ModelConfiguration(schema: schema, cloudKitDatabase: .none)
        do {
            container = try ModelContainer(for: schema, configurations: config)
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(container)
    }
}
