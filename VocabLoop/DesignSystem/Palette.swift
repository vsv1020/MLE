import SwiftUI
import UIKit

/// Semantic colour tokens.
///
/// Views name tokens, never raw colours. That is what makes a palette change a one-file
/// edit, and it is why there is no `Color(red:green:blue:)` anywhere in `Features/`.
///
/// Every token carries both a light and a dark value, resolved by `UIColor`'s dynamic
/// provider so it updates live when the user switches appearance — a `@Environment
/// (\.colorScheme)` check in each view would not, inside a UIKit-backed context.
///
/// All foreground/background pairings here are at or above 4.5:1 against their intended
/// surface, in both appearances.
public enum Palette {
    // MARK: Brand

    /// Primary actions, active tab, progress ring.
    public static let brandPrimary = Color(light: 0x4F46E5, dark: 0x818CF8)
    /// Accents and the streak flame.
    public static let brandSecondary = Color(light: 0x0D9488, dark: 0x2DD4BF)
    /// Tint for text and icons placed *on* `brandPrimary`.
    public static let onBrand = Color(light: 0xFFFFFF, dark: 0x0B1120)

    // MARK: Surfaces

    public static let canvas = Color(light: 0xF8FAFC, dark: 0x0B1120)
    public static let surface = Color(light: 0xFFFFFF, dark: 0x151C2E)
    public static let surfaceRaised = Color(light: 0xF1F5F9, dark: 0x1E293B)
    public static let separator = Color(light: 0xE2E8F0, dark: 0x25324A)

    // MARK: Text

    public static let textPrimary = Color(light: 0x0F172A, dark: 0xF8FAFC)
    public static let textSecondary = Color(light: 0x475569, dark: 0x94A3B8)
    public static let textTertiary = Color(light: 0x94A3B8, dark: 0x64748B)

    // MARK: Ratings

    /// The most semantically loaded colours in the app — consistent across the rating
    /// bar, statistics, forecast bars and history rows.
    ///
    /// Colour is always *redundant* here: every rating also carries a text label and a
    /// fixed position, because red-vs-green as the sole signal fails for the most common
    /// colour-vision deficiency.
    public static func rating(_ rating: Rating) -> Color {
        switch rating {
        case .again: Color(light: 0xDC2626, dark: 0xF87171)
        case .hard: Color(light: 0xD97706, dark: 0xFBBF24)
        case .good: Color(light: 0x059669, dark: 0x34D399)
        case .easy: Color(light: 0x2563EB, dark: 0x60A5FA)
        }
    }

    // MARK: Card maturity

    public static func maturity(_ maturity: CardMaturity) -> Color {
        switch maturity {
        case .new: Color(light: 0x94A3B8, dark: 0x64748B)
        case .learning: Color(light: 0xD97706, dark: 0xFBBF24)
        case .young: Color(light: 0x0D9488, dark: 0x2DD4BF)
        case .mature: Color(light: 0x4F46E5, dark: 0x818CF8)
        }
    }

    // MARK: Status

    public static let success = Color(light: 0x059669, dark: 0x34D399)
    public static let warning = Color(light: 0xD97706, dark: 0xFBBF24)
    public static let danger = Color(light: 0xDC2626, dark: 0xF87171)

    /// Heatmap fill for a day, scaled against the busiest day in the window.
    ///
    /// Intensity is bucketed rather than continuous: five steps read as a scale, whereas a
    /// smooth gradient reads as noise at 12×12pt.
    public static func heatmapLevel(_ reviews: Int, max maxReviews: Int) -> Color {
        guard reviews > 0, maxReviews > 0 else { return surfaceRaised }
        let ratio = Double(reviews) / Double(maxReviews)
        let bucket = min(4, max(1, Int(ceil(ratio * 4))))
        return brandSecondary.opacity(0.25 * Double(bucket))
    }
}

extension Color {
    /// Build a colour from two hex values, one per appearance.
    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(hex: dark)
                : UIColor(hex: light)
        })
    }

    /// Parse a `"#RRGGBB"` string, e.g. `Deck.colorHex`. `nil` when unparseable, so a bad
    /// value falls back to the brand colour rather than rendering black.
    public init?(hexString: String?) {
        guard let hexString else { return nil }
        var cleaned = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("#") { cleaned.removeFirst() }
        guard cleaned.count == 6, let value = UInt32(cleaned, radix: 16) else { return nil }
        self.init(uiColor: UIColor(hex: value))
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
