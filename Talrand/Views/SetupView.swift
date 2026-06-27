import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct SetupView: View {
    @State private var setupService = SetupService()
    @Environment(\.modelContext) private var modelContext

    // The setup screen no longer auto-fetches. The user first picks a path; only
    // then does the fetch pipeline run. This is also the recovery entry point.
    @State private var phase: Phase = .choosing
    @State private var isImporting = false
    @State private var restoreError: String?

    private enum Phase {
        case choosing
        case working
    }

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            headerSection

            switch phase {
            case .choosing:
                choiceSection
            case .working:
                if setupService.error != nil {
                    errorSection
                } else {
                    progressSection
                }
            }

            Spacer()
            Spacer()
        }
        .padding(.horizontal, 32)
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.json]) { result in
            handleImport(result)
        }
        .alert(
            "Restore Failed",
            isPresented: Binding(
                get: { restoreError != nil },
                set: { if !$0 { restoreError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { restoreError = nil }
        } message: {
            Text(restoreError ?? "")
        }
    }

    private var headerSection: some View {
        VStack(spacing: 8) {
            Image(systemName: "rectangle.stack.fill")
                .font(.system(size: 56))
                .foregroundStyle(.blue)

            Text("Talrand")
                .font(.largeTitle)
                .fontWeight(.bold)

            if phase == .working {
                Text("Setting up your deck...")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Text("Fetching card data, images & rulings from Scryfall")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            } else {
                Text("Your Commander deck companion")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var choiceSection: some View {
        VStack(spacing: 16) {
            Button {
                phase = .working
                Task { await setupService.performSetup(modelContext: modelContext) }
            } label: {
                Label("Continue with Default Deck", systemImage: "rectangle.stack.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Button {
                isImporting = true
            } label: {
                Label("Restore from Backup…", systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
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

            Button("Skip All Remaining") {
                setupService.skipAllRemaining()
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
    }

    private func handleImport(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                let backup = try BackupCodec.decode(data)
                BackupService.restore(backup, into: modelContext)
                phase = .working
                Task { await setupService.performSetup(modelContext: modelContext) }
            } catch {
                restoreError = error.localizedDescription
            }
        case .failure(let error):
            restoreError = error.localizedDescription
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
