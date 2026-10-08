import Foundation
// `@preconcurrency`, as the compiler itself suggests. `UNNotificationSettings` is not
// `Sendable`, so `await center.notificationSettings()` warns about crossing an isolation
// boundary — a warning about UserNotifications' own annotations, not about anything this file
// can fix. Silencing it here keeps the build's warning list to things that are actionable.
@preconcurrency import UserNotifications
import OSLog

/// Local study reminders.
///
/// Local notifications only — no push, no server, no device token. That keeps reminders
/// working offline and means the app needs no notification infrastructure at all, which
/// is the right trade for a feature whose entire job is "remind me at 8pm".
@MainActor
public final class NotificationService {
    private let center: UNUserNotificationCenter
    private let logger = Logger(subsystem: "com.vocabloop.app", category: "notifications")

    static let dailyReminderIdentifier = "vocabloop.reminder.daily"
    static let dailyWordIdentifier = "vocabloop.dailyword"
    /// The evening "a few words before bed?" nudge. One request, never repeating, rewritten
    /// whenever its inputs change — see ``refreshStreakReminder(preferences:streak:studiedToday:now:)``.
    static let streakRiskIdentifier = "vocabloop.streak.risk"

    /// Bumped by every cancel and every refresh of the streak nudge.
    ///
    /// ``refreshStreakReminder(preferences:streak:studiedToday:now:)`` awaits the authorization
    /// status before it adds the request. A review recorded during that await cancels the nudge
    /// synchronously — and without this counter the refresh would then resume and schedule
    /// "your streak is waiting" for someone who has just studied. A refresh only adds its request
    /// if nothing cancelled or superseded it in the meantime.
    private var streakReminderGeneration = 0

