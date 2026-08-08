import XCTest
import SwiftData
@testable import VocabLoop

/// Daily-word selection must be **deterministic** in `(user, day, language)`. A "word of the day"
/// that changes when you reopen the app reads as a bug, and after a reinstall it would look like
/// lost data.
@MainActor
final class DailyWordTests: XCTestCase {

    private func makeFixture(entryCount: Int = 40) throws -> (ModelContext, UserAccount, StudyPreferences) {
        let context = try TestStore.makeContext()
        let account = try context.activeAccount()
        let preferences = try XCTUnwrap(account.preferences)
        // A batch's key contains a study-day key, so this suite is asserting about day boundaries
        // whether it means to or not. Without pinning, it asserts about the machine's timezone.
        pinToUTC(preferences)
        preferences.newWordsPerDay = 5
        preferences.cefrFloor = .a1
        preferences.cefrCeiling = .c2

        for index in 0..<entryCount {
            _ = try TestStore.makeEntry(
                in: context,
                headword: "word\(String(format: "%03d", index))",
                cefr: .a1,
                frequencyRank: index + 1
            )
        }
        try context.save()
        return (context, account, preferences)
    }

    func testSelectionIsDeterministicForTheSameDay() throws {
        let (context, account, preferences) = try makeFixture()
        let service = DailyWordService(context: context)

        let first = try service.selectEntryStableIDs(
            for: account, preferences: preferences, dayKey: "2025-03-15"
        )
        for _ in 0..<10 {
            XCTAssertEqual(
                try service.selectEntryStableIDs(
                    for: account, preferences: preferences, dayKey: "2025-03-15"
                ),
                first
            )
        }
    }

    func testDifferentDaysGiveDifferentWords() throws {
        let (context, account, preferences) = try makeFixture()
        let service = DailyWordService(context: context)

        let monday = try service.selectEntryStableIDs(
            for: account, preferences: preferences, dayKey: "2025-03-17"
        )
        let tuesday = try service.selectEntryStableIDs(
            for: account, preferences: preferences, dayKey: "2025-03-18"
        )
        XCTAssertNotEqual(monday, tuesday, "consecutive days should not offer the same words")
    }

    func testSelectionHonoursTheDailyLimit() throws {
        let (context, account, preferences) = try makeFixture()
        let service = DailyWordService(context: context)

        for limit in [0, 1, 5, 12] {
            preferences.newWordsPerDay = limit
            let selection = try service.selectEntryStableIDs(
                for: account, preferences: preferences, dayKey: "2025-03-15"
            )
            XCTAssertEqual(selection.count, limit)
            XCTAssertEqual(Set(selection).count, selection.count, "no repeats within a batch")
        }
    }

    /// A uniform draw over a 10,000-word dictionary would serve mostly rare words. Selection is
    /// weighted toward frequency so a beginner meets "because" before "ubiquitous".
    func testSelectionPrefersFrequentWords() throws {
        let (context, account, preferences) = try makeFixture(entryCount: 400)
        preferences.newWordsPerDay = 5
        let service = DailyWordService(context: context)

        var ranks: [Int] = []
        for day in 1...20 {
            let selection = try service.selectEntryStableIDs(
                for: account, preferences: preferences, dayKey: String(format: "2025-03-%02d", day)
            )
            for stableID in selection {
                if let entry = try context.entry(stableID: stableID), let rank = entry.frequencyRank {
                    ranks.append(rank)
                }
            }
        }
        XCTAssertFalse(ranks.isEmpty)
        // The draw window is capped at `max(target * 12, 60)` of the frequency-ranked list, so no
        // selected word may come from beyond it.
        XCTAssertLessThanOrEqual(ranks.max() ?? 0, 60, "selection strayed outside the frequency window")
    }

