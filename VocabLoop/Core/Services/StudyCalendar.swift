import Foundation

/// Day-boundary arithmetic for streaks, daily batches and the heatmap.
///
/// A "study day" is *not* a calendar day. It starts at ``dayStartHour`` (4am by
/// default), because somebody reviewing at 1am is finishing yesterday's session, and
/// telling them they broke a 200-day streak is how an app gets deleted.
///
/// Every date→day conversion in the app goes through this type. Scattering
/// `Calendar.startOfDay(for:)` calls around the codebase is how off-by-one streak bugs
/// get in, and they are close to impossible to reproduce after the fact.
public struct StudyCalendar: Sendable, Hashable {
    public let timeZone: TimeZone
    /// Hour at which the study day rolls over, `0…23`.
    public let dayStartHour: Int

    public init(timeZone: TimeZone = .current, dayStartHour: Int = 4) {
        self.timeZone = timeZone
        self.dayStartHour = min(max(dayStartHour, 0), 23)
    }

    public init(preferences: StudyPreferences) {
        self.init(timeZone: preferences.timeZone, dayStartHour: preferences.dayStartHour)
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    /// Instant at which the study day containing `date` began.
    public func dayStart(for date: Date) -> Date {
        let calendar = self.calendar
        let midnight = calendar.startOfDay(for: date)
        let boundary = calendar.date(byAdding: .hour, value: dayStartHour, to: midnight) ?? midnight
        if date < boundary {
            // Before the rollover hour, so we are still inside yesterday's study day.
            return calendar.date(byAdding: .day, value: -1, to: boundary) ?? boundary
        }
        return boundary
    }

    public func dayEnd(for date: Date) -> Date {
        calendar.date(byAdding: .day, value: 1, to: dayStart(for: date)) ?? date
    }

    /// `yyyy-MM-dd`, stable and sortable, used as the persisted day identity.
    ///
    /// Built by hand from date components rather than with `DateFormatter` because a
    /// formatter would follow the user's locale and could emit a non-Gregorian
    /// calendar's numbering — which would silently corrupt every ``StudyDay`` key.
    public func dayKey(for date: Date) -> String {
        let start = dayStart(for: date)
        let parts = calendar.dateComponents([.year, .month, .day], from: start)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// Number of study days between two instants. Negative if `later` precedes `earlier`.
    public func dayDifference(from earlier: Date, to later: Date) -> Int {
        let a = dayStart(for: earlier)
        let b = dayStart(for: later)
        return calendar.dateComponents([.day], from: a, to: b).day ?? 0
    }

    public func isSameDay(_ a: Date, _ b: Date) -> Bool {
        dayStart(for: a) == dayStart(for: b)
    }

    /// Day key `daysAgo` study days before the one containing `date`.
    ///
    /// Uses calendar arithmetic rather than subtracting 86,400 seconds, so a DST
    /// transition inside the window cannot skip or repeat a day — which would show up
    /// as a streak silently resetting twice a year.
    public func dayKey(daysAgo: Int, from date: Date) -> String? {
        calendar
            .date(byAdding: .day, value: -daysAgo, to: dayStart(for: date))
            .map(dayKey(for:))
    }

    /// Day keys for the `count` study days ending with the one containing `date`,
    /// oldest first. Drives the heatmap and the streak scan.
    public func recentDayKeys(endingAt date: Date, count: Int) -> [String] {
        guard count > 0 else { return [] }
        let calendar = self.calendar
        let end = dayStart(for: date)
        return (0..<count).reversed().compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: end).map(dayKey(for:))
        }
    }

    /// Next occurrence of `hour:minute` strictly after `date`, for scheduling reminders.
    public func nextOccurrence(hour: Int, minute: Int, after date: Date) -> Date? {
        var components = calendar.dateComponents([.year, .month, .day], from: date)
        components.hour = hour
        components.minute = minute
        components.second = 0
        guard let today = calendar.date(from: components) else { return nil }
        return today > date ? today : calendar.date(byAdding: .day, value: 1, to: today)
    }
}