    public init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    public func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    /// Ask for permission. Returns whether reminders can now be scheduled.
    ///
    /// Only ever called from the Settings toggle, never at launch: asking for
    /// notification permission before the user has any reason to want them is how apps
    /// get permanently denied.
    @discardableResult
    public func requestAuthorization() async -> Bool {
        do {
            return try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            logger.error("Authorization failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Rewrite all scheduled reminders to match `preferences`.
    ///
    /// Idempotent: it removes what it owns and reschedules, so calling it after any
    /// preference change is always correct and never accumulates duplicates.
    ///
    /// `streak` and `studiedToday` feed the evening streak nudge. Their defaults describe someone
    /// who has already studied today, so a caller that does not know them removes the nudge
    /// rather than scheduling one on a guess; `EngagementService.refreshStreakReminder` puts it
    /// back with real values on the next background or session.
    public func refreshSchedule(
        preferences: StudyPreferences,
        dueCount: Int,
        streak: Int = 0,
        studiedToday: Bool = true
    ) async {
        streakReminderGeneration += 1
        center.removePendingNotificationRequests(withIdentifiers: [
            Self.dailyReminderIdentifier, Self.dailyWordIdentifier, Self.streakRiskIdentifier,
        ])

        guard preferences.remindersEnabled else { return }
        guard await authorizationStatus() == .authorized else { return }

        await scheduleDailyReminder(preferences: preferences, dueCount: dueCount)
        if preferences.dailyWordNotificationEnabled {
            await scheduleDailyWordNudge(preferences: preferences)
        }
        await refreshStreakReminder(
            preferences: preferences, streak: streak, studiedToday: studiedToday, now: Date()
        )
    }

    // MARK: - Streak nudge

    /// Schedule, or remove, the one-off evening nudge for the next study day the streak is open.
    ///
    /// Scheduled only when reminders are on and authorized, the streak reminder toggle is on and
    /// the streak is at least two days. If today has no review yet it is today's slot, and only
    /// while that is still ahead *within today's study day* — a nudge firing tomorrow would talk
    /// about a streak that by then has already ended. If today is done it is tomorrow's slot, so
    /// backgrounding after a session leaves tomorrow's nudge waiting (a review tomorrow cancels
    /// it again). Idempotent: the previous request is always removed first.
    public func refreshStreakReminder(
        preferences: StudyPreferences,
        streak: Int,
        studiedToday: Bool,
        now: Date
    ) async {
        streakReminderGeneration += 1
        let generation = streakReminderGeneration
        center.removePendingNotificationRequests(withIdentifiers: [Self.streakRiskIdentifier])

        let calendar = StudyCalendar(preferences: preferences)
        guard let fireDate = Self.streakReminderDate(
            preferences: preferences, streak: streak, studiedToday: studiedToday,
            now: now, calendar: calendar
        ) else { return }
        guard await authorizationStatus() == .authorized else { return }
        // A review, a cancel or a newer refresh happened while this one waited: theirs wins.
        guard generation == streakReminderGeneration else { return }

        let content = UNMutableNotificationContent()
        content.title = Self.streakReminderTitle
        content.body = Self.streakReminderBody(streak: streak)
        content.sound = .default
        content.interruptionLevel = .passive
        // No badge: the nudge is an invitation, not a count of something owed.

        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        var components = gregorian.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
        components.timeZone = calendar.timeZone
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)

        await add(
            UNNotificationRequest(
                identifier: Self.streakRiskIdentifier, content: content, trigger: trigger
            )
        )
    }

    /// Remove the streak nudge now. Called the moment a review is recorded: whoever studied
    /// today has nothing to be nudged about today. The next refresh (on background) schedules
    /// tomorrow's instead.
    public func cancelStreakReminder() {
        streakReminderGeneration += 1
        center.removePendingNotificationRequests(withIdentifiers: [Self.streakRiskIdentifier])
    }

    static let streakReminderTitle = "睡前背几个单词吗？"

    /// Kind on purpose: never "lose", "break" or "don't let", and no countdown.
    static func streakReminderBody(streak: Int) -> String {
        "你已经连续打卡 \(streak) 天，今天也在等你。背 3 个单词就能接上 —— 麻薯给你留好了位置。"
    }

    /// The next 19:30 after `now` — or 18:30 when the daily reminder is set for 19:30, since two
    /// notifications in the same minute read as a bug. Strictly after `now`, so once today's slot
    /// has passed this is tomorrow's.
    static func streakReminderFireDate(preferences: StudyPreferences, now: Date, calendar: StudyCalendar) -> Date? {
        let collides = preferences.reminderHour == 19 && preferences.reminderMinute == 30
        return calendar.nextOccurrence(hour: collides ? 18 : 19, minute: 30, after: now)
    }

    /// When the nudge should fire, or `nil` when there should be none. Pure, so every rule in
    /// the engagement plan (§1.2) is unit-tested without a notification center.
    ///
    /// Studied today: the slot in the *next study day*, searched from that day's start rather
    /// than from `now`, because before 19:30 the next slot after `now` is still today's — and
    /// today needs no nudge. Not studied today: today's slot while it is still ahead, else none.
    static func streakReminderDate(
        preferences: StudyPreferences,
        streak: Int,
        studiedToday: Bool,
        now: Date,
        calendar: StudyCalendar
    ) -> Date? {
        guard preferences.remindersEnabled,
              preferences.streakReminderEnabled,
              streak >= 2
        else { return nil }

        if studiedToday {
            let nextDayStart = calendar.dayEnd(for: now)
            guard let fireDate = streakReminderFireDate(
                      preferences: preferences, now: nextDayStart, calendar: calendar
                  ),
                  calendar.isSameDay(fireDate, nextDayStart)
            else { return nil }
            return fireDate
        }

        guard let fireDate = streakReminderFireDate(preferences: preferences, now: now, calendar: calendar),
              calendar.isSameDay(fireDate, now)
        else { return nil }
        return fireDate
    }

    private func scheduleDailyReminder(preferences: StudyPreferences, dueCount: Int) async {
        let content = UNMutableNotificationContent()
        content.title = "该复习啦"
        // The count is a snapshot from when the reminder was scheduled and will drift.
        // Phrase it so a stale number still reads as true rather than as a wrong claim.
        content.body = dueCount > 0
            ? "刚才有 \(dueCount) 张卡片在等你。花几分钟就够了。"
            : "学一小会儿，把连续打卡接下去。"
        content.sound = .default
        content.interruptionLevel = .passive

        var components = preferences.reminderTimeComponents
        components.timeZone = preferences.timeZone
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)

        await add(
            UNNotificationRequest(
                identifier: Self.dailyReminderIdentifier, content: content, trigger: trigger
            )
        )
    }

    private func scheduleDailyWordNudge(preferences: StudyPreferences) async {
        let content = UNMutableNotificationContent()
        content.title = "今天的新词准备好了"
        content.body = "\(preferences.newWordsPerDay) 个\(preferences.activeLanguage.displayName)新词在等你。"
        content.sound = nil
        content.interruptionLevel = .passive

        // Morning, and deliberately not the same time as the review reminder — two
        // notifications in the same minute read as a bug. The reminder time is the user's to
        // choose, though, and 9am is a perfectly ordinary choice, so the collision has to be
        // checked rather than assumed away.
        let nudgeHour = (preferences.reminderHour == 9 && preferences.reminderMinute == 0) ? 8 : 9
        var components = DateComponents(hour: nudgeHour, minute: 0)
        components.timeZone = preferences.timeZone
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)

        await add(
            UNNotificationRequest(
                identifier: Self.dailyWordIdentifier, content: content, trigger: trigger
            )
        )
    }

    private func add(_ request: UNNotificationRequest) async {
        do {
            try await center.add(request)
        } catch {
            logger.error("Could not schedule \(request.identifier, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    public func cancelAll() {
        streakReminderGeneration += 1
        center.removePendingNotificationRequests(withIdentifiers: [
            Self.dailyReminderIdentifier, Self.dailyWordIdentifier, Self.streakRiskIdentifier,
        ])
    }

    /// Mirror the due count onto the app icon badge.
    public func updateBadge(to count: Int) async {
        do {
            try await center.setBadgeCount(max(0, count))
        } catch {
            logger.error("Badge update failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
