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

    /// Primary actions, active tab, progress ring. Crayon blue / chalk blue.
    public static let brandPrimary = Color(light: 0x2A62A8, dark: 0x8FBEF0)
    /// Accents and the streak flame.
    ///
    /// Used as *text* in CEFR chips and the streak counter, so the light value is burnt sienna
    /// rather than the brighter orange a crayon box actually contains — 5.36:1 on paper.
    public static let brandSecondary = Color(light: 0xA9501C, dark: 0xF0A868)
    /// Tint for text and icons placed *on* `brandPrimary`.
    public static let onBrand = Color(light: 0xFFFDF6, dark: 0x1B211D)

    // MARK: Surfaces

    /// Paper in light, blackboard in dark.
    ///
    /// The three tones are deliberately close together — closer than the scale they
    /// replaced. Paper does not come in three obviously different shades, and the previous gap
    /// between `surface` and `surfaceRaised` was wide enough that ``textTertiary`` could not
    /// clear 4.5:1 on the darker one without collapsing into ``textSecondary``. Tightening the
    /// surfaces is what buys the third text tone its own identity.
    public static let canvas = Color(light: 0xF7EFDC, dark: 0x1B211D)
    public static let surface = Color(light: 0xFFFDF6, dark: 0x262D28)
    public static let surfaceRaised = Color(light: 0xFCF6E9, dark: 0x2F3831)

    /// Not a hairline any more — in this design system the separator *is* the drawn outline,
    /// so it is full-strength ink rather than a tint of the background.
    public static let separator = Color(light: 0x33291F, dark: 0xC9C4B2)

    // MARK: Text

    /// Crayon black is never actually black — it is a very dark warm brown, which is what
    /// keeps the page from reading as a printed document.
    public static let textPrimary = Color(light: 0x33291F, dark: 0xF4F0E2)
    public static let textSecondary = Color(light: 0x6B5C46, dark: 0xC2BCA8)
    /// Timestamps, hints, field captions.
    ///
    /// Tertiary text still *carries information* — a due date, an interval, a usage hint — so
    /// WCAG's exception for incidental text does not apply to it. Clears 4.60:1 at worst (on
    /// `canvas`, the darkest paper tone) while staying visibly lighter than ``textSecondary``:
    /// 5.17:1 against 6.36:1 on `surface`.
    public static let textTertiary = Color(light: 0x786A54, dark: 0xA8A18C)

    // MARK: Ratings

    /// The most semantically loaded colours in the app — consistent across the rating
    /// bar, statistics, forecast bars and history rows.
    ///
    /// Colour is always *redundant* here: every rating also carries a text label and a
    /// fixed position, because red-vs-green as the sole signal fails for the most common
    /// colour-vision deficiency.
    ///
    /// Bright fills with dark ink, and one value per rating rather than one per appearance.
    ///
    /// These used to be *darker* in light mode than the obvious 600-weight picks, for a stated
    /// reason: the rating bar set its labels in white, and white needs a dark fill underneath to
    /// clear 4.5:1. So the four colours the user looks at hundreds of times a day were the
    /// dullest in the app — and dulled by the accessibility requirement, which is the worst way
    /// to lose a palette argument.
    ///
    /// Inverting the pairing wins both at once. Dark ink on a 400-weight fill reads at **5.28:1
    /// at worst** against the previous scheme's 4.83:1, and the fills go from muted to poster
    /// bright. Brighter *and* more legible; the old scheme had it backwards.
    ///
    /// One value per rating also fixes a quiet inconsistency: light Hard was amber-700 while
    /// dark Hard was amber-400, so the same self-assessment was a different colour depending on
    /// the time of day.
    public static func rating(_ rating: Rating) -> Color {
        switch rating {
        case .again: Color(light: 0xFB7185, dark: 0xFB7185)
        case .hard: Color(light: 0xFBBF24, dark: 0xFBBF24)
        case .good: Color(light: 0x34D399, dark: 0x34D399)
        case .easy: Color(light: 0x60A5FA, dark: 0x60A5FA)
        }
    }

    /// Outline for a ``rating(_:)`` fill. Always drawn, never optional.
    ///
    /// This is what makes the bright fills legal, and it is not decoration. A 400-weight fill on
    /// paper is only 1.46:1 at worst — the amber bar on `surface` — and the
    /// rating colours are not just button backgrounds: they are the bars on the session summary
    /// and the history dots in entry detail, which are graphical objects WCAG 1.4.11 holds to
    /// 3:1. Without an edge, brightening the fills would have made the *data* invisible while
    /// making the buttons prettier.
    ///
    /// A darker shade of the same hue clears 6.19:1 against every paper tone and 3.43–4.25:1
    /// against its own fill, so the shape has a boundary from both sides. In dark mode the edge
    /// is redundant — the fill is already 4.51:1 against the nearest blackboard tone — but it is
    /// kept there anyway, because a hard outline is the whole cel-shaded idea and dropping it in
    /// one appearance would make the two look like different apps.
    public static func ratingEdge(_ rating: Rating) -> Color {
        switch rating {
        // rose-900 rather than rose-800: rose-800 came in at 2.98:1 against its own fill, which
        // rounds to 3 and is not the same as clearing it.
        case .again: Color(light: 0x881337, dark: 0x881337)
        case .hard: Color(light: 0x92400E, dark: 0x92400E)
        case .good: Color(light: 0x065F46, dark: 0x065F46)
        case .easy: Color(light: 0x1E40AF, dark: 0x1E40AF)
        }
    }

    /// Foreground for text placed *on* a ``rating(_:)`` fill.
    ///
    /// Dark in both appearances now, because the fills are bright in both. Previously this was
    /// white in light mode and near-black in dark mode — a split that existed only because the
    /// light fills were dark. Warm ink now, so it belongs to the paper. Every pairing it
    /// produces is at or above 4.5:1: the worst 5.28:1 (light Again), the best 9.81:1 (dark Hard).
    ///
    /// One foreground per scheme rather than per rating, so the four buttons stay consistent
    /// with each other.
    public static let onRating = Color(light: 0x33291F, dark: 0x1B211D)

    // MARK: Status

    public static let success = Color(light: 0x2F7A46, dark: 0x86D9A0)
    public static let warning = Color(light: 0x9A5B10, dark: 0xF2C46B)
    public static let danger = Color(light: 0xA83228, dark: 0xF2938A)

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
