import XCTest
import SwiftData
@testable import VocabLoop

@MainActor
final class StreakTests: XCTestCase {
    private let calendar = StudyCalendar(timeZone: TimeZone(identifier: "UTC")!, dayStartHour: 4)

    private func makeDays(_ daysAgoWithReviews: [(Int, Int)]) throws -> [StudyDay] {
        let context = try TestStore.makeContext()
        let account = try TestStore.makeAccount(in: context)
        return try daysAgoWithReviews.map { daysAgo, reviews in
            try TestStore.makeStudyDay(
                in: context, userID: account.userID, calendar: calendar,
                daysAgo: daysAgo, reviews: reviews, from: referenceDate
            )
        }
    }

    /// A streak must survive a daylight-saving transition.
    ///
    /// This is the user-visible half of the `StudyCalendar` bug CI found. `dayStart` computed its
    /// rollover boundary as midnight plus N *hours* — absolute time — so on a spring-forward day
    /// it landed an hour later on the wall clock than `date(byAdding: .day,)` did. One day key came
    /// back duplicated and its neighbour vanished, which reads to the user as a streak resetting
    /// for no reason, twice a year. `StudyCalendarTests` pins the keys; this pins the consequence.
    func testStreakSpansASpringForwardTransition() throws {
        let london = StudyCalendar(timeZone: TimeZone(identifier: "Europe/London")!, dayStartHour: 4)
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = london.timeZone
        // London sprang forward on 30 March 2025, so a week ending 2 April straddles it.
        let now = try XCTUnwrap(
            gregorian.date(from: DateComponents(year: 2025, month: 4, day: 2, hour: 12))
        )

        let context = try TestStore.makeContext()
        let account = try TestStore.makeAccount(in: context)
        let days = try (0..<7).map { daysAgo in
            try TestStore.makeStudyDay(
                in: context, userID: account.userID, calendar: london,
                daysAgo: daysAgo, reviews: 5, from: now
            )
        }
        XCTAssertEqual(
            Set(days.map(\.dayKey)).count, 7,
            "seven days must produce seven keys: \(days.map(\.dayKey).sorted())"
        )

        let streak = StreakService.streak(days: days, calendar: london, now: now)
        XCTAssertEqual(streak.current, 7, "the transition must not shorten the streak")
        XCTAssertEqual(streak.longest, 7)
        XCTAssertFalse(streak.isAtRiskToday, "today has reviews")
    }

    func testNoDaysMeansNoStreak() throws {
        let streak = StreakService.streak(days: [], calendar: calendar, now: referenceDate)
        XCTAssertEqual(streak.current, 0)
        XCTAssertEqual(streak.longest, 0)
        XCTAssertFalse(streak.isAtRiskToday)
    }

    func testConsecutiveDaysIncludingTodayCount() throws {
        let days = try makeDays([(0, 10), (1, 20), (2, 5)])
        let streak = StreakService.streak(days: days, calendar: calendar, now: referenceDate)
        XCTAssertEqual(streak.current, 3)
        XCTAssertEqual(streak.longest, 3)
        XCTAssertFalse(streak.isAtRiskToday)
    }

    /// The most important case. A streak that reached yesterday is still alive this morning —
    /// showing zero before the user has had a chance to study would be both wrong and
    /// demoralising.
    func testStreakSurvivesUntilTodayEnds() throws {
        let days = try makeDays([(1, 20), (2, 15), (3, 10)])
        let streak = StreakService.streak(days: days, calendar: calendar, now: referenceDate)
        XCTAssertEqual(streak.current, 3, "yesterday's streak is still current today")
        XCTAssertTrue(streak.isAtRiskToday, "but it needs a review today to continue")
    }

    func testGapBreaksTheStreak() throws {
        let days = try makeDays([(0, 10), (1, 10), (3, 10), (4, 10)])
        let streak = StreakService.streak(days: days, calendar: calendar, now: referenceDate)
        XCTAssertEqual(streak.current, 2, "day 2 is missing, so the run stops there")
        XCTAssertEqual(streak.longest, 2)
    }

    func testLongestStreakIsFoundAnywhereInHistory() throws {
        // A 5-day run a fortnight ago, and a 1-day run today.
        let days = try makeDays([(0, 10), (10, 10), (11, 10), (12, 10), (13, 10), (14, 10)])
        let streak = StreakService.streak(days: days, calendar: calendar, now: referenceDate)
        XCTAssertEqual(streak.current, 1)
        XCTAssertEqual(streak.longest, 5)
    }

    /// A day counts if *any* review happened. Requiring the goal would punish exactly the users
    /// who are trying on a busy day.
    func testAnyReviewCountsRegardlessOfGoal() throws {
        let days = try makeDays([(0, 1), (1, 1), (2, 1)])
        XCTAssertTrue(days.allSatisfy { !$0.goalMet })
        let streak = StreakService.streak(days: days, calendar: calendar, now: referenceDate)
        XCTAssertEqual(streak.current, 3)
    }

    func testDaysWithNoReviewsDoNotCount() throws {
        let days = try makeDays([(0, 0), (1, 0)])
        let streak = StreakService.streak(days: days, calendar: calendar, now: referenceDate)
        XCTAssertEqual(streak.current, 0)
        XCTAssertEqual(streak.longest, 0)
    }

    func testLongestIsNeverLessThanCurrent() throws {
        let days = try makeDays([(0, 5), (1, 5), (2, 5), (3, 5)])
        let streak = StreakService.streak(days: days, calendar: calendar, now: referenceDate)
        XCTAssertGreaterThanOrEqual(streak.longest, streak.current)
    }
}