    func testCEFRRangeIsRespected() throws {
        let context = try TestStore.makeContext()
        let account = try context.activeAccount()
        let preferences = try XCTUnwrap(account.preferences)
        preferences.newWordsPerDay = 10
        preferences.cefrFloor = .b1
        preferences.cefrCeiling = .b2

        _ = try TestStore.makeEntry(in: context, headword: "beginner", cefr: .a1, frequencyRank: 1)
        _ = try TestStore.makeEntry(in: context, headword: "intermediate", cefr: .b1, frequencyRank: 2)
        _ = try TestStore.makeEntry(in: context, headword: "upper", cefr: .b2, frequencyRank: 3)
        _ = try TestStore.makeEntry(in: context, headword: "advanced", cefr: .c1, frequencyRank: 4)

        let service = DailyWordService(context: context)
        let selection = try service.selectEntryStableIDs(
            for: account, preferences: preferences, dayKey: "2025-03-15"
        )
        let headwords = try selection.compactMap { try context.entry(stableID: $0)?.headword }.sorted()
        XCTAssertEqual(headwords, ["intermediate", "upper"])
    }

    func testAlreadyEnrolledWordsAreNotOffered() throws {
        let (context, account, preferences) = try makeFixture(entryCount: 10)
        preferences.newWordsPerDay = 10

        let enrolled = try XCTUnwrap(try context.entry(
            stableID: Entry.makeStableID(language: "en", headword: "word000")
        ))
        try TestStore.makeCard(in: context, for: enrolled, phase: .new, due: referenceDate, intervalDays: 0)

        let service = DailyWordService(context: context)
        let selection = try service.selectEntryStableIDs(
            for: account, preferences: preferences, dayKey: "2025-03-15"
        )
        XCTAssertFalse(selection.contains(enrolled.stableID))
    }

    /// "Not this one" has to mean it, or the feature is worse than useless.
    func testDismissedWordsAreNeverOfferedAgain() throws {
        let (context, account, preferences) = try makeFixture(entryCount: 10)
        preferences.newWordsPerDay = 3
        let service = DailyWordService(context: context)

        let batch = try service.batch(for: account, preferences: preferences, now: referenceDate)
        let dismissedID = try XCTUnwrap(batch.entryStableIDs.first)
        let dismissedEntry = try XCTUnwrap(try context.entry(stableID: dismissedID))
        try service.dismiss(entry: dismissedEntry, in: batch)

        for day in 1...10 {
            let selection = try service.selectEntryStableIDs(
                for: account, preferences: preferences,
                dayKey: String(format: "2025-04-%02d", day)
            )
            XCTAssertFalse(selection.contains(dismissedID), "day \(day) re-offered a dismissed word")
        }
    }

    func testPausedDecksDoNotContributeNewWords() throws {
        let context = try TestStore.makeContext()
        let account = try context.activeAccount()
        let preferences = try XCTUnwrap(account.preferences)
        preferences.newWordsPerDay = 10

        let active = Deck(slug: "active", name: "Active", languageCode: "en", isBuiltIn: true)
        let paused = Deck(slug: "paused", name: "Paused", languageCode: "en", isBuiltIn: true)
        paused.isActiveForNewWords = false
        context.insert(active)
        context.insert(paused)

        let fromActive = try TestStore.makeEntry(in: context, headword: "activeword", frequencyRank: 1)
        let fromPaused = try TestStore.makeEntry(in: context, headword: "pausedword", frequencyRank: 2)
        fromActive.decks.append(active)
        fromPaused.decks.append(paused)
        try context.save()

        let service = DailyWordService(context: context)
        let selection = try service.selectEntryStableIDs(
            for: account, preferences: preferences, dayKey: "2025-03-15"
        )
        XCTAssertTrue(selection.contains(fromActive.stableID))
        XCTAssertFalse(selection.contains(fromPaused.stableID))
    }

