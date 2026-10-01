import XCTest
import SwiftData
@testable import VocabLoop

/// The 1.0.7 schema change: one new entity and three defaulted preferences.
///
/// SwiftData failures here surface as a launch that quarantines the user's store, so the cheapest
/// place to catch them is a container that opens with the full schema.
@MainActor
final class EngagementProfileSchemaTests: XCTestCase {
    private var snapshotURL: URL!

    override func setUp() {
        super.setUp()
        snapshotURL = FileManager.default.temporaryDirectory
            .appending(path: "engagement-schema-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: snapshotURL)
        super.tearDown()
    }

    private func makeService(context: ModelContext) -> EngagementService {
        EngagementService(
            context: context,
            notifications: NotificationService(),
            snapshots: WidgetSnapshotWriter(url: snapshotURL),
            entitlements: Entitlements(defaults: nil)
        )
    }

    func testSchemaRegistersTheProfileAndOpensInMemory() throws {
        let names = PersistenceController.schema.entities.map(\.name)
        XCTAssertTrue(names.contains("EngagementProfile"), "registered entities: \(names)")

        let context = try TestStore.makeContext()
        context.insert(EngagementProfile(userID: "someone"))
        try context.save()
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<EngagementProfile>()), 1)
    }

    func testNewProfileStartsAtTheDefaults() throws {
        let context = try TestStore.makeContext()
        let profile = EngagementProfile(userID: "u")
        context.insert(profile)
        XCTAssertEqual(profile.candyTotal, 0)
        XCTAssertEqual(profile.level, 1)
        XCTAssertEqual(profile.bodyColorRaw, "vanilla")
        XCTAssertEqual(profile.bodyColor, .vanilla)
        XCTAssertTrue(profile.equippedAccessoryIDs.isEmpty)
        XCTAssertTrue(profile.unlockedAchievements.isEmpty)
        XCTAssertNil(profile.lastStudiedAt)
    }

    func testProfileIsCreatedOnceForTheActiveAccount() throws {
        let context = try TestStore.makeContext()
        let account = try context.activeAccount()
        let service = makeService(context: context)

        let first = try service.profile()
        let second = try service.profile()
        XCTAssertEqual(first.userID, account.userID)
        XCTAssertEqual(first.persistentModelID, second.persistentModelID)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<EngagementProfile>()), 1)
    }

    func testNewPreferencesDefaultOn() throws {
        let context = try TestStore.makeContext()
        let stored = try XCTUnwrap(try context.activeAccount().preferences)
        XCTAssertTrue(stored.soundEffectsEnabled)
        XCTAssertTrue(stored.quizModesEnabled)
        XCTAssertTrue(stored.streakReminderEnabled)
    }

    func testRecordAddsCandyAndRemembersWhenTheLearnerStudied() throws {
        let context = try TestStore.makeContext()
        let account = try context.activeAccount()
        let preferences = try XCTUnwrap(account.preferences)
        pinToUTC(preferences)
        let service = makeService(context: context)

        let event = ReviewOutcomeEvent(
            cardID: "en:apple:1#recognition", entryStableID: "en:apple:1", rating: .again,
            questionKind: .flip, wasAutoGraded: false, responseMS: 2_000,
            phaseBefore: .review, maturityBefore: .young, maturityAfter: .learning,
            comboAfter: 0, justReachedGoal: false, reviewsToday: 1
        )
        let events = try service.record(event, preferences: preferences, now: referenceDate)
        // W2: the first review also pays the first-of-day bonus and unlocks `first_review`.
        let expected = RewardEngine.candyPerReview + RewardEngine.firstReviewBonus + RewardEngine.achievementBonus
        XCTAssertEqual(events.first, EngagementEvent.candy(expected), "a Forgot earns the same base candy")

        let profile = try service.profile()
        XCTAssertEqual(profile.candyTotal, expected)
        XCTAssertEqual(profile.lastStudiedAt, referenceDate)
    }

    func testSessionOpeningReportsDaysAwayFromHistory() throws {
        let context = try TestStore.makeContext()
        let account = try context.activeAccount()
        let preferences = try XCTUnwrap(account.preferences)
        pinToUTC(preferences)
        let calendar = StudyCalendar(preferences: preferences)
        try TestStore.makeStudyDay(
            in: context, userID: account.userID, calendar: calendar,
            daysAgo: 4, reviews: 10, from: referenceDate
        )
        let service = makeService(context: context)

        let opening = try service.sessionOpened(preferences: preferences, now: referenceDate)
        XCTAssertEqual(opening.daysSinceLastStudy, 4, "an upgrade with history but no profile still counts")
        XCTAssertFalse(opening.studiedToday)
        XCTAssertEqual(opening.streak.current, 0)
        XCTAssertEqual(opening.candyTotal, 0)
        XCTAssertEqual(opening.level, 1)
        XCTAssertEqual(opening.look, .default)
    }

    func testLockedWardrobeItemsCannotBeWorn() throws {
        let context = try TestStore.makeContext()
        _ = try context.activeAccount()
        let service = makeService(context: context)

        try service.setEquipped(.crown, slot: .head)
        try service.setBodyColor(.galaxy)
        XCTAssertEqual(service.currentLook(), .default, "level 1 without Plus wears nothing new")

        let profile = try service.profile()
        profile.candyTotal = RewardEngine.candyRequired(toReach: 8)
        try service.setEquipped(.crown, slot: .head)
        try service.setEquipped(.redScarf, slot: .neck)
        try service.setEquipped(.partyHat, slot: .head)
        XCTAssertEqual(Set(service.currentLook().accessories), [.partyHat, .redScarf], "one item per slot")
        XCTAssertEqual(service.currentLook().stage, .kid)
    }
}
