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
    /// `.heavy`, not `.bold`. See the note on ``statValue``.
    public static let screenTitle = Font.system(.title2, design: .rounded, weight: .heavy)
    public static let sectionHeader = Font.system(.headline, weight: .bold)
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
    ///
    /// `.black` rather than `.bold`, and this is the cheapest "more cartoon" change in the app:
    /// heavy weight on SF Rounded is what makes a number read as *drawn* rather than as data.
    /// Weight and not size, because size is Dynamic Type's to decide — and not `.width(.expanded)`,
    /// which is a no-op on SF Rounded and can silently drop the rounded design, nor `.tracking()`,
    /// which fights `monospacedDigit()`.
    ///
    /// Deliberately confined to numerals and headings. `wordDisplay`, `wordTitle`, `example`,
    /// `phonetic`, `caption` and `chip` keep their weights: those carry the language being taught,
    /// including Thai tone marks, where extra weight closes counters and costs legibility.
    public static let statValue = Font.system(.title, design: .rounded, weight: .black).monospacedDigit()
    public static let statValueSmall = Font.system(.title3, design: .rounded, weight: .heavy).monospacedDigit()
    /// Interval labels on the rating buttons.
    public static let buttonInterval = Font.system(.caption2, design: .rounded, weight: .semibold).monospacedDigit()
    public static let buttonLabel = Font.system(.body, design: .rounded, weight: .semibold)

    /// The decorative symbol at the top of an empty state, a launch screen, an auth step or the
    /// session summary.
    ///
    /// Seven sites hard-coded `.font(.system(size:))` at 40, 44, 44, 52, 52, 56 and 40 — six
    /// different numbers for one job. They were also the only fixed-size fonts in the app, which
    /// `DESIGN.md` states do not exist: a user at the largest accessibility size got body text
    /// twice its default and a hero glyph at exactly the same 44pt as everyone else.
    ///
    /// One token, `.largeTitle`, so these scale like the rest. It is a decoration, so the size is
    /// allowed to be whatever Dynamic Type says — nothing here depends on it.
    public static let heroGlyph = Font.system(.largeTitle, design: .rounded, weight: .bold)
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

/// Corner radii, pushed well past "friendly" into round — the Q look.
///
/// Roundness is most of what reads as *cute* before a single colour or face registers: a
/// shape with tight corners reads as a document, one with fat corners reads as a toy. These
/// are roughly half again the previous values (card 20, nested 14, button 14).
///
/// There is no chip radius: chips are `Capsule`s, which are fully round by construction at
/// every Dynamic Type size. A summary row in onboarding had been borrowing the chip value; it
/// is a nested panel and uses ``nested``.
public enum Radius {
    public static let card: CGFloat = 30
    public static let nested: CGFloat = 22
    public static let button: CGFloat = 22
}

public enum Elevation {
    /// One elevation *level*, now in two treatments — see ``CardContainer/Style``.
    ///
    /// Still no competing depths: a card is either soft-lit or cel-shaded, never both, and the
    /// two are mutually exclusive at the one call site that draws them. The `.sticker` treatment
    /// exists because these tokens have a bug they cannot fix from here: `shadowColor` is a fixed
    /// `Color.black.opacity(0.08)` rather than an adaptive one, so on the `#0B1120` dark canvas it
    /// is invisible and dark mode has had no depth cue at all.
    ///
    /// The `card(_:)` helper that used to live here was deleted rather than updated: zero call
    /// sites, and it duplicated these three literals in a form nothing could keep in sync.
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
