import XCTest
import SwiftData
@testable import VocabLoop

@MainActor
final class StatsTests: XCTestCase {

    private func makeFixture() throws -> (ModelContext, StatsService, UserAccount, StudyPreferences) {
        let context = try TestStore.makeContext()
        let account = try context.activeAccount()
        let preferences = try XCTUnwrap(account.preferences)
        preferences.timeZoneIdentifier = "UTC"
        return (context, StatsService(context: context), account, preferences)
    }

    func testEmptyStoreReportsZerosRatherThanFailing() throws {
        let (_, stats, account, preferences) = try makeFixture()
        let result = try stats.statistics(for: account, preferences: preferences, now: referenceDate)

        XCTAssertEqual(result.dueNow, 0)
        XCTAssertEqual(result.totalEnrolled, 0)
        XCTAssertNil(result.retentionLast30Days)
        XCTAssertEqual(result.currentStreak, 0)
    }

    func testDueCountsSeparateNowFromTodayAndNew() throws {
        let (context, stats, account, preferences) = try makeFixture()

        let overdue = try TestStore.makeEntry(in: context, headword: "overdue")
        let laterToday = try TestStore.makeEntry(in: context, headword: "latertoday")
        let tomorrow = try TestStore.makeEntry(in: context, headword: "tomorrow")
        let fresh = try TestStore.makeEntry(in: context, headword: "fresh")

        try TestStore.makeCard(in: context, for: overdue, due: referenceDate.addingTimeInterval(-3600))
        try TestStore.makeCard(in: context, for: laterToday, due: referenceDate.addingTimeInterval(3600))
        try TestStore.makeCard(in: context, for: tomorrow, due: referenceDate.addingTimeInterval(3 * 86_400))
        try TestStore.makeCard(in: context, for: fresh, phase: .new, due: referenceDate, intervalDays: 0)

        let result = try stats.statistics(for: account, preferences: preferences, now: referenceDate)

        XCTAssertEqual(result.dueNow, 1, "only the overdue card is due right now")
        XCTAssertEqual(result.dueToday, 2, "the card due later today counts toward today")
        XCTAssertEqual(result.newAvailable, 1)
        XCTAssertEqual(result.totalEnrolled, 4)
    }

    func testMaturityBucketsUseTheTwentyOneDayBoundary() throws {
        let (context, stats, account, preferences) = try makeFixture()

        let young = try TestStore.makeEntry(in: context, headword: "young")
        let mature = try TestStore.makeEntry(in: context, headword: "mature")
        let learning = try TestStore.makeEntry(in: context, headword: "learning")
        let fresh = try TestStore.makeEntry(in: context, headword: "fresh")

        try TestStore.makeCard(in: context, for: young, due: referenceDate, intervalDays: 20)
        try TestStore.makeCard(in: context, for: mature, due: referenceDate, intervalDays: 21)
        try TestStore.makeCard(in: context, for: learning, phase: .learning, due: referenceDate, intervalDays: 0.007)
        try TestStore.makeCard(in: context, for: fresh, phase: .new, due: referenceDate, intervalDays: 0)

        let result = try stats.statistics(for: account, preferences: preferences, now: referenceDate)
        XCTAssertEqual(result.countsByMaturity[.young], 1)
        XCTAssertEqual(result.countsByMaturity[.mature], 1, "21 days is mature, not young")
        XCTAssertEqual(result.countsByMaturity[.learning], 1)
        XCTAssertEqual(result.countsByMaturity[.new], 1)
    }

    /// Introductions must not inflate accuracy — rating a word you have never seen is not a recall
    /// test.
    func testRetentionExcludesIntroductions() throws {
        let (context, stats, account, preferences) = try makeFixture()
        let entry = try TestStore.makeEntry(in: context, headword: "abandon")
        let service = ReviewService(context: context)
        let card = try XCTUnwrap(
            try service.enroll(entry: entry, preferences: preferences, now: referenceDate).first
        )

        // Introduction (phaseBefore == .new), then a genuine recall that failed.
        try service.grade(card: card, rating: .easy, preferences: preferences, now: referenceDate)
        try service.grade(
            card: card, rating: .again, preferences: preferences,
            now: referenceDate.addingTimeInterval(86_400)
        )

        let result = try stats.statistics(
            for: account, preferences: preferences,
            now: referenceDate.addingTimeInterval(2 * 86_400)
        )
        XCTAssertEqual(result.reviewsLast30Days, 1, "only the graded recall counts")
        XCTAssertEqual(try XCTUnwrap(result.retentionLast30Days), 0, accuracy: 1e-9)
    }