    /// The batch is persisted, so the words seen this morning are still there this evening.
    func testBatchIsPersistedAndReusedWithinTheSameDay() throws {
        let (context, account, preferences) = try makeFixture()
        let service = DailyWordService(context: context)

        let morning = try service.batch(for: account, preferences: preferences, now: referenceDate)
        let evening = try service.batch(
            for: account, preferences: preferences, now: referenceDate.addingTimeInterval(8 * 3600)
        )

        XCTAssertEqual(morning.key, evening.key)
        XCTAssertEqual(morning.entryStableIDs, evening.entryStableIDs)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DailyBatch>()), 1)
    }

    func testAcceptingAWordEnrolsItAndRecordsAcceptance() throws {
        let (context, account, preferences) = try makeFixture()
        let service = DailyWordService(context: context)
        let review = ReviewService(context: context)

        let batch = try service.batch(for: account, preferences: preferences, now: referenceDate)
        let entry = try XCTUnwrap(try context.entry(stableID: try XCTUnwrap(batch.entryStableIDs.first)))

        try service.accept(
            entry: entry, in: batch, preferences: preferences,
            reviewService: review, now: referenceDate
        )

        XCTAssertTrue(batch.acceptedEntryStableIDs.contains(entry.stableID))
        XCTAssertTrue(entry.isEnrolled)
        XCTAssertEqual(entry.cards.count, preferences.enabledDirections.count)
    }

    /// Accepting twice — a double tap on the app's most-tapped control — must not create a second
    /// set of cards or reset the first.
    func testAcceptingTwiceIsIdempotent() throws {
        let (context, account, preferences) = try makeFixture()
        let service = DailyWordService(context: context)
        let review = ReviewService(context: context)

        let batch = try service.batch(for: account, preferences: preferences, now: referenceDate)
        let entry = try XCTUnwrap(try context.entry(stableID: try XCTUnwrap(batch.entryStableIDs.first)))

        try service.accept(entry: entry, in: batch, preferences: preferences, reviewService: review)
        try service.accept(entry: entry, in: batch, preferences: preferences, reviewService: review)

        XCTAssertEqual(entry.cards.count, preferences.enabledDirections.count)
        XCTAssertEqual(batch.acceptedEntryStableIDs.filter { $0 == entry.stableID }.count, 1)
    }

    func testBatchEntriesComeBackInGeneratedOrder() throws {
        let (context, account, preferences) = try makeFixture()
        let service = DailyWordService(context: context)

        let batch = try service.batch(for: account, preferences: preferences, now: referenceDate)
        let entries = try service.entries(in: batch)
        XCTAssertEqual(entries.map(\.stableID), batch.entryStableIDs)
    }

    func testEmptyDictionaryProducesAnEmptyBatchRatherThanFailing() throws {
        let context = try TestStore.makeContext()
        let account = try context.activeAccount()
        let preferences = try XCTUnwrap(account.preferences)
        let service = DailyWordService(context: context)

        let batch = try service.batch(for: account, preferences: preferences, now: referenceDate)
        XCTAssertTrue(batch.entryStableIDs.isEmpty)
    }

    // MARK: - Seeded generator

    /// The generator must not use Swift's `Hasher`, which is seeded per process — the same inputs
    /// would produce a different batch on every launch.
    func testSeedIsStableAcrossInstances() {
        let a = DailyWordService.seed(userID: "user-1", dayKey: "2025-03-15", languageCode: "en")
        let b = DailyWordService.seed(userID: "user-1", dayKey: "2025-03-15", languageCode: "en")
        XCTAssertEqual(a, b)

        XCTAssertNotEqual(
            a, DailyWordService.seed(userID: "user-2", dayKey: "2025-03-15", languageCode: "en")
        )
        XCTAssertNotEqual(
            a, DailyWordService.seed(userID: "user-1", dayKey: "2025-03-16", languageCode: "en")
        )
        XCTAssertNotEqual(
            a, DailyWordService.seed(userID: "user-1", dayKey: "2025-03-15", languageCode: "fr")
        )
    }

    func testSeededGeneratorIsReproducibleAndNonDegenerate() {
        var first = SeededGenerator(seed: 42)
        var second = SeededGenerator(seed: 42)
        let a = (0..<32).map { _ in first.next() }
        let b = (0..<32).map { _ in second.next() }
        XCTAssertEqual(a, b)
        XCTAssertEqual(Set(a).count, a.count, "a usable generator must not repeat immediately")

        // A zero seed makes SplitMix64 degenerate, so it is nudged off zero.
        var zero = SeededGenerator(seed: 0)
        let zeroValues = (0..<8).map { _ in zero.next() }
        XCTAssertFalse(zeroValues.allSatisfy { $0 == 0 })
    }
}
