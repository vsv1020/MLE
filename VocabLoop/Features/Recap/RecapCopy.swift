import Foundation

/// Every sentence the recap surfaces say, in one place, as pure functions.
///
/// Pure so ``RecapHeadlineTests`` can pin the wording without a store, and in one place so the
/// Progress card, the share image and the parent report never phrase the same number two ways.
///
/// House rules for this copy (engagement plan §1.9, §1.10): celebrate what happened, never
/// count what did not. No "only", no "missed", no "failed"; tricky words are "worth another
/// look".
enum RecapCopy {
    // MARK: Headline

    /// "This week you mastered 42 words", with the singular and a kind zero.
    static func headline(wordsMastered: Int) -> String {
        switch wordsMastered {
        case ..<1: return "这一周你的单词还在不断积累"
        case 1: return "这一周你掌握了 1 个单词"
        default: return "这一周你掌握了 \(wordsMastered) 个单词"
        }
    }

    /// The same headline for a parent reading about their child.
    static func parentHeadline(wordsMastered: Int) -> String {
        switch wordsMastered {
        case ..<1: return "本周没有新单词达到“记得很牢”"
        case 1: return "本周有 1 个单词达到“记得很牢”"
        default: return "本周有 \(wordsMastered) 个单词达到“记得很牢”"
        }
    }

    // MARK: Counts

    /// "1 review", "12 reviews".
    static func count(_ value: Int, _ singular: String, _ plural: String? = nil) -> String {
        "\(value) \(singular)"
    }

    /// "5 of 7 days".
    static func daysStudied(_ studiedDays: [Bool]) -> String {
        let studied = studiedDays.filter { $0 }.count
        return "\(studiedDays.count) 天中学了 \(studied) 天"
    }

    /// "84%", or an em dash with nothing to measure.
    static func percent(_ value: Double?) -> String {
        guard let value else { return "—" }
        return "\(Int((value * 100).rounded()))%"
    }

    // MARK: Week-on-week

    /// Direction of a change, for the arrow next to a number.
    enum Trend: Equatable {
        case up, down, same

        init(delta: Int) {
            if delta > 0 {
                self = .up
            } else if delta < 0 {
                self = .down
            } else {
                self = .same
            }
        }

        var symbolName: String {
            switch self {
            case .up: return "arrow.up.right"
            case .down: return "arrow.down.right"
            case .same: return "arrow.right"
            }
        }
    }

    /// "+12 vs last week", "−3 vs last week", "Same as last week".
    static func delta(_ delta: Int) -> String {
        switch Trend(delta: delta) {
        case .up: return "比上周 +\(delta)"
        // U+2212, a real minus sign: a hyphen reads as a dash at caption size.
        case .down: return "比上周 \u{2212}\(-delta)"
        case .same: return "和上周一样"
        }
    }

    // MARK: Parent notes

    /// Plain-language notes for the parent report. Each one explains a number a parent might
    /// otherwise misread — above all accuracy, where "85 %" looks like a B grade and is in fact
    /// the scheduler doing exactly what it should.
    static func parentNotes(accuracy: Double?, reviews: Int, daysStudied: Int, streak: Int, trickyCount: Int) -> [String] {
        var notes: [String] = []
        if let accuracy {
            let percent = Int((accuracy * 100).rounded())
            switch accuracy {
            case ..<0.75:
                notes.append("本周正确率是 \(percent)%。这通常是因为一下子学了很多新词；App 会让难的单词更早回来复习，慢慢就会自己平衡。")
            case ..<0.95:
                notes.append("正确率在 85% 左右，说明复习安排正常运作：单词总在快要忘记之前回来，这时复习效果最好。本周是 \(percent)%。")
            default:
                notes.append("本周正确率是 \(percent)%。正确率很高没问题，不过也可能说明单词偏简单，每天加几个新词会更有意思。")
            }
        } else {
            notes.append("最近七天没有复习。什么都不会丢：每个单词都在原地等着，花几分钟就能接着学。")
        }
        if reviews > 0 {
            notes.append("当 App 确信一个单词能记住三周以上时，它就算“记得很牢”。")
        }
        if daysStudied > 0 && daysStudied < 7 {
            notes.append("短而规律的学习胜过偶尔的长时间学习。大多数日子学几分钟就足够了。")
        }
        if streak >= 7 {
            notes.append("已经连续打卡 \(streak) 天。表扬孩子坚持学习，比表扬分数更有用。")
        }
        if trickyCount > 0 {
            notes.append("“值得再看看”的单词本周忘了两次或以上。这很正常，它们会更常回来复习，直到记住为止。")
        }
        notes.append("这份报告的所有内容都在这台设备上计算，不会发送到任何地方，也不需要账号。")
        return notes
    }

    // MARK: Day dots

    /// One-letter weekday for a `yyyy-MM-dd` day key, e.g. "M". Empty when the key is malformed.
    ///
    /// Read in UTC from the key's own digits, so the letter never depends on the device's time
    /// zone — the key already *is* the user's study day.
    static func weekdayInitial(dayKey: String, locale: Locale = Locale(identifier: "zh_Hans")) -> String {
        let parts = dayKey.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return "" }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        calendar.locale = locale
        guard let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else {
            return ""
        }
        let weekday = calendar.component(.weekday, from: date)
        let symbols = calendar.veryShortWeekdaySymbols
        guard weekday >= 1, weekday <= symbols.count else { return "" }
        return symbols[weekday - 1]
    }

    /// Full weekday name for VoiceOver, e.g. "Monday".
    static func weekdayName(dayKey: String, locale: Locale = Locale(identifier: "zh_Hans")) -> String {
        let parts = dayKey.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return dayKey }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        calendar.locale = locale
        guard let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else {
            return dayKey
        }
        let weekday = calendar.component(.weekday, from: date)
        let symbols = calendar.weekdaySymbols
        guard weekday >= 1, weekday <= symbols.count else { return dayKey }
        return symbols[weekday - 1]
    }

    /// "Week from 25 Sep 2026" style label for a history row, from its first day key.
    static func weekLabel(weekStartKey: String, locale: Locale = Locale(identifier: "zh_Hans")) -> String {
        let parts = weekStartKey.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return weekStartKey }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        guard let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else {
            return weekStartKey
        }
        let style = Date.FormatStyle(
            date: .abbreviated, time: .omitted,
            locale: locale, calendar: calendar, timeZone: calendar.timeZone
        )
        return "\(date.formatted(style)) 起的一周"
    }
}

/// The once-a-week "See your week" chip on the goal screen (engagement plan §1.9).
///
/// A calendar week rather than the recap's rolling window: the chip is a nudge, and "once per
/// week" has to mean a week a person would recognise.
enum RecapNudge {
    static let seenWeekKey = "recap.seenWeekKey"

    /// ISO week identifier such as `2026-W40`, in `timeZone`.
    static func weekKey(for date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return String(format: "%04d-W%02d", parts.yearForWeekOfYear ?? 0, parts.weekOfYear ?? 0)
    }

    /// `true` when the chip has not been offered yet this week.
    static func shouldOffer(currentWeekKey: String, seenWeekKey: String?) -> Bool {
        seenWeekKey != currentWeekKey
    }
}
