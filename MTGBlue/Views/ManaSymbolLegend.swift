import SwiftUI

struct ManaSymbolLegend: View {
    let text: String

    private static let symbols: [(code: String, label: String)] = [
        ("{T}", "Tap this permanent"),
        ("{Q}", "Untap this permanent"),
        ("{C}", "Colorless mana"),
        ("{W}", "White mana"),
        ("{U}", "Blue mana"),
        ("{B}", "Black mana"),
        ("{R}", "Red mana"),
        ("{G}", "Green mana"),
        ("{W/U}", "White or Blue mana"),
        ("{W/B}", "White or Black mana"),
        ("{U/B}", "Blue or Black mana"),
        ("{U/R}", "Blue or Red mana"),
        ("{B/R}", "Black or Red mana"),
        ("{B/G}", "Black or Green mana"),
        ("{R/G}", "Red or Green mana"),
        ("{R/W}", "Red or White mana"),
        ("{G/W}", "Green or White mana"),
        ("{G/U}", "Green or Blue mana"),
        ("{X}", "Variable mana (you choose)"),
        ("{0}", "Zero mana"),
        ("{1}", "One generic mana"),
        ("{2}", "Two generic mana"),
        ("{3}", "Three generic mana"),
        ("{4}", "Four generic mana"),
        ("{5}", "Five generic mana"),
        ("{6}", "Six generic mana"),
        ("{7}", "Seven generic mana"),
        ("{8}", "Eight generic mana"),
        ("{9}", "Nine generic mana"),
        ("{10}", "Ten generic mana"),
    ]

    private var presentSymbols: [(code: String, label: String)] {
        Self.symbols.filter { text.contains($0.code) }
    }

    var body: some View {
        if !presentSymbols.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(presentSymbols, id: \.code) { symbol in
                    HStack(spacing: 8) {
                        Text(symbol.code)
                            .font(.caption)
                            .fontWeight(.semibold)
                            .monospacedDigit()
                            .frame(minWidth: 28, alignment: .center)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(.blue.opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                        Text(symbol.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
