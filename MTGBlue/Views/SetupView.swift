import SwiftUI
import SwiftData

struct SetupView: View {
    @State private var setupService = SetupService()
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            headerSection

            if setupService.error != nil {
                errorSection
            } else {
                progressSection
            }

            Spacer()
            Spacer()
        }
        .padding(.horizontal, 32)
        .task {
            await setupService.performSetup(modelContext: modelContext)
        }
    }

    private var headerSection: some View {
        VStack(spacing: 8) {
            Image(systemName: "rectangle.stack.fill")
                .font(.system(size: 56))
                .foregroundStyle(.blue)

            Text("MTG Blue")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Setting up your deck...")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var progressSection: some View {
        VStack(spacing: 12) {
            if setupService.totalCards > 0 {
                ProgressView(
                    value: Double(setupService.completedCards),
                    total: Double(setupService.totalCards)
                )

                Text("Fetching card \(setupService.completedCards)/\(setupService.totalCards)...")
                    .font(.subheadline)
                    .monospacedDigit()

                if !setupService.currentCardName.isEmpty {
                    Text(setupService.currentCardName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } else {
                ProgressView()
                Text("Loading deck data...")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var errorSection: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title)
                .foregroundStyle(.orange)

            if let error = setupService.error {
                Text("Failed to fetch \(error.cardName)")
                    .font(.headline)

                Text(error.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 16) {
                Button("Skip") {
                    setupService.skipCurrentCard()
                }
                .buttonStyle(.bordered)

                Button("Retry") {
                    setupService.retryCurrentCard()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}

#Preview {
    SetupView()
        .modelContainer(
            for: [Card.self, Deck.self, DeckEntry.self, CollectorNumberEntry.self, Ruling.self],
            inMemory: true
        )
}
