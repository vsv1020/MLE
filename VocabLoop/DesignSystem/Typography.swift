import SwiftUI

/// Type scale.
///
/// Every entry is built on a Dynamic Type text style, never `.system(size:)`, so the whole
/// app scales with the user's setting. A vocabulary app whose definitions cannot be
/// enlarged is unusable for a large fraction of the people who most want it.
public enum Typography {
    /// The word itself on a flashcard — the largest thing on screen, by design.
    public static let wordDisplay = Font.system(.largeTitle, design: .rounded, weight: .bold)
    /// A word in a list row or detail header.
    public static let wordTitle = Font.system(.title2, design: .rounded, weight: .bold)
    public static let screenTitle = Font.system(.title2, design: .rounded, weight: .bold)
    public static let sectionHeader = Font.system(.headline, weight: .semibold)
    public static let body = Font.system(.body)
    public static let bodyEmphasis = Font.system(.body, weight: .semibold)

    /// Example sentences, in serif italic.
    ///
    /// The single most useful typographic distinction in a dictionary UI: it separates
    /// "language being taught" from "app chrome" without a label or a box.
    public static let example = Font.system(.callout, design: .serif)

    /// Phonetics, monospaced so IPA symbols keep their width and do not jitter as the
    /// transcription changes between cards.
    public static let phonetic = Font.system(.subheadline, design: .monospaced)

    public static let caption = Font.system(.caption, design: .rounded, weight: .medium)
    public static let chip = Font.system(.caption2, design: .rounded, weight: .semibold)

    /// Large numeric statistics, with monospaced digits so a counting animation does not
    /// make the layout twitch.
    public static let statValue = Font.system(.title, design: .rounded, weight: .bold).monospacedDigit()
    public static let statValueSmall = Font.system(.title3, design: .rounded, weight: .bold).monospacedDigit()
    /// Interval labels on the rating buttons.
    public static let buttonInterval = Font.system(.caption2, design: .rounded, weight: .semibold).monospacedDigit()
    public static let buttonLabel = Font.system(.body, design: .rounded, weight: .semibold)
}

/// 4pt spacing scale. Views use these rather than literals, so vertical rhythm stays
/// consistent when a screen is edited by someone who has not read the design doc.
public enum Spacing {
    public static let xxs: CGFloat = 4
    public static let xs: CGFloat = 8
    public static let sm: CGFloat = 12
    /// Standard screen gutter.
    public static let md: CGFloat = 16
    public static let lg: CGFloat = 24
    public static let xl: CGFloat = 32
    public static let xxl: CGFloat = 48
}

public enum Radius {
    public static let card: CGFloat = 20
    public static let nested: CGFloat = 14
    public static let chip: CGFloat = 8
    public static let button: CGFloat = 14
}

public enum Elevation {
    /// One elevation only. Two competing shadow levels always look accidental, and a
    /// third makes a screen look like a slide deck.
    public static func card(_ isRaised: Bool = true) -> some View {
        Color.clear
            .shadow(color: .black.opacity(isRaised ? 0.08 : 0), radius: 16, x: 0, y: 4)
    }

    public static let shadowColor = Color.black.opacity(0.08)
    public static let shadowRadius: CGFloat = 16
    public static let shadowY: CGFloat = 4
}

/// Minimum interactive size, per Apple's Human Interface Guidelines.
public enum LayoutMetrics {
    public static let minimumTapTarget: CGFloat = 44
    /// Cap line length on iPad — a definition running the full width of a 13" screen is
    /// genuinely harder to read than one at phone width.
    public static let maximumContentWidth: CGFloat = 680
}
