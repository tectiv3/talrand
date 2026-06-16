import SwiftUI

struct ManaCostView: View {
    let manaCost: String
    var size: CGFloat = 16

    private var symbols: [String] {
        var result: [String] = []
        var i = manaCost.startIndex
        while i < manaCost.endIndex {
            if manaCost[i] == "{" {
                if let close = manaCost[i...].firstIndex(of: "}") {
                    let code = String(manaCost[manaCost.index(after: i)..<close])
                    result.append(code)
                    i = manaCost.index(after: close)
                } else {
                    i = manaCost.index(after: i)
                }
            } else {
                i = manaCost.index(after: i)
            }
        }
        return result
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(symbols.enumerated()), id: \.offset) { _, symbol in
                manaCircle(symbol)
            }
        }
    }

    private func manaCircle(_ symbol: String) -> some View {
        ZStack {
            Circle()
                .fill(manaColor(symbol))
            Circle()
                .strokeBorder(.black.opacity(0.3), lineWidth: 0.5)
            Text(manaLabel(symbol))
                .font(.system(size: size * 0.6, weight: .bold, design: .rounded))
                .foregroundStyle(manaTextColor(symbol))
        }
        .frame(width: size, height: size)
    }

    private func manaColor(_ symbol: String) -> Color {
        switch symbol {
        case "W": return Color(red: 0.96, green: 0.93, blue: 0.82)
        case "U": return Color(red: 0.17, green: 0.41, blue: 0.72)
        case "B": return Color(red: 0.24, green: 0.20, blue: 0.26)
        case "R": return Color(red: 0.85, green: 0.27, blue: 0.17)
        case "G": return Color(red: 0.15, green: 0.52, blue: 0.27)
        case "C": return Color(red: 0.78, green: 0.78, blue: 0.80)
        case "X": return Color(red: 0.78, green: 0.78, blue: 0.80)
        case "T": return Color(red: 0.78, green: 0.78, blue: 0.80)
        default: return Color(red: 0.78, green: 0.78, blue: 0.80)
        }
    }

    private func manaTextColor(_ symbol: String) -> Color {
        switch symbol {
        case "W": return .black
        case "U", "B", "R", "G": return .white
        default: return .black
        }
    }

    private func manaLabel(_ symbol: String) -> String {
        switch symbol {
        case "T": return "T"
        case "X": return "X"
        case "C": return "C"
        default: return symbol
        }
    }
}

#Preview("Mana Costs") {
    VStack(alignment: .leading, spacing: 16) {
        ManaCostView(manaCost: "{1}{U}{U}", size: 20)
        ManaCostView(manaCost: "{3}{W}{U}{B}{R}{G}", size: 20)
        ManaCostView(manaCost: "{X}{R}{R}", size: 20)
        ManaCostView(manaCost: "{2}{G}", size: 14)
    }
    .padding()
    .background(.black)
}
