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
        guard reviews > 0 else { return "今日目标完成" }
        return "今日目标完成，今天学了 \(RecapCopy.count(reviews, "个单词"))"
    }

    /// "7 days in a row".
    static func streakHeadline(days: Int) -> String {
        guard days > 0 else { return "准备开始新的连续打卡" }
        return "连续打卡 \(RecapCopy.count(days, "天"))"
    }

    /// "New badge: Night owl".
    static func badgeHeadline(name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "获得一枚新徽章" : "新徽章：\(trimmed)"
    }

    /// "Meet my Mochi — level 6".
    static func mochiHeadline(level: Int) -> String {
        "来看看我的麻薯：\(max(1, level)) 级"
    }

    /// "Today I learned ubiquitous". The card sets the word in italics; the plain string is what
    /// the share message and VoiceOver read.
    static func wordHeadline(headword: String) -> String {
        "\(wordHeadlinePrefix)\(headword)"
    }

    static let wordHeadlinePrefix = "今天我学会了 "

    /// "Page complete — 12 shining stickers".
    static func albumHeadline(stickers: Int) -> String {
        guard stickers > 0 else { return "这一页集齐了" }
        return "这一页集齐了：\(RecapCopy.count(stickers, "张闪亮贴纸"))"
    }

    // MARK: Eyebrows

    /// The small caption above the headline.
    static func eyebrow(_ kind: ShareCard.Kind) -> String {
        switch kind {
        case .goal: return "每日目标"
        case .streak: return "我的连续打卡"
        case .badge: return "新徽章"
        case .mochi: return "我的麻薯"
        case .word: return "新词"
        case .album: return "贴纸册"
        case .week: return "我在麻薯背单词的一周"
        }
    }

    // MARK: Card details

    /// "5 min"; `nil` for zero, which the card leaves out rather than printing.
    static func minutes(_ minutes: Int) -> String? {
        guard minutes > 0 else { return nil }
        return RecapCopy.count(minutes, "分钟")
    }

    /// "7-day streak"; `nil` when no streak is running.
    static func streakChip(_ days: Int) -> String? {
        guard days > 0 else { return nil }
        return "连续打卡 \(days) 天"
    }

    /// "Goal: 30 a day".
    static func goalChip(_ goal: Int) -> String? {
        guard goal > 0 else { return nil }
        return "目标：每天 \(goal) 个"
    }

    /// "Best: 12 days" — offered only when the best run is longer than the current one, so it
    /// reads as a record, never as a comparison the child is losing.
    static func longestChip(current: Int, longest: Int) -> String? {
        guard longest > current, longest > 0 else { return nil }
        return "最长：\(RecapCopy.count(longest, "天"))"
    }

    /// "1,240 star candy".
    static func candy(_ candy: Int) -> String {
        "\(max(0, candy).formatted()) 颗星星糖"
    }

    /// "Earned 12 Sep" — a date only, never a time.
    static func earned(_ date: Date, locale: Locale = Locale(identifier: "zh_Hans")) -> String {
        "获得于 \(date.formatted(.dateTime.day().month(.abbreviated).locale(locale)))"
    }

    // MARK: Footer and message

    static let appName = "麻薯背单词"
    static let invite = "和麻薯一起背单词"

    /// `apps.apple.com/app/id6800027452` — the link as printed on the card.
    static var appStoreShortLink: String {
        let raw = AppLinks.appStore.absoluteString
        return raw.hasPrefix("https://") ? String(raw.dropFirst("https://".count)) : raw
    }

    static let subject = "我的麻薯背单词卡片"

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
