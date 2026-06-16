import SwiftUI
import SwiftData

@main
struct MTGBlueApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: [
            Card.self,
            Deck.self,
            DeckEntry.self,
            CollectorNumberEntry.self,
            Ruling.self,
        ])
    }
}
