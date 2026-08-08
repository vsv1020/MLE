import Foundation
import UserNotifications
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
    public func refreshSchedule(preferences: StudyPreferences, dueCount: Int) async {
        center.removePendingNotificationRequests(withIdentifiers: [
            Self.dailyReminderIdentifier, Self.dailyWordIdentifier,
        ])

        guard preferences.remindersEnabled else { return }
        guard await authorizationStatus() == .authorized else { return }

        await scheduleDailyReminder(preferences: preferences, dueCount: dueCount)
        if preferences.dailyWordNotificationEnabled {
            await scheduleDailyWordNudge(preferences: preferences)
        }
    }

    private func scheduleDailyReminder(preferences: StudyPreferences, dueCount: Int) async {
        let content = UNMutableNotificationContent()
        content.title = "Time to review"
        // The count is a snapshot from when the reminder was scheduled and will drift.
        // Phrase it so a stale number still reads as true rather than as a wrong claim.
        content.body = dueCount > 0
            ? "You had \(dueCount) card\(dueCount == 1 ? "" : "s") waiting. A few minutes is enough."
            : "Keep the streak going with a short session."
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
        content.title = "Today's words are ready"
        content.body = "\(preferences.newWordsPerDay) new \(preferences.activeLanguage.displayName) words are waiting."
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
        center.removePendingNotificationRequests(withIdentifiers: [
            Self.dailyReminderIdentifier, Self.dailyWordIdentifier,
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