    func testForecastBucketsByDayAndMaturity() throws {
        let (context, stats, account, preferences) = try makeFixture()

        let overdue = try TestStore.makeEntry(in: context, headword: "overdue")
        let inThreeDays = try TestStore.makeEntry(in: context, headword: "soon")
        let matureLater = try TestStore.makeEntry(in: context, headword: "maturelater")
        let beyondWindow = try TestStore.makeEntry(in: context, headword: "faraway")

        try TestStore.makeCard(
            in: context, for: overdue, due: referenceDate.addingTimeInterval(-5 * 86_400), intervalDays: 5
        )
        try TestStore.makeCard(
            in: context, for: inThreeDays, due: referenceDate.addingTimeInterval(3 * 86_400), intervalDays: 5
        )
        try TestStore.makeCard(
            in: context, for: matureLater, due: referenceDate.addingTimeInterval(3 * 86_400), intervalDays: 60
        )
        try TestStore.makeCard(
            in: context, for: beyondWindow, due: referenceDate.addingTimeInterval(90 * 86_400), intervalDays: 90
        )

        let result = try stats.statistics(
            for: account, preferences: preferences, now: referenceDate, forecastDays: 30
        )
        XCTAssertEqual(result.forecast.count, 30)
        // Overdue cards land on today — they are due now, not in the past.
        XCTAssertEqual(result.forecast[0].total, 1)
        XCTAssertEqual(result.forecast[3].youngCount, 1)
        XCTAssertEqual(result.forecast[3].matureCount, 1)
        XCTAssertEqual(
            result.forecast.reduce(0) { $0 + $1.total }, 3,
            "a card beyond the window must not be folded into the last day"
        )
    }

    func testSuspendedCardsAreExcludedFromDueCountsAndForecast() throws {
        let (context, stats, account, preferences) = try makeFixture()
        let entry = try TestStore.makeEntry(in: context, headword: "suspended")
        let card = try TestStore.makeCard(
            in: context, for: entry, due: referenceDate.addingTimeInterval(-3600)
        )
        card.isSuspended = true
        try context.save()

        let result = try stats.statistics(for: account, preferences: preferences, now: referenceDate)
        XCTAssertEqual(result.dueNow, 0)
        XCTAssertEqual(result.forecast.reduce(0) { $0 + $1.total }, 0)
        XCTAssertEqual(result.totalEnrolled, 1, "it is still in the collection, just paused")
    }

    func testHeatmapCoversTheRequestedWindowContiguously() throws {
        let (context, stats, account, preferences) = try makeFixture()
        let calendar = StudyCalendar(preferences: preferences)
        try TestStore.makeStudyDay(
            in: context, userID: account.userID, calendar: calendar,
            daysAgo: 2, reviews: 17, from: referenceDate
        )

        let result = try stats.statistics(
            for: account, preferences: preferences, now: referenceDate, heatmapDays: 30
        )
        XCTAssertEqual(result.heatmap.count, 30)
        XCTAssertEqual(result.heatmap.map(\.dayKey), result.heatmap.map(\.dayKey).sorted())
        XCTAssertEqual(result.heatmap.filter { $0.reviews > 0 }.count, 1)
        XCTAssertEqual(result.heatmap.first { $0.reviews > 0 }?.reviews, 17)
    }

