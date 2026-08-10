import Foundation

/// Streak arithmetic over ``StudyDay`` rows.
///
/// A `struct` of static functions rather than a service object because it is pure: it
/// takes days in, gives numbers out, and touches no storage. That is what makes the
/// timezone and day-boundary edge cases testable, which is the whole reason streaks
/// deserve their own type — they are the feature users notice being wrong.
public enum StreakService {
    public struct Streak: Hashable, Sendable {
        public var current: Int
        public var longest: Int
        /// `true` when the user has not yet studied today but the streak is still alive.
        /// Drives the "at risk" styling on the streak chip.
        public var isAtRiskToday: Bool

        public static let none = Streak(current: 0, longest: 0, isAtRiskToday: false)
    }

    /// A day counts toward a streak when *any* review happened, not when the goal was
    /// met.
    ///
    /// Deliberate: requiring the goal turns a busy day into a broken streak and
    /// punishes exactly the users who are trying. The goal ring rewards hitting the
    /// target; the streak rewards showing up.
    static func counts(_ day: StudyDay) -> Bool { day.reviewsCompleted > 0 }

    /// Current and longest streak.
    ///
    /// Today is treated as neutral: a streak that reached yesterday is still current
    /// until today ends. Anything else would show every user a zero every morning.
    public static func streak(days: [StudyDay], calendar: StudyCalendar, now: Date) -> Streak {
        let activeKeys = Set(days.filter(counts).map(\.dayKey))
        guard !activeKeys.isEmpty else { return .none }

        let todayKey = calendar.dayKey(for: now)
        let studiedToday = activeKeys.contains(todayKey)

        // Walk backwards from today (or from yesterday, when today is still open).
        //
        // Bounded by the number of active days, which no streak can exceed. The loop already
        // terminates on the first inactive day, but this is a `while` over a date calculation
        // whose result feeds a number on the Home screen: if some calendar ever returned the
        // same key for two different offsets, the alternative to a bound is a spin on the main
        // actor with the app frozen.
        var current = 0
        var offset = studiedToday ? 0 : 1
        while current < activeKeys.count {
            guard let key = calendar.dayKey(daysAgo: offset, from: now) else { break }
            guard activeKeys.contains(key) else { break }
            current += 1
            offset += 1
        }

        return Streak(
            current: current,
            longest: max(longestRun(activeKeys: activeKeys, days: days, calendar: calendar), current),
            isAtRiskToday: current > 0 && !studiedToday
        )
    }

    /// Longest run of consecutive active days anywhere in the history.
    private static func longestRun(activeKeys: Set<String>, days: [StudyDay], calendar: StudyCalendar) -> Int {
        // Sorted day *starts* rather than keys, because "consecutive" is a calendar
        // question — string keys would treat 2025-01-31 and 2025-02-01 as unrelated.
        let starts = days
            .filter(counts)
            .map(\.dayStart)
            .sorted()

        var longest = 0
        var run = 0
        var previous: Date?
        for start in starts {
            if let previous, calendar.dayDifference(from: previous, to: start) == 1 {
                run += 1
            } else {
                run = 1
            }
            longest = max(longest, run)
            previous = start
        }
        return longest
    }
}
