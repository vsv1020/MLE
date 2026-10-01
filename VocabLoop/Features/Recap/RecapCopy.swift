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
        case ..<1: return "This week you kept your words growing"
        case 1: return "This week you mastered 1 word"
        default: return "This week you mastered \(wordsMastered) words"
        }
    }

    /// The same headline for a parent reading about their child.
    static func parentHeadline(wordsMastered: Int) -> String {
        switch wordsMastered {
        case ..<1: return "No new words reached “well known” this week"
        case 1: return "1 word reached “well known” this week"
        default: return "\(wordsMastered) words reached “well known” this week"
        }
    }

    // MARK: Counts

    /// "1 review", "12 reviews".
    static func count(_ value: Int, _ singular: String, _ plural: String? = nil) -> String {
        "\(value) \(value == 1 ? singular : (plural ?? singular + "s"))"
    }

    /// "5 of 7 days".
    static func daysStudied(_ studiedDays: [Bool]) -> String {
        let studied = studiedDays.filter { $0 }.count
        return "\(studied) of \(studiedDays.count) days"
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
        case .up: return "+\(delta) vs last week"
        // U+2212, a real minus sign: a hyphen reads as a dash at caption size.
        case .down: return "\u{2212}\(-delta) vs last week"
        case .same: return "Same as last week"
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
                notes.append("Accuracy was \(percent) % this week. That usually means a lot of brand-new words at once; the app brings the hard ones back sooner, so it evens out by itself.")
            case ..<0.95:
                notes.append("Accuracy around 85 % is the scheduler working as intended: words come back just before they would be forgotten, which is when a review does the most good. \(percent) % this week.")
            default:
                notes.append("Accuracy was \(percent) % this week. Very high accuracy is fine; it can also mean the words are on the easy side, and adding a few new ones each day keeps it interesting.")
            }
        } else {
            notes.append("No reviews in the last seven days. Nothing is lost: every word waits where it was, and a few minutes picks it straight back up.")
        }
        if reviews > 0 {
            notes.append("A word counts as “well known” once the app is confident it will be remembered for three weeks or more.")
        }
        if daysStudied > 0 && daysStudied < 7 {
            notes.append("Short, regular sessions beat long occasional ones. A few minutes on most days is plenty.")
        }
        if streak >= 7 {
            notes.append("A \(streak)-day streak. Praise for showing up works better than praise for scores.")
        }
        if trickyCount > 0 {
            notes.append("The words “worth another look” were forgotten twice or more this week. That is normal; they will come back more often until they stick.")
        }
        notes.append("Everything in this report is worked out on this device. Nothing is sent anywhere, and no account is needed.")
        return notes
    }

    // MARK: Day dots

    /// One-letter weekday for a `yyyy-MM-dd` day key, e.g. "M". Empty when the key is malformed.
    ///
    /// Read in UTC from the key's own digits, so the letter never depends on the device's time
    /// zone — the key already *is* the user's study day.
    static func weekdayInitial(dayKey: String, locale: Locale = .current) -> String {
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
    static func weekdayName(dayKey: String, locale: Locale = .current) -> String {
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
    static func weekLabel(weekStartKey: String, locale: Locale = .current) -> String {
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
        return "Week from \(date.formatted(style))"
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