    func testTodaysTotalsComeFromTheDayRollup() throws {
        let (context, stats, account, preferences) = try makeFixture()
        let calendar = StudyCalendar(preferences: preferences)
        let day = try TestStore.makeStudyDay(
            in: context, userID: account.userID, calendar: calendar,
            daysAgo: 0, reviews: 12, from: referenceDate
        )
        day.newCardsIntroduced = 3
        day.goalMet = true
        try context.save()

        let result = try stats.statistics(for: account, preferences: preferences, now: referenceDate)
        XCTAssertEqual(result.reviewsToday, 12)
        XCTAssertEqual(result.newIntroducedToday, 3)
        XCTAssertTrue(result.goalMetToday)
        XCTAssertEqual(try XCTUnwrap(result.accuracyToday), 1, accuracy: 1e-9)
    }

    func testStatisticsAreScopedToTheActiveLanguage() throws {
        let (context, stats, account, preferences) = try makeFixture()
        preferences.activeLanguage = .english

        let english = try TestStore.makeEntry(in: context, headword: "english", language: .english)
        let french = try TestStore.makeEntry(in: context, headword: "français", language: .french)
        try TestStore.makeCard(in: context, for: english, due: referenceDate.addingTimeInterval(-60))
        try TestStore.makeCard(in: context, for: french, due: referenceDate.addingTimeInterval(-60))

        let result = try stats.statistics(for: account, preferences: preferences, now: referenceDate)
        XCTAssertEqual(result.dueNow, 1)
        XCTAssertEqual(result.totalEnrolled, 1)
    }
}

final class IntervalFormatterTests: XCTestCase {
    func testShortFormatPicksAnAppropriateUnit() {
        XCTAssertEqual(IntervalFormatter.short(days: 0), "<1 分钟")
        XCTAssertEqual(IntervalFormatter.short(days: 1.0 / 1440), "1 分钟")
        XCTAssertEqual(IntervalFormatter.short(days: 10.0 / 1440), "10 分钟")
        XCTAssertEqual(IntervalFormatter.short(days: 3.0 / 24), "3 小时")
        XCTAssertEqual(IntervalFormatter.short(days: 1), "1 天")
        XCTAssertEqual(IntervalFormatter.short(days: 9), "9 天")
        XCTAssertEqual(IntervalFormatter.short(days: 28), "4 周")
        XCTAssertEqual(IntervalFormatter.short(days: 91), "3 个月")
        XCTAssertEqual(IntervalFormatter.short(days: 730), "2.0 年")
    }

    /// These labels sit four across on a 375pt screen, so length is a hard constraint. The
    /// Chinese labels ("12 小时", "<1 分钟", "2.5 年") stay within five characters.
    func testShortLabelsStayCompact() {
        for days in [0.0007, 0.5, 1, 5, 20, 45, 200, 900, 5_000] {
            XCTAssertLessThanOrEqual(
                IntervalFormatter.short(days: days).count, 5,
                "\"\(IntervalFormatter.short(days: days))\" is too wide for a rating button"
            )
        }
    }

    func testNonFiniteInputDoesNotProduceGarbage() {
        XCTAssertEqual(IntervalFormatter.short(days: .nan), "<1 分钟")
        XCTAssertEqual(IntervalFormatter.short(days: .infinity), "<1 分钟")
        XCTAssertEqual(IntervalFormatter.short(days: -5), "<1 分钟")
    }

    func testSpokenFormIsASentenceFragment() {
        XCTAssertEqual(IntervalFormatter.spoken(days: 1), "1 天后")
        XCTAssertEqual(IntervalFormatter.spoken(days: 4), "4 天后")
        XCTAssertEqual(IntervalFormatter.spoken(days: 1.0 / 1440), "1 分钟后")
        XCTAssertEqual(IntervalFormatter.spoken(days: 90), "大约 3 个月后")
    }

    func testDueDescriptionDistinguishesOverdueFromUpcoming() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(IntervalFormatter.dueDescription(due: now, now: now), "现在就该复习")
        XCTAssertEqual(
            IntervalFormatter.dueDescription(due: now.addingTimeInterval(4 * 86_400), now: now),
            "4 天后复习"
        )
        XCTAssertEqual(
            IntervalFormatter.dueDescription(due: now.addingTimeInterval(-4 * 86_400), now: now),
            "已超期 4 天"
        )
    }
}
