import XCTest
import SwiftData
@testable import VocabLoop

/// The evening "a few words before bed?" nudge (engagement plan §1.2): when it fires, when it
/// must not exist, and its copy. All pure, so no notification center is involved.
@MainActor
final class StreakReminderTests: XCTestCase {

    /// Held for the test's duration: a model must not outlive its context.
    private var context: ModelContext?

    override func tearDown() {
        context = nil
        super.tearDown()
    }

    private func makePreferences() throws -> (StudyPreferences, StudyCalendar) {
        let context = try TestStore.makeContext()
        self.context = context
        let preferences = try XCTUnwrap(try context.activeAccount().preferences)
        pinToUTC(preferences)
        preferences.remindersEnabled = true
        preferences.reminderHour = 20
        preferences.reminderMinute = 0
        return (preferences, StudyCalendar(preferences: preferences))
    }

    private func utc(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = TimeZone(identifier: "UTC")!
        return gregorian.date(from: DateComponents(year: 2023, month: 11, day: day, hour: hour, minute: minute))!
    }

    // MARK: - Fire date

    func testFiresAtHalfPastSevenToday() throws {
        let (preferences, calendar) = try makePreferences()
        XCTAssertEqual(
            NotificationService.streakReminderFireDate(preferences: preferences, now: referenceDate, calendar: calendar),
            utc(15, 19, 30)
        )
    }

    func testMovesToHalfPastSixWhenTheDailyReminderIsAtHalfPastSeven() throws {
        let (preferences, calendar) = try makePreferences()
        preferences.reminderHour = 19
        preferences.reminderMinute = 30
        XCTAssertEqual(
            NotificationService.streakReminderFireDate(preferences: preferences, now: referenceDate, calendar: calendar),
            utc(15, 18, 30)
        )
    }

    func testIsTomorrowOnceTodaysSlotHasPassed() throws {
        let (preferences, calendar) = try makePreferences()
        XCTAssertEqual(
            NotificationService.streakReminderFireDate(preferences: preferences, now: utc(15, 20), calendar: calendar),
            utc(16, 19, 30)
        )
        XCTAssertEqual(
            NotificationService.streakReminderFireDate(preferences: preferences, now: utc(15, 19, 30), calendar: calendar),
            utc(16, 19, 30),
            "strictly after now"
        )
    }

    // MARK: - Whether to schedule

    func testScheduledForAStreakOfTwoNotYetContinuedToday() throws {
        let (preferences, calendar) = try makePreferences()
        XCTAssertEqual(
            NotificationService.streakReminderDate(
                preferences: preferences, streak: 2, studiedToday: false, now: referenceDate, calendar: calendar
            ),
            utc(15, 19, 30)
        )
    }

    func testNotScheduledForAOneDayStreak() throws {
        let (preferences, calendar) = try makePreferences()
        XCTAssertNil(NotificationService.streakReminderDate(
            preferences: preferences, streak: 1, studiedToday: false, now: referenceDate, calendar: calendar
        ))
        XCTAssertNil(NotificationService.streakReminderDate(
            preferences: preferences, streak: 0, studiedToday: false, now: referenceDate, calendar: calendar
        ))
    }

    /// Today is done, so today needs no nudge — but tomorrow's study day does. Before 19:30 the
    /// next slot after `now` is still today's, so this checks it skips to tomorrow's.
    func testOnceTodayHasAReviewTheNudgeIsTomorrows() throws {
        let (preferences, calendar) = try makePreferences()
        XCTAssertEqual(
            NotificationService.streakReminderDate(
                preferences: preferences, streak: 9, studiedToday: true, now: referenceDate, calendar: calendar
            ),
            utc(16, 19, 30),
            "tomorrow's slot, never today's"
        )
    }

    /// Studied today, then backgrounded: after today's slot, late at night, and in the small hours
    /// that still belong to today's study day, the nudge is tomorrow's — at 18:30 when the daily
    /// reminder owns 19:30. The guards still apply.
    func testStudiedTodaySchedulesTomorrowsNudge() throws {
        let (preferences, calendar) = try makePreferences()
        XCTAssertEqual(
            NotificationService.streakReminderDate(
                preferences: preferences, streak: 2, studiedToday: true, now: utc(15, 21), calendar: calendar
            ),
            utc(16, 19, 30)
        )
        // 2am on the 16th is still the 15th's study day, so "tomorrow" is the 16th.
        XCTAssertEqual(
            NotificationService.streakReminderDate(
                preferences: preferences, streak: 2, studiedToday: true, now: utc(16, 2), calendar: calendar
            ),
            utc(16, 19, 30)
        )

        preferences.reminderHour = 19
        preferences.reminderMinute = 30
        XCTAssertEqual(
            NotificationService.streakReminderDate(
                preferences: preferences, streak: 2, studiedToday: true, now: referenceDate, calendar: calendar
            ),
            utc(16, 18, 30)
        )

        XCTAssertNil(NotificationService.streakReminderDate(
            preferences: preferences, streak: 1, studiedToday: true, now: referenceDate, calendar: calendar
        ))
        preferences.streakReminderEnabled = false
        XCTAssertNil(NotificationService.streakReminderDate(
            preferences: preferences, streak: 9, studiedToday: true, now: referenceDate, calendar: calendar
        ))
        preferences.streakReminderEnabled = true
        preferences.remindersEnabled = false
        XCTAssertNil(NotificationService.streakReminderDate(
            preferences: preferences, streak: 9, studiedToday: true, now: referenceDate, calendar: calendar
        ))
    }

    func testNotScheduledWhenEitherToggleIsOff() throws {
        let (preferences, calendar) = try makePreferences()
        preferences.streakReminderEnabled = false
        XCTAssertNil(NotificationService.streakReminderDate(
            preferences: preferences, streak: 9, studiedToday: false, now: referenceDate, calendar: calendar
        ))
        preferences.streakReminderEnabled = true
        preferences.remindersEnabled = false
        XCTAssertNil(NotificationService.streakReminderDate(
            preferences: preferences, streak: 9, studiedToday: false, now: referenceDate, calendar: calendar
        ))
    }

    /// Past 19:30 the next slot is in tomorrow's study day, when this streak will already have
    /// ended — so there is no nudge rather than a wrong one.
    func testNotScheduledOnceTodaysSlotHasPassed() throws {
        let (preferences, calendar) = try makePreferences()
        XCTAssertNil(NotificationService.streakReminderDate(
            preferences: preferences, streak: 9, studiedToday: false, now: utc(15, 21), calendar: calendar
        ))
        // 2am belongs to the previous study day; the next 19:30 is in the following one.
        XCTAssertNil(NotificationService.streakReminderDate(
            preferences: preferences, streak: 9, studiedToday: false, now: utc(16, 2), calendar: calendar
        ))
    }

    // MARK: - Copy

    func testCopyIsKind() {
        XCTAssertEqual(NotificationService.streakRiskIdentifier, "vocabloop.streak.risk")
        XCTAssertEqual(NotificationService.streakReminderTitle, "A few words before bed?")
        let body = NotificationService.streakReminderBody(streak: 5)
        XCTAssertEqual(
            body,
            "Your 5-day streak is waiting for today. Three words keep it going — Mochi saved your spot."
        )
        for banned in ["lose", "break", "don't let"] {
            XCTAssertFalse(body.lowercased().contains(banned), banned)
        }
    }
}
