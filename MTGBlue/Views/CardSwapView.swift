import SwiftUI
import SwiftData

struct CardSwapView: View {
    let oldCard: Card

    @State private var swapService = CardSwapService()
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var showingSearch = false
    @State private var searchQuery = ""
    @State private var searchResults: [ScryfallCard] = []
    @State private var isSearching = false
    @State private var searchError: String? = nil

    @Query private var decks: [Deck]
    private var deck: Deck? { decks.first }

    var body: some View {
        NavigationStack {
            Group {
                switch swapService.state {
                case .scanning:
                    scanningView
                case .fetching:
                    fetchingView
                case .confirming:
                    confirmingView
                case .error:
                    errorView
                case .completed:
                    Color.clear.onAppear { dismiss() }
                }
            }
            .navigationTitle("Replace Card")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    // MARK: - Scanning State

    private var scanningView: some View {
        VStack(spacing: 0) {
            headerBanner

            if showingSearch {
                searchView
            } else {
                cameraScannerSection
            }
        }
    }

    private var headerBanner: some View {
        VStack(spacing: 4) {
            Text("Scan replacement for:")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(oldCard.name)
                .font(.headline)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private var cameraScannerSection: some View {
        ZStack(alignment: .bottom) {
            CameraScannerView(
                mode: .swap,
                onCardMatched: { matchedCard in
                    guard let deck else { return }
                    swapService.handleScannedCard(matchedCard, replacing: oldCard, in: deck)
                }
            )

            Button {
                showingSearch = true
            } label: {
                Label("Search by Name", systemImage: "magnifyingglass")
                    .font(.subheadline.bold())
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .padding(.bottom, 24)
        }
    }

    // MARK: - Search Fallback

    private var searchView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("Card name", text: $searchQuery)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .onSubmit { performSearch() }

                Button("Search") { performSearch() }
                    .buttonStyle(.bordered)
                    .disabled(searchQuery.trimmingCharacters(in: .whitespaces).isEmpty || isSearching)
            }
            .padding()

            if isSearching {
                ProgressView("Searching...")
                    .padding()
                Spacer()
            } else if let searchError {
                Text(searchError)
                    .foregroundStyle(.red)
                    .padding()
                Spacer()
            } else if searchResults.isEmpty && !searchQuery.isEmpty {
                ContentUnavailableView.search(text: searchQuery)
            } else {
                List(searchResults, id: \.id) { result in
                    Button {
                        selectSearchResult(result)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(result.name)
                                .font(.body)
                                .foregroundStyle(.primary)
                            Text("\(result.set.uppercased()) #\(result.collectorNumber) — \(result.rarity.capitalized)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
                .listStyle(.plain)
            }

            HStack {
                Button {
                    showingSearch = false
                    searchQuery = ""
                    searchResults = []
                    searchError = nil
                } label: {
                    Label("Back to Scanner", systemImage: "camera")
                }
                .padding()

                Spacer()
            }
        }
    }

    // MARK: - Fetching State

    private var fetchingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("Looking up card...")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Confirming State

    private var confirmingView: some View {
        VStack(spacing: 24) {
            Spacer()

            HStack(alignment: .top, spacing: 20) {
                cardPreview(card: oldCard, label: "Removing", tint: .red)
                Image(systemName: "arrow.right")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .padding(.top, 60)
                if let newCard = swapService.newCard {
                    cardPreview(card: newCard, label: "Adding", tint: .green)
                }
            }
            .padding(.horizontal)

            Spacer()

            VStack(spacing: 12) {
                Button {
                    guard let deck else { return }
                    swapService.confirmSwap(oldCard: oldCard, in: deck, modelContext: modelContext)
                } label: {
                    Text("Confirm Swap")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .controlSize(.large)

                Button("Cancel") { dismiss() }
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
    }

    private func cardPreview(card: Card, label: String, tint: Color) -> some View {
        VStack(spacing: 8) {
            Text(label)
                .font(.caption.bold())
                .foregroundStyle(tint)
                .textCase(.uppercase)

            if let path = card.resolvedFrontImagePath,
               let uiImage = UIImage(contentsOfFile: path) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(tint.opacity(0.15))
                    .frame(width: 120, height: 168)
                    .overlay {
                        Text(card.name)
                            .font(.caption)
                            .multilineTextAlignment(.center)
                            .padding(4)
                    }
            }

            Text(card.name)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: 120)
        }
    }

    // MARK: - Error State

    private var errorView: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundStyle(.orange)

            Text(swapService.errorMessage ?? "Something went wrong")
                .font(.body)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            VStack(spacing: 12) {
                Button("Try Again") { swapService.retry() }
                    .buttonStyle(.borderedProminent)

                Button("Cancel") { dismiss() }
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }

    // MARK: - Actions

    private func performSearch() {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        isSearching = true
        searchError = nil
        searchResults = []

        Task {
            do {
                let results = try await swapService.searchCards(query: trimmed)
                searchResults = results
            } catch {
                searchError = error.localizedDescription
            }
            isSearching = false
        }
    }

    private func selectSearchResult(_ result: ScryfallCard) {
        guard let deck else { return }
        Task {
            await swapService.handleSearchResult(
                result,
                replacing: oldCard,
                in: deck,
                modelContext: modelContext
            )
        }
    }
}
