import XCTest
import SwiftData
@testable import VocabLoop

/// `EngagementService.record`: the candy economy, the once-only guards and the events the study
/// screen celebrates (engagement plan §1.3, §2.2).
///
/// Every test pins preferences to UTC with a 4am rollover and uses `referenceDate`
/// (Wednesday 2023-11-15 10:00 UTC), so day and week boundaries do not depend on the machine.
@MainActor
final class EngagementServiceTests: XCTestCase {
    private var snapshotURL: URL!

    override func setUp() {
        super.setUp()
        snapshotURL = FileManager.default.temporaryDirectory
            .appending(path: "engagement-service-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: snapshotURL)
        super.tearDown()
    }

    private struct Fixture {
        let context: ModelContext
        let account: UserAccount
        let preferences: StudyPreferences
        let service: EngagementService
        let calendar: StudyCalendar
    }

    private func makeFixture() throws -> Fixture {
        let context = try TestStore.makeContext()
        let account = try context.activeAccount()
        let preferences = try XCTUnwrap(account.preferences)
        pinToUTC(preferences)
        let service = EngagementService(
            context: context,
            notifications: NotificationService(),
            snapshots: WidgetSnapshotWriter(url: snapshotURL),
            entitlements: Entitlements(defaults: nil)
        )
        return Fixture(
            context: context, account: account, preferences: preferences, service: service,
            calendar: StudyCalendar(preferences: preferences)
        )
    }

    private func event(
        entryStableID: String = "en:apple:1",
        rating: Rating = .good,
        kind: QuestionKind = .flip,
        maturityBefore: CardMaturity = .young,
        maturityAfter: CardMaturity = .young,
        combo: Int = 1,
        justReachedGoal: Bool = false,
        reviewsToday: Int = 1
    ) -> ReviewOutcomeEvent {
        ReviewOutcomeEvent(
            cardID: "\(entryStableID)#recognition", entryStableID: entryStableID, rating: rating,
            questionKind: kind, wasAutoGraded: kind.isAutoGraded, responseMS: 2_000,
            phaseBefore: .review, maturityBefore: maturityBefore, maturityAfter: maturityAfter,
            comboAfter: combo, justReachedGoal: justReachedGoal, reviewsToday: reviewsToday
        )
    }

    private func achievementEvents(_ events: [EngagementEvent]) -> [AchievementID] {
        events.compactMap { event in
            if case .achievement(let id) = event { return id }
            return nil
        }
    }

    // MARK: - Candy

    /// A short scripted day: five reviews, combos 1…5, the goal reached on the fifth.
    func testCandyTotalsForAScriptedDay() throws {
        let f = try makeFixture()
        try TestStore.makeStudyDay(
            in: f.context, userID: f.account.userID, calendar: f.calendar,
            daysAgo: 0, reviews: 5, from: referenceDate
        )

        var all: [[EngagementEvent]] = []
        for combo in 1...5 {
            let now = referenceDate.addingTimeInterval(Double(combo) * 60)
            all.append(try f.service.record(
                event(combo: combo, justReachedGoal: combo == 5, reviewsToday: combo),
                preferences: f.preferences, now: now
            ))
        }

        let first = RewardEngine.candyPerReview + RewardEngine.firstReviewBonus + RewardEngine.achievementBonus
        XCTAssertEqual(all[0], [.candy(first), .firstReviewToday(streak: 1), .achievement(.first_review)])
        XCTAssertEqual(all[1], [.candy(1)])
        XCTAssertEqual(all[2], [.candy(1 + RewardEngine.comboBonus(3)), .comboMilestone(3)])
        XCTAssertEqual(all[3], [.candy(1)])
        XCTAssertEqual(all[4], [.candy(1 + RewardEngine.comboBonus(5) + RewardEngine.goalBonus), .comboMilestone(5)])

        let expectedTotal = 5 * RewardEngine.candyPerReview
            + RewardEngine.firstReviewBonus
            + RewardEngine.comboBonus(3) + RewardEngine.comboBonus(5)
            + RewardEngine.goalBonus
            + RewardEngine.achievementBonus
        let profile = try f.service.profile()
        XCTAssertEqual(profile.candyTotal, expectedTotal)
        XCTAssertEqual(profile.candyThisWeek, expectedTotal)
        XCTAssertEqual(profile.lifetimeReviews, 5)
        XCTAssertEqual(profile.goalDaysTotal, 1)
        XCTAssertEqual(profile.bestCombo, 5)
        XCTAssertEqual(profile.bestComboThisWeek, 5)
        XCTAssertEqual(profile.lastStudiedAt, referenceDate.addingTimeInterval(300))
        XCTAssertEqual(profile.weekKey, "2023-11-13")
    }

    /// Honesty costs nothing: a Forgot and an Easy earn exactly the same.
    func testCandyIsRatingAgnostic() throws {
        let forgot = try makeFixture()
        let easy = try makeFixture()
        let a = try forgot.service.record(event(rating: .again, combo: 0), preferences: forgot.preferences, now: referenceDate)
        let b = try easy.service.record(event(rating: .easy, combo: 1), preferences: easy.preferences, now: referenceDate)
        XCTAssertEqual(a.first, b.first)
        XCTAssertEqual(try forgot.service.profile().candyTotal, try easy.service.profile().candyTotal)
    }

    func testFirstReviewBonusIsPaidOncePerStudyDay() throws {
        let f = try makeFixture()
        try TestStore.makeStudyDay(
            in: f.context, userID: f.account.userID, calendar: f.calendar,
            daysAgo: 0, reviews: 1, from: referenceDate
        )

        let first = try f.service.record(event(), preferences: f.preferences, now: referenceDate)
        XCTAssertTrue(first.contains(.firstReviewToday(streak: 1)))

        // Same study day, including 2am the next calendar morning (before the 4am rollover).
        let again = try f.service.record(event(), preferences: f.preferences, now: referenceDate.addingTimeInterval(3_600))
        XCTAssertEqual(again, [.candy(RewardEngine.candyPerReview)])
        let lateNight = try f.service.record(event(), preferences: f.preferences, now: referenceDate.addingTimeInterval(16 * 3_600))
        XCTAssertFalse(lateNight.contains { if case .firstReviewToday = $0 { return true } else { return false } })

        // The next study day pays it again, with yesterday's streak plus today.
        let tomorrow = referenceDate.addingTimeInterval(86_400)
        let next = try f.service.record(event(), preferences: f.preferences, now: tomorrow)
        XCTAssertEqual(next.first, .candy(RewardEngine.candyPerReview + RewardEngine.firstReviewBonus))
        XCTAssertTrue(next.contains(.firstReviewToday(streak: 2)))
    }

    func testLevelUpIsReportedWhenTheReviewCrossesALevel() throws {
        let f = try makeFixture()
        let profile = try f.service.profile()
        profile.candyTotal = RewardEngine.candyRequired(toReach: 2) - 1
        profile.lastFirstReviewDayKey = f.calendar.dayKey(for: referenceDate)
        // Already unlocked, so only the base candy is added.
        profile.unlockedAchievements = [UnlockedAchievement(id: AchievementID.first_review.rawValue, unlockedAt: referenceDate)]

        let events = try f.service.record(event(), preferences: f.preferences, now: referenceDate)
        XCTAssertEqual(events, [.candy(1), .levelUp(2)])
        XCTAssertEqual(try f.service.profile().level, 2)

        let quiet = try f.service.record(event(), preferences: f.preferences, now: referenceDate)
        XCTAssertEqual(quiet, [.candy(1)], "no level-up without crossing one")
    }

    func testWeekRolloverResetsTheWeeklyFieldsBeforeAdding() throws {
        let f = try makeFixture()
        let profile = try f.service.profile()
        profile.weekKey = "2023-11-06"
        profile.candyThisWeek = 500
        profile.bestComboThisWeek = 40
        profile.bestCombo = 40
        profile.candyTotal = 900

        let events = try f.service.record(event(combo: 2), preferences: f.preferences, now: referenceDate)
        guard case .candy(let earned) = events.first else { return XCTFail("candy first") }

        XCTAssertEqual(profile.weekKey, "2023-11-13")
        XCTAssertEqual(profile.candyThisWeek, earned)
        XCTAssertEqual(profile.bestComboThisWeek, 2)
        XCTAssertEqual(profile.bestCombo, 40, "the lifetime best is not weekly")
        XCTAssertEqual(profile.candyTotal, 900 + earned)
    }

    func testWeekKeyIsTheMondayOfTheStudyWeek() {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = TimeZone(identifier: "UTC")!
        let calendar = StudyCalendar(timeZone: TimeZone(identifier: "UTC")!, dayStartHour: 4)
        func date(_ day: Int, _ hour: Int) -> Date {
            gregorian.date(from: DateComponents(year: 2023, month: 11, day: day, hour: hour))!
        }
        XCTAssertEqual(EngagementService.weekKey(for: date(15, 10), calendar: calendar), "2023-11-13")
        XCTAssertEqual(EngagementService.weekKey(for: date(13, 10), calendar: calendar), "2023-11-13")
        XCTAssertEqual(EngagementService.weekKey(for: date(19, 23), calendar: calendar), "2023-11-13")
        // 2am on Monday still belongs to Sunday's study day, so to the week before.
        XCTAssertEqual(EngagementService.weekKey(for: date(13, 2), calendar: calendar), "2023-11-06")
        XCTAssertEqual(EngagementService.weekKey(for: date(20, 2), calendar: calendar), "2023-11-13")
    }

    // MARK: - Combo and quiz

    func testComboMilestonesPayTheirBonusAndTrackTheBest() throws {
        let f = try makeFixture()
        _ = try f.service.record(event(combo: 1), preferences: f.preferences, now: referenceDate)

        let ten = try f.service.record(event(combo: 10), preferences: f.preferences, now: referenceDate)
        XCTAssertEqual(
            ten,
            [.candy(1 + RewardEngine.comboBonus(10) + RewardEngine.achievementBonus), .comboMilestone(10), .achievement(.combo_10)]
        )
        let eleven = try f.service.record(event(combo: 11), preferences: f.preferences, now: referenceDate)
        XCTAssertEqual(eleven, [.candy(1)])
        let reset = try f.service.record(event(rating: .again, combo: 0), preferences: f.preferences, now: referenceDate)
        XCTAssertEqual(reset, [.candy(1)])
        XCTAssertEqual(try f.service.profile().bestCombo, 11)
    }

    func testOnlyCorrectAutoGradedAnswersCountForTheQuizBadge() throws {
        let f = try makeFixture()
        _ = try f.service.record(event(rating: .good, kind: .multipleChoice), preferences: f.preferences, now: referenceDate)
        _ = try f.service.record(event(rating: .hard, kind: .typed), preferences: f.preferences, now: referenceDate)
        _ = try f.service.record(event(rating: .again, kind: .listenChoose, combo: 0), preferences: f.preferences, now: referenceDate)
        _ = try f.service.record(event(rating: .good, kind: .flip), preferences: f.preferences, now: referenceDate)
        XCTAssertEqual(try f.service.profile().quizCorrectTotal, 2)
    }

    // MARK: - Achievements

    func testAchievementsUnlockOnceAndPayOnce() throws {
        let f = try makeFixture()
        let first = try f.service.record(event(combo: 10), preferences: f.preferences, now: referenceDate)
        XCTAssertEqual(achievementEvents(first), [.first_review, .combo_10])

        let second = try f.service.record(event(combo: 10), preferences: f.preferences, now: referenceDate)
        XCTAssertTrue(achievementEvents(second).isEmpty)

        let profile = try f.service.profile()
        XCTAssertEqual(profile.unlockedAchievements.filter { $0.id == AchievementID.combo_10.rawValue }.count, 1)
        XCTAssertEqual(profile.unlockedAchievements.count, 2)

        let statuses = try f.service.achievementStatuses(preferences: f.preferences, now: referenceDate)
        XCTAssertEqual(statuses.count, AchievementID.allCases.count)
        XCTAssertEqual(statuses.filter(\.isUnlocked).map(\.id), [.first_review, .combo_10])
    }

    func testNightOwlUnlocksTheNightcap() throws {
        let f = try makeFixture()
        let lateEvening = referenceDate.addingTimeInterval(13 * 3_600) // 23:00 UTC
        let events = try f.service.record(event(), preferences: f.preferences, now: lateEvening)
        XCTAssertTrue(achievementEvents(events).contains(.night_owl))
        XCTAssertTrue(try f.service.profile().unlockedAccessoryIDs.contains(MochiAccessory.nightcap.rawValue))
        XCTAssertTrue(f.service.isUnlocked(.nightcap))
    }

    func testStreakBadgesCountTodaysReview() throws {
        let f = try makeFixture()
        for daysAgo in 1...2 {
            try TestStore.makeStudyDay(
                in: f.context, userID: f.account.userID, calendar: f.calendar,
                daysAgo: daysAgo, reviews: 3, from: referenceDate
            )
        }
        // Today's `StudyDay` not written yet: the review being recorded still makes it three.
        let events = try f.service.record(event(), preferences: f.preferences, now: referenceDate)
        XCTAssertTrue(events.contains(.firstReviewToday(streak: 3)))
        XCTAssertTrue(achievementEvents(events).contains(.streak_3))
    }

    /// An upgrade with words matured before 1.0.7 earns the badge on its first recorded review.
    func testExistingMatureWordsCountOnTheFirstReview() throws {
        let f = try makeFixture()
        for index in 0..<10 {
            let entry = try TestStore.makeEntry(in: f.context, headword: "word\(index)")
            try TestStore.makeCard(in: f.context, for: entry, due: referenceDate, intervalDays: 30)
        }
        let events = try f.service.record(event(), preferences: f.preferences, now: referenceDate)
        XCTAssertTrue(achievementEvents(events).contains(.mastered_10))
    }

    // MARK: - Stickers and albums

    func testStickerAndAlbumFireExactlyOnTheCrossingIntoMaturity() throws {
        let f = try makeFixture()
        let entry = try TestStore.makeEntry(in: f.context, headword: "apple")
        try TestStore.makeCard(in: f.context, for: entry, due: referenceDate, intervalDays: 30)
        let albumID = Album.makeID(languageCode: entry.languageCode, level: .a1, family: .nouns, page: 1)

        // Not a crossing: already mature before.
        let stayed = try f.service.record(
            event(entryStableID: entry.stableID, maturityBefore: .mature, maturityAfter: .mature),
            preferences: f.preferences, now: referenceDate
        )
        XCTAssertFalse(stayed.contains(.stickerLit(entryStableID: entry.stableID)))

        let crossed = try f.service.record(
            event(entryStableID: entry.stableID, maturityBefore: .young, maturityAfter: .mature),
            preferences: f.preferences, now: referenceDate
        )
        XCTAssertTrue(crossed.contains(.stickerLit(entryStableID: entry.stableID)))
        XCTAssertTrue(crossed.contains(.albumCompleted(albumID: albumID, title: "A1 Nouns · Page 1")))
        XCTAssertTrue(achievementEvents(crossed).contains(.album_first))
        guard case .candy(let earned) = crossed.first else { return XCTFail("candy first") }
        XCTAssertEqual(
            earned,
            RewardEngine.candyPerReview + RewardEngine.stickerBonus + RewardEngine.albumBonus + RewardEngine.achievementBonus
        )
        XCTAssertEqual(try f.service.profile().completedAlbumIDs, [albumID])

        // An album pays once, even if a card lapses and matures again.
        let recrossed = try f.service.record(
            event(entryStableID: entry.stableID, maturityBefore: .young, maturityAfter: .mature),
            preferences: f.preferences, now: referenceDate
        )
        XCTAssertFalse(recrossed.contains { if case .albumCompleted = $0 { return true } else { return false } })
        XCTAssertEqual(try f.service.profile().completedAlbumIDs, [albumID])
    }

    /// A word is only as mature as its weakest card: its sticker waits for the last one.
    func testStickerWaitsForEveryCardOfTheWord() throws {
        let f = try makeFixture()
        let entry = try TestStore.makeEntry(in: f.context, headword: "river")
        try TestStore.makeCard(in: f.context, for: entry, direction: .recognition, due: referenceDate, intervalDays: 30)
        try TestStore.makeCard(in: f.context, for: entry, direction: .production, due: referenceDate, intervalDays: 5)

        let events = try f.service.record(
            event(entryStableID: entry.stableID, maturityBefore: .young, maturityAfter: .mature),
            preferences: f.preferences, now: referenceDate
        )
        XCTAssertFalse(events.contains(.stickerLit(entryStableID: entry.stableID)))
        XCTAssertTrue(try f.service.profile().completedAlbumIDs.isEmpty)
    }

    // MARK: - Side effects

    func testSnapshotIsWrittenAfterEachGrade() throws {
        let f = try makeFixture()
        try TestStore.makeStudyDay(
            in: f.context, userID: f.account.userID, calendar: f.calendar,
            daysAgo: 0, reviews: 4, from: referenceDate
        )
        let reader = WidgetSnapshotWriter(url: snapshotURL)
        XCTAssertNil(reader.read())

        _ = try f.service.record(event(), preferences: f.preferences, now: referenceDate)
        let first = try XCTUnwrap(reader.read())
        XCTAssertEqual(first.candy, try f.service.profile().candyTotal)
        XCTAssertEqual(first.reviewsToday, 4)
        XCTAssertTrue(first.studiedToday)
        XCTAssertEqual(first.streak, 1)
        XCTAssertEqual(first.updatedAt, referenceDate)

        let later = referenceDate.addingTimeInterval(60)
        _ = try f.service.record(event(), preferences: f.preferences, now: later)
        let second = try XCTUnwrap(reader.read())
        XCTAssertEqual(second.candy, first.candy + RewardEngine.candyPerReview)
        XCTAssertEqual(second.updatedAt, later)
    }
}
