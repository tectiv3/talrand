import SwiftUI

enum MTGTheme {
    static let darkBg = Color(red: 0.08, green: 0.07, blue: 0.10)
    static let cardBg = Color(red: 0.13, green: 0.12, blue: 0.16)
    static let cardBorder = Color(red: 0.35, green: 0.30, blue: 0.20)
    static let gold = Color(red: 0.82, green: 0.68, blue: 0.36)
    static let goldDim = Color(red: 0.55, green: 0.45, blue: 0.25)
    static let parchment = Color(red: 0.92, green: 0.88, blue: 0.80)
    static let textPrimary = Color(red: 0.93, green: 0.91, blue: 0.87)
    static let textSecondary = Color(red: 0.60, green: 0.57, blue: 0.52)

    static func categoryColor(_ category: String) -> Color {
        switch category {
        case "Creature": return Color(red: 0.15, green: 0.52, blue: 0.27)
        case "Planeswalker": return Color(red: 0.60, green: 0.40, blue: 0.70)
        case "Instant": return Color(red: 0.17, green: 0.41, blue: 0.72)
        case "Sorcery": return Color(red: 0.85, green: 0.27, blue: 0.17)
        case "Artifact": return Color(red: 0.55, green: 0.55, blue: 0.58)
        case "Enchantment": return Color(red: 0.96, green: 0.93, blue: 0.82)
        case "Battle": return Color(red: 0.85, green: 0.55, blue: 0.17)
        case "Land": return Color(red: 0.50, green: 0.40, blue: 0.30)
        case "Sideboard": return MTGTheme.goldDim
        default: return MTGTheme.textSecondary
        }
    }

    static func rarityColor(_ rarity: String) -> Color {
        switch rarity.lowercased() {
        case "mythic": return Color(red: 0.90, green: 0.45, blue: 0.15)
        case "rare": return gold
        case "uncommon": return Color(red: 0.65, green: 0.65, blue: 0.70)
        default: return textSecondary
        }
    }
}
