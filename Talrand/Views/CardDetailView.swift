import SwiftUI
import SwiftData

struct CardDetailView: View {
    let card: Card
    var onReplace: (() -> Void)?

    @Environment(\.modelContext) private var modelContext
    @State private var showingBack = false
    @State private var cardImage: UIImage?

    private var isDFC: Bool {
        card.layout == "transform" || card.layout == "modal_dfc"
    }

    var body: some View {
        List {
            Section {
                cardImageView
                cardInfo
            }
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))

            if !uniqueRulings.isEmpty || !card.rulings.isEmpty {
                Section {
                    rulingsSection
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            }

            if onReplace != nil {
                Section {
                    replaceButton
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            }
        }
        .listStyle(.plain)
        .textSelection(.enabled)
        .navigationTitle(card.name)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            let service = SetupService()
            await service.refetchCards([card], modelContext: modelContext)
            cardImage = await loadCurrentImage()
        }
    }

    // MARK: - Card Image

    @ViewBuilder
    private var cardImageView: some View {
        VStack(spacing: 6) {
            Group {
                if let cardImage {
                    Image(uiImage: cardImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    imagePlaceholder
                }
            }
            .containerRelativeFrame(.horizontal) { width, _ in width * 0.7 }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .rotation3DEffect(
                .degrees(showingBack ? 180 : 0),
                axis: (x: 0, y: 1, z: 0)
            )
            .animation(.easeInOut(duration: 0.4), value: showingBack)
            .onTapGesture {
                if isDFC {
                    showingBack.toggle()
                }
            }
            .frame(maxWidth: .infinity)
            .task(id: showingBack) {
                cardImage = await loadCurrentImage()
            }

            if isDFC {
                Text("Tap to flip")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func loadCurrentImage() async -> UIImage? {
        let storedPath = showingBack ? card.localBackImagePath : card.localFrontImagePath
        guard let storedPath, !storedPath.isEmpty else { return nil }
        return await Task.detached {
            let cache = ImageCacheService()
            guard let resolved = cache.resolvedPath(storedPath) else { return nil as UIImage? }
            return UIImage(contentsOfFile: resolved)
        }.value
    }

    private var imagePlaceholder: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(.blue.opacity(0.3))
            .aspectRatio(2.5 / 3.5, contentMode: .fit)
            .overlay {
                Text(card.name)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding()
            }
    }

    // MARK: - Card Info

    private var cardInfo: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(card.name)
                .font(.title)
                .bold()

            if !card.manaCost.isEmpty {
                Text(card.manaCost)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Text(card.typeLine)
                .font(.subheadline)

            if let power = card.power, let toughness = card.toughness {
                Text("Power/Toughness: \(power)/\(toughness)")
                    .font(.subheadline)
            }

            Divider()

            if !card.oracleText.isEmpty {
                oracleTextView
                ManaSymbolLegend(text: card.manaCost + " " + card.oracleText)
                    .padding(.top, 4)
            }
        }
    }

    private var oracleTextView: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(card.oracleText.components(separatedBy: "\n").enumerated()), id: \.offset) { _, paragraph in
                if !paragraph.isEmpty {
                    Text(paragraph)
                        .font(.body)
                }
            }
        }
    }

    // MARK: - Rulings

    private var uniqueRulings: [Ruling] {
        var seen = Set<String>()
        return card.rulings
            .sorted { $0.date > $1.date }
            .filter { seen.insert($0.comment).inserted }
    }

    private var rulingsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rulings")
                .font(.headline)

            if uniqueRulings.isEmpty {
                Text("No rulings for this card")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(uniqueRulings, id: \.comment) { ruling in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(ruling.date)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(ruling.comment)
                            .font(.body)
                    }
                }
            }
        }
    }

    // MARK: - Replace Button

    @ViewBuilder
    private var replaceButton: some View {
        if let onReplace {
            Button("Replace Card") {
                onReplace()
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
        }
    }
}
