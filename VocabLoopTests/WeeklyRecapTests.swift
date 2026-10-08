import XCTest
import SwiftData
@testable import VocabLoop

/// The weekly recap's word counts come from `ReviewLog` (engagement plan §1.9). These pin the
/// "mastered" definition and the window's edges, with preferences pinned to UTC and a 4am
/// rollover: `referenceDate` is Wednesday 2023-11-15 10:00 UTC, so the window is
/// [2023-11-09 04:00, 2023-11-16 04:00) and the week before is [2023-11-02 04:00, 2023-11-09 04:00).
@MainActor
final class WeeklyRecapTests: XCTestCase {
    private var snapshotURL: URL!

    override func setUp() {
        super.setUp()
        snapshotURL = FileManager.default.temporaryDirectory
            .appending(path: "weekly-recap-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: snapshotURL)
        super.tearDown()
    }

    private struct Fixture {
        let context: ModelContext
        let account: UserAccount
        let preferences: StudyPreferences
        let engagement: EngagementService
        let recaps: WeeklyRecapService
    }

    private func makeFixture() throws -> Fixture {
        let context = try TestStore.makeContext()
        let account = try context.activeAccount()
        let preferences = try XCTUnwrap(account.preferences)
        pinToUTC(preferences)
        preferences.nativeLanguageCodes = ["zh"]
        let engagement = EngagementService(
            context: context,
            notifications: NotificationService(),
            snapshots: WidgetSnapshotWriter(url: snapshotURL),
            entitlements: Entitlements(defaults: nil)
        )
        return Fixture(
            context: context, account: account, preferences: preferences, engagement: engagement,
            recaps: WeeklyRecapService(context: context, engagement: engagement)
        )
    }

    private func utc(_ day: Int, _ hour: Int, _ minute: Int = 0, _ second: Int = 0) -> Date {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = TimeZone(identifier: "UTC")!
        return gregorian.date(from: DateComponents(year: 2023, month: 11, day: day, hour: hour, minute: minute, second: second))!
    }

    /// A log row with exactly the fields the recap reads.
    @discardableResult
    private func makeLog(
        in context: ModelContext,
        entryStableID: String,
        at date: Date,
        rating: Rating = .good,
        phaseBefore: LearningPhase = .review,
        scheduledDays: Double = 10,
        intervalAfter: Double = 15,
        stabilityAfter: Double = 15,
        direction: CardDirection = .recognition
    ) -> ReviewLog {
        let before = SchedulingState(
            phase: phaseBefore,
            stability: phaseBefore == .new ? 0 : 5,
            difficulty: phaseBefore == .new ? 0 : 5,
            intervalDays: scheduledDays,
            due: date,
            lastReviewedAt: phaseBefore == .new ? nil : date.addingTimeInterval(-scheduledDays * 86_400)
        )
        let after = SchedulingState(
            phase: rating == .again ? .relearning : .review,
            stability: stabilityAfter,
            difficulty: 5,
            intervalDays: intervalAfter,
            due: date.addingTimeInterval(intervalAfter * 86_400),
            lastReviewedAt: date
        )
        let log = ReviewLog(
            cardID: Card.makeCardID(entryStableID: entryStableID, direction: direction),
            entryStableID: entryStableID,
            languageCode: "en",
            direction: direction,
            reviewedAt: date,
            rating: rating,
            stateBefore: before,
            outcome: SchedulingOutcome(state: after, intervalDays: intervalAfter, retrievabilityBefore: 0.9),
            durationMS: 3_000,
            scheduler: .fsrs5,
            parametersVersion: "test"
        )
        context.insert(log)
        return log
    }

    // MARK: - masteredCount

    func testMasteredCountsTheCrossingIntoTwentyOneDays() throws {
        let context = try TestStore.makeContext()
        let logs = [
            makeLog(in: context, entryStableID: "en:a:1", at: referenceDate, scheduledDays: 15, intervalAfter: 30),
            // Exactly at the threshold counts.
            makeLog(in: context, entryStableID: "en:b:1", at: referenceDate, scheduledDays: 20.9, intervalAfter: 21),
            // Already mature: a review of a mature card is not a new mastery.
            makeLog(in: context, entryStableID: "en:c:1", at: referenceDate, scheduledDays: 21, intervalAfter: 50),
            // Still young.
            makeLog(in: context, entryStableID: "en:d:1", at: referenceDate, scheduledDays: 10, intervalAfter: 20.9),
            // A lapse from mature.
            makeLog(in: context, entryStableID: "en:e:1", at: referenceDate, rating: .again, scheduledDays: 30, intervalAfter: 0.01),
        ]
        XCTAssertEqual(WeeklyRecapService.masteredCount(logs: logs), 2)
    }

    func testAWordWithTwoCardsIsMasteredOnce() throws {
        let context = try TestStore.makeContext()
        let logs = [
            makeLog(in: context, entryStableID: "en:a:1", at: referenceDate, scheduledDays: 15, intervalAfter: 30, direction: .recognition),
            makeLog(in: context, entryStableID: "en:a:1", at: referenceDate, scheduledDays: 15, intervalAfter: 30, direction: .production),
        ]
        XCTAssertEqual(WeeklyRecapService.masteredCount(logs: logs), 1)
        XCTAssertEqual(WeeklyRecapService.masteredCount(logs: []), 0)
    }

    // MARK: - Window

    func testWindowBoundsAreWholeStudyDays() throws {
        let calendar = StudyCalendar(timeZone: TimeZone(identifier: "UTC")!, dayStartHour: 4)
        let bounds = WeeklyRecapService.windowBounds(endingAt: referenceDate, calendar: calendar)
        XCTAssertEqual(bounds.start, utc(9, 4))
        XCTAssertEqual(bounds.end, utc(16, 4))
        XCTAssertEqual(bounds.previousStart, utc(2, 4))
    }

    func testRecapCountsOnlyLogsInsideTheWindow() throws {
        let f = try makeFixture()
        func crossing(_ id: String, _ date: Date) {
            makeLog(in: f.context, entryStableID: id, at: date, scheduledDays: 15, intervalAfter: 30)
        }
        crossing("en:first:1", utc(9, 4))               // first instant of the window: in
        crossing("en:last:1", utc(16, 3, 59, 59))       // last second of today's study day: in
        crossing("en:before:1", utc(9, 3, 59, 59))      // one second early: the week before
        crossing("en:tomorrow:1", utc(16, 4))           // tomorrow's study day: out
        crossing("en:old:1", utc(2, 3))                 // before both windows: out
        try f.context.save()

        let recap = try f.recaps.recap(for: f.account, preferences: f.preferences, endingAt: referenceDate)
        XCTAssertEqual(recap.wordsMastered, 2)
        XCTAssertEqual(recap.previous?.wordsMastered, 2 - 1)
        XCTAssertEqual(recap.headline, "这周你掌握了 2 个单词")
        XCTAssertEqual(recap.dayKeys.count, 7)
        XCTAssertEqual(recap.weekStartKey, "2023-11-09")
        XCTAssertEqual(recap.dayKeys.last, "2023-11-15")
    }

    func testDaysStudiedAndTotalsComeFromStudyDays() throws {
        let f = try makeFixture()
        let calendar = StudyCalendar(preferences: f.preferences)
        for daysAgo in [0, 2, 6, 7] {
            try TestStore.makeStudyDay(
                in: f.context, userID: f.account.userID, calendar: calendar,
                daysAgo: daysAgo, reviews: 10, from: referenceDate
            )
        }
        let recap = try f.recaps.recap(for: f.account, preferences: f.preferences, endingAt: referenceDate)
        XCTAssertEqual(recap.studiedDays, [true, false, false, false, true, false, true])
        XCTAssertEqual(recap.reviews, 30, "seven days ago is the week before")
        XCTAssertEqual(recap.previous?.reviews, 30 - 10)
        XCTAssertEqual(recap.streak, 1)
    }

    // MARK: - Words

    func testNailedTrickyAndStartedWords() throws {
        let f = try makeFixture()
        let strong = try TestStore.makeEntry(in: f.context, headword: "strong")
        strong.senses.first?.translations = ["zh": "强"]
        let steady = try TestStore.makeEntry(in: f.context, headword: "steady")
        let slippery = try TestStore.makeEntry(in: f.context, headword: "slippery")
        let once = try TestStore.makeEntry(in: f.context, headword: "once")
        let fresh = try TestStore.makeEntry(in: f.context, headword: "fresh")

        makeLog(in: f.context, entryStableID: strong.stableID, at: utc(14, 9), stabilityAfter: 60)
        makeLog(in: f.context, entryStableID: steady.stableID, at: utc(13, 9), stabilityAfter: 20)
        // Forgotten twice, and once recalled with a huge stability: tricky, so not "nailed".
        makeLog(in: f.context, entryStableID: slippery.stableID, at: utc(10, 9), rating: .again)
        makeLog(in: f.context, entryStableID: slippery.stableID, at: utc(11, 9), rating: .again)
        makeLog(in: f.context, entryStableID: slippery.stableID, at: utc(12, 9), stabilityAfter: 99)
        // Forgotten once: not tricky.
        makeLog(in: f.context, entryStableID: once.stableID, at: utc(12, 9), rating: .again)
        // An introduction: started, never "nailed" however it was rated.
        makeLog(in: f.context, entryStableID: fresh.stableID, at: utc(15, 9), rating: .easy, phaseBefore: .new, scheduledDays: 0, stabilityAfter: 80)
        // Outside the window: ignored.
        makeLog(in: f.context, entryStableID: once.stableID, at: utc(1, 9), rating: .again)
        try f.context.save()

        let recap = try f.recaps.recap(for: f.account, preferences: f.preferences, endingAt: referenceDate)
        XCTAssertEqual(recap.trickyWords.map(\.headword), ["slippery"])
        XCTAssertEqual(recap.nailedWords.map(\.headword), ["strong", "steady"])
        XCTAssertEqual(recap.nailedWords.first?.translation, "强")
        XCTAssertEqual(recap.startedWords.map(\.headword), ["fresh"])
        XCTAssertEqual(recap.wordsStarted, 1)
    }

    func testTrickyWordsAreRankedAndCapped() throws {
        let context = try TestStore.makeContext()
        var logs: [ReviewLog] = []
        for (id, misses) in [("en:a:1", 2), ("en:b:1", 4), ("en:c:1", 3), ("en:d:1", 2), ("en:e:1", 1)] {
            for index in 0..<misses {
                logs.append(makeLog(in: context, entryStableID: id, at: referenceDate.addingTimeInterval(Double(index)), rating: .again))
            }
        }
        XCTAssertEqual(WeeklyRecapService.trickyWordIDs(logs: logs, limit: 3), ["en:b:1", "en:c:1", "en:a:1"])
    }

    // MARK: - Candy and combo

    func testCandyAndBestComboUseTheProfileWeekWhenItMatches() throws {
        let f = try makeFixture()
        let event = ReviewOutcomeEvent(
            cardID: "en:apple:1#recognition", entryStableID: "en:apple:1", rating: .good,
            questionKind: .flip, wasAutoGraded: false, responseMS: 1_000,
            phaseBefore: .review, maturityBefore: .young, maturityAfter: .young,
            comboAfter: 12, justReachedGoal: false, reviewsToday: 1
        )
        _ = try f.engagement.record(event, preferences: f.preferences, now: referenceDate)
        let profile = try f.engagement.profile()

        let recap = try f.recaps.recap(for: f.account, preferences: f.preferences, endingAt: referenceDate)
        XCTAssertEqual(recap.bestCombo, 12)
        XCTAssertEqual(recap.candyEarned, profile.candyThisWeek)
        XCTAssertEqual(recap.level, profile.level)

        // A week ago is a different profile week: no combo record, and candy rebuilt from logs.
        let older = try f.recaps.history(for: f.account, preferences: f.preferences, weeks: 2, now: referenceDate)
        XCTAssertEqual(older.count, 2)
        XCTAssertEqual(older[1].bestCombo, 0)
        XCTAssertEqual(older[1].candyEarned, 0)
        XCTAssertEqual(older[1].weekStartKey, "2023-11-02")
    }

    func testEstimatedCandyIsAFloorFromWhatWasLogged() {
        XCTAssertEqual(
            WeeklyRecapService.estimatedCandy(reviews: 100, studiedDays: 5, goalDays: 3, wordsMastered: 4, achievements: 2),
            100 * RewardEngine.candyPerReview + 5 * RewardEngine.firstReviewBonus + 3 * RewardEngine.goalBonus
                + 4 * RewardEngine.stickerBonus + 2 * RewardEngine.achievementBonus
        )
    }
}
