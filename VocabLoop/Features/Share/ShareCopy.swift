import Foundation

/// Every sentence on a share card, as pure functions (sharing plan §1).
///
/// House rules as ``RecapCopy``: celebrate what happened, never count what did not. No "only",
/// "missed", "failed" or "lost" — `ShareCopyTests.testNeverMentionsFailure` checks every headline
/// over a grid of inputs.
enum ShareCopy {
    // MARK: Sharer

    /// The name printed at the top of a poster, or `nil` to print none: guests and placeholder
    /// names ("游客", "我") stay anonymous. Trimmed and capped so a long name cannot crowd the card.
    static func sharerName(displayName: String?, isGuest: Bool) -> String? {
        guard !isGuest, let raw = displayName else { return nil }
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !placeholderNames.contains(name.lowercased()) else { return nil }
        return name.count > 16 ? String(name.prefix(15)) + "…" : name
    }

    static let placeholderNames: Set<String> = ["游客", "我", "guest", "?"]

    // MARK: Headlines

    /// "Daily goal done — 30 words today".
    static func goalHeadline(reviews: Int) -> String {
        guard reviews > 0 else { return "今日目标完成" }
        // Reviews are cards, not distinct words: a word studied both ways is two reviews.
        return "今日目标完成：复习了 \(RecapCopy.count(reviews, "张卡片"))"
    }

    /// The week poster's headline, in the sharer's own voice. The in-app recap talks to the
    /// learner ("这周你…"); a poster is the learner talking to friends.
    static func weekHeadline(wordsMastered: Int) -> String {
        wordsMastered < 1 ? "这周我的单词一直在长大" : "这周我掌握了 \(wordsMastered) 个单词"
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

    /// The poster footer: the app's name, one line on what it is, and how to get it. No printed
    /// link — the footer carries a QR code for ``AppLinks/appStoreChina`` instead.
    static let appName = "麻薯背单词"
    static let slogan = "打开就背，会记住的单词卡"
    static let qrHint = "长按识别二维码，或在 App Store 搜索「麻薯背单词」"

    static let subject = "我的麻薯背单词卡片"

    /// The text that travels with the poster: the headline and the China App Store link, so a
    /// friend can still find the app when the target drops the image or shows only the text.
    /// "我在用麻薯背单词背单词：连续打卡 7 天。下载：https://apps.apple.com/cn/app/id6800027452".
    static func message(headline: String) -> String {
        let trimmed = headline.trimmingCharacters(in: .whitespacesAndNewlines)
        let link = AppLinks.appStoreChina.absoluteString
        guard let last = trimmed.last else { return "我在用麻薯背单词背单词。下载：\(link)" }
        let stop = "。！？!?…".contains(last) ? "" : "。"
        return "我在用麻薯背单词背单词：\(trimmed)\(stop)下载：\(link)"
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
