import Foundation

/// Every sentence on a share card, as pure functions (sharing plan §1).
///
/// House rules as ``RecapCopy``: celebrate what happened, never count what did not. No "only",
/// "missed", "failed" or "lost" — `ShareCopyTests.testNeverMentionsFailure` checks every headline
/// over a grid of inputs.
enum ShareCopy {
    // MARK: Headlines

    /// "Daily goal done — 30 words today".
    static func goalHeadline(reviews: Int) -> String {
        guard reviews > 0 else { return "Daily goal done today" }
        return "Daily goal done — \(RecapCopy.count(reviews, "word")) today"
    }

    /// "7 days in a row".
    static func streakHeadline(days: Int) -> String {
        guard days > 0 else { return "Ready for a new streak" }
        return "\(RecapCopy.count(days, "day")) in a row"
    }

    /// "New badge: Night owl".
    static func badgeHeadline(name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "A new badge" : "New badge: \(trimmed)"
    }

    /// "Meet my Mochi — level 6".
    static func mochiHeadline(level: Int) -> String {
        "Meet my Mochi — level \(max(1, level))"
    }

    /// "Today I learned ubiquitous". The card sets the word in italics; the plain string is what
    /// the share message and VoiceOver read.
    static func wordHeadline(headword: String) -> String {
        "\(wordHeadlinePrefix)\(headword)"
    }

    static let wordHeadlinePrefix = "Today I learned "

    /// "Page complete — 12 shining stickers".
    static func albumHeadline(stickers: Int) -> String {
        guard stickers > 0 else { return "Page complete" }
        return "Page complete — \(RecapCopy.count(stickers, "shining sticker"))"
    }

    // MARK: Eyebrows

    /// The small caption above the headline.
    static func eyebrow(_ kind: ShareCard.Kind) -> String {
        switch kind {
        case .goal: return "Daily goal"
        case .streak: return "My streak"
        case .badge: return "New badge"
        case .mochi: return "My Mochi"
        case .word: return "New word"
        case .album: return "Sticker book"
        case .week: return "My week on VocabLoop"
        }
    }

    // MARK: Card details

    /// "5 min"; `nil` for zero, which the card leaves out rather than printing.
    static func minutes(_ minutes: Int) -> String? {
        guard minutes > 0 else { return nil }
        return RecapCopy.count(minutes, "min", "min")
    }

    /// "7-day streak"; `nil` when no streak is running.
    static func streakChip(_ days: Int) -> String? {
        guard days > 0 else { return nil }
        return "\(days)-day streak"
    }

    /// "Goal: 30 a day".
    static func goalChip(_ goal: Int) -> String? {
        guard goal > 0 else { return nil }
        return "Goal: \(goal) a day"
    }

    /// "Best: 12 days" — offered only when the best run is longer than the current one, so it
    /// reads as a record, never as a comparison the child is losing.
    static func longestChip(current: Int, longest: Int) -> String? {
        guard longest > current, longest > 0 else { return nil }
        return "Best: \(RecapCopy.count(longest, "day"))"
    }

    /// "1,240 star candy".
    static func candy(_ candy: Int) -> String {
        "\(max(0, candy).formatted()) star candy"
    }

    /// "Earned 12 Sep" — a date only, never a time.
    static func earned(_ date: Date, locale: Locale = .current) -> String {
        "Earned \(date.formatted(.dateTime.day().month(.abbreviated).locale(locale)))"
    }

    // MARK: Footer and message

    static let appName = "VocabLoop"
    static let invite = "Learn words with Mochi"

    /// `apps.apple.com/app/id6800027452` — the link as printed on the card.
    static var appStoreShortLink: String {
        let raw = AppLinks.appStore.absoluteString
        return raw.hasPrefix("https://") ? String(raw.dropFirst("https://".count)) : raw
    }

    static let subject = "My VocabLoop card"

    /// Headline plus the full link, so the link survives targets that drop the image.
    static func message(headline: String) -> String {
        "\(headline) · \(AppLinks.appStore.absoluteString)"
    }

    // MARK: Example emphasis

    /// Splits an example sentence around the headword so the card can emphasise it.
    ///
    /// Prefers the pack's cloze marking (`"She {{lent}} me…"`), which catches irregular forms,
    /// then a case-insensitive match of the headword; `nil` when neither finds it — the sentence
    /// is then shown plain.
    static func emphasis(in example: String, cloze: String?, headword: String) -> (before: String, match: String, after: String)? {
        if let cloze,
           let open = cloze.range(of: "{{"),
           let close = cloze.range(of: "}}", range: open.upperBound..<cloze.endIndex) {
            let before = String(cloze[..<open.lowerBound])
            let match = String(cloze[open.upperBound..<close.lowerBound])
            let after = String(cloze[close.upperBound...])
                .replacingOccurrences(of: "{{", with: "")
                .replacingOccurrences(of: "}}", with: "")
            if !match.isEmpty { return (before, match, after) }
        }
        let needle = headword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty,
              let range = example.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive])
        else { return nil }
        return (String(example[..<range.lowerBound]), String(example[range]), String(example[range.upperBound...]))
    }
}
