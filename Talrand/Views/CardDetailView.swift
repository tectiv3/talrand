import SwiftUI
import SwiftData

struct CardDetailView: View {
    let card: Card
    var onReplace: (() -> Void)?
    var allowRefresh: Bool = false

    @Environment(\.modelContext) private var modelContext
    @State private var showingBack = false
    @State private var cardImage: UIImage?
    @State private var showRulings = false

    private var isDFC: Bool {
        card.layout == "transform" || card.layout == "modal_dfc"
    }

    var body: some View {
        if allowRefresh {
            content.refreshable { await refresh() }
        } else {
            content
        }
    }

    private var content: some View {
        ScrollView {
            VStack(spacing: 0) {
                heroImage
                infoSection
                if !uniqueRulings.isEmpty {
                    rulingsSection
                }
                if let onReplace {
                    replaceSection(onReplace)
                }
            }
        }
        .background(MTGTheme.darkBg)
        .navigationTitle(card.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }

    private func refresh() async {
        let service = SetupService()
        await service.refetchCards([card], modelContext: modelContext)
        cardImage = await loadCurrentImage()
    }

    // MARK: - Hero Image

    private var heroImage: some View {
        VStack(spacing: 8) {
            Group {
                if let cardImage {
                    Image(uiImage: cardImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    imagePlaceholder
                }
            }
            .containerRelativeFrame(.horizontal) { width, _ in width * 0.8 }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(MTGTheme.cardBorder, lineWidth: 1)
            )
            .shadow(color: MTGTheme.gold.opacity(0.15), radius: 20, y: 8)
            .scaleEffect(x: showingBack ? -1 : 1, y: 1)
            .rotation3DEffect(
                .degrees(showingBack ? 180 : 0),
                axis: (x: 0, y: 1, z: 0)
            )
            .animation(.easeInOut(duration: 0.4), value: showingBack)
            .onTapGesture {
                if isDFC { showingBack.toggle() }
            }
            .frame(maxWidth: .infinity)
            .task(id: showingBack) {
                cardImage = await loadCurrentImage()
            }

            if isDFC {
                Label("Tap to flip", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(MTGTheme.textSecondary)
            }
        }
        .padding(.top, 12)
        .padding(.bottom, 16)
    }

    private var imagePlaceholder: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(MTGTheme.cardBg)
            .aspectRatio(2.5 / 3.5, contentMode: .fit)
            .overlay {
                VStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.title)
                        .foregroundStyle(MTGTheme.goldDim)
                    Text(card.name)
                        .font(.headline)
                        .foregroundStyle(MTGTheme.textPrimary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
            }
    }

    // MARK: - Info

    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(card.name)
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundStyle(MTGTheme.textPrimary)
                Spacer()
                if !card.manaCost.isEmpty {
                    ManaCostView(manaCost: card.manaCost, size: 22)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            HStack {
                Text(card.typeLine)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(MTGTheme.textPrimary)
                Spacer()
                if let power = card.power, let toughness = card.toughness {
                    ptBadge(power: power, toughness: toughness)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(MTGTheme.cardBorder.opacity(0.3))

            HStack(spacing: 6) {
                Text(card.setCode.uppercased())
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundStyle(MTGTheme.textSecondary)
                Text("•")
                    .foregroundStyle(MTGTheme.textSecondary)
                Text("#\(card.collectorNumber)")
                    .font(.caption)
                    .foregroundStyle(MTGTheme.textSecondary)
                Text("•")
                    .foregroundStyle(MTGTheme.textSecondary)
                Text(card.rarity.capitalized)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(MTGTheme.rarityColor(card.rarity))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            if !card.oracleText.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(card.oracleText.components(separatedBy: "\n").enumerated()), id: \.offset) { _, paragraph in
                        if !paragraph.isEmpty {
                            Text(paragraph)
                                .font(.body)
                                .foregroundStyle(MTGTheme.parchment)
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(MTGTheme.cardBg)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(MTGTheme.cardBorder.opacity(0.5), lineWidth: 1)
                        )
                )
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
        }
        .background(MTGTheme.darkBg)
    }

    // MARK: - P/T Badge

    private func ptBadge(power: String, toughness: String) -> some View {
        Text("\(power)/\(toughness)")
            .font(.subheadline)
            .fontWeight(.bold)
            .foregroundStyle(MTGTheme.textPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(MTGTheme.cardBg)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(MTGTheme.cardBorder, lineWidth: 1)
                    )
            )
    }

    // MARK: - Rulings

    private var uniqueRulings: [Ruling] {
        var seen = Set<String>()
        return card.rulings
            .sorted { $0.date > $1.date }
            .filter { seen.insert($0.comment).inserted }
    }

    private var rulingsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showRulings.toggle()
                }
            } label: {
                HStack {
                    Text("RULINGS")
                        .font(.caption)
                        .fontWeight(.heavy)
                        .tracking(1.5)
                        .foregroundStyle(MTGTheme.gold)
                    Text("\(uniqueRulings.count)")
                        .font(.caption2)
                        .fontWeight(.bold)
                        .foregroundStyle(MTGTheme.darkBg)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(MTGTheme.goldDim, in: Capsule())
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(MTGTheme.textSecondary)
                        .rotationEffect(.degrees(showRulings ? 90 : 0))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)

            if showRulings {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(uniqueRulings, id: \.comment) { ruling in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(ruling.date)
                                .font(.caption)
                                .foregroundStyle(MTGTheme.goldDim)
                            Text(ruling.comment)
                                .font(.callout)
                                .foregroundStyle(MTGTheme.parchment)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(MTGTheme.cardBg)
                        )
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
        }
    }

    // MARK: - Replace

    private func replaceSection(_ action: @escaping () -> Void) -> some View {
        Button {
            action()
        } label: {
            HStack {
                Image(systemName: "arrow.triangle.swap")
                Text("Replace Card")
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .foregroundStyle(MTGTheme.darkBg)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(MTGTheme.gold)
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
    }

    // MARK: - Image Loading

    private func loadCurrentImage() async -> UIImage? {
        let storedPath: String?
        if showingBack {
            storedPath = card.localBackImagePath
        } else {
            storedPath = card.localFrontImagePath
        }
        guard let storedPath, !storedPath.isEmpty else { return nil }
        return await Task.detached {
            let cache = ImageCacheService()
            guard let resolved = cache.resolvedPath(storedPath) else { return nil as UIImage? }
            return UIImage(contentsOfFile: resolved)
        }.value
    }
}

#Preview("Detail — Instant") {
    NavigationStack {
        CardDetailView(
            card: Card(
                scryfallId: "preview-1",
                oracleId: "oracle-1",
                name: "Mana Sculpt",
                setCode: "sos",
                collectorNumber: "57",
                oracleText: "Counter target spell. If you control a Wizard, add an amount of {C} equal to the amount of mana spent to cast that spell at the beginning of your next main phase.",
                manaCost: "{1}{U}{U}",
                typeLine: "Instant",
                colorIdentity: "U",
                rarity: "rare",
                layout: "normal",
                frontImageUrl: ""
            ),
            onReplace: {}
        )
    }
    .preferredColorScheme(.dark)
}

#Preview("Detail — Creature") {
    NavigationStack {
        CardDetailView(
            card: Card(
                scryfallId: "preview-2",
                oracleId: "oracle-2",
                name: "Talrand, Sky Summoner",
                setCode: "cmm",
                collectorNumber: "124",
                oracleText: "Whenever you cast an instant or sorcery spell, create a 2/2 blue Drake creature token with flying.",
                manaCost: "{2}{U}{U}",
                typeLine: "Legendary Creature — Merfolk Wizard",
                colorIdentity: "U",
                power: "2",
                toughness: "2",
                rarity: "rare",
                layout: "normal",
                frontImageUrl: ""
            )
        )
    }
    .preferredColorScheme(.dark)
}
