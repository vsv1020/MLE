import XCTest
import SwiftData
@testable import VocabLoop

/// One test per bug found by review rather than by a failing test.
///
/// Each of these was reachable in normal use and none of them would have crashed — they would
/// have shown a wrong number, or quietly grown the database. That is exactly the class of
/// defect a test suite has to carry, because nothing else will catch it twice.
@MainActor
final class RegressionTests: XCTestCase {

    // MARK: - Outbox growth from a slider drag

    /// Preferences are last-write-wins, so a pending row must be *replaced*, not appended to.
    ///
    /// The retention slider saves on every tick. Dragging it across its range at 1% steps
    /// called `enqueuePreferences` 27 times, leaving 27 rows each holding a full payload.
    func testRepeatedPreferenceSavesReplaceTheirOutboxRowInsteadOfAppending() throws {
        let context = try TestStore.makeContext()
        let account = try context.activeAccount()
        let preferences = try XCTUnwrap(account.preferences)

        let engine = SyncEngine(
            context: context,
            client: APIClient(configuration: .offline),
            monitor: NetworkMonitor(),
            isServerConfigured: false
        )

        // Simulate the drag.
        for percent in stride(from: 0.70, through: 0.97, by: 0.01) {
            preferences.desiredRetention = (percent * 100).rounded() / 100
            engine.enqueuePreferences(preferences)
        }

        let rows = try context.fetch(
            FetchDescriptor<SyncOutboxItem>(
                predicate: #Predicate { $0.subjectID == "preferences" }
            )
        )
        XCTAssertEqual(rows.count, 1, "28 saves left \(rows.count) rows; they must collapse to one")

        // And the surviving row must hold the *last* value, not the first.
        let payload = try JSONDecoder().decode(PreferencesSyncPayload.self, from: rows[0].payload)
        XCTAssertEqual(payload.desiredRetention, 0.97, accuracy: 1e-9)
    }

    /// Replacing must not reorder the queue: the server needs the change where the user made
    /// it, not jumped to the end.
    func testReplacedPreferencesKeepTheirOriginalQueuePosition() throws {
        let context = try TestStore.makeContext()
        let account = try context.activeAccount()
        let preferences = try XCTUnwrap(account.preferences)
        let engine = SyncEngine(
            context: context, client: APIClient(configuration: .offline),
            monitor: NetworkMonitor(), isServerConfigured: false
        )

        engine.enqueuePreferences(preferences)
        let firstSequence = try XCTUnwrap(
            try context.fetch(FetchDescriptor<SyncOutboxItem>()).first?.sequence
        )

        // A later, unrelated write.
        let entry = try TestStore.makeEntry(in: context, headword: "alpha")
        try ReviewService(context: context).enroll(entry: entry, preferences: preferences)

        preferences.dailyGoal = 99
        engine.enqueuePreferences(preferences)

        let preferenceRows = try context.fetch(
            FetchDescriptor<SyncOutboxItem>(predicate: #Predicate { $0.subjectID == "preferences" })
        )
        XCTAssertEqual(preferenceRows.count, 1)
        XCTAssertEqual(
            preferenceRows[0].sequence, firstSequence,
            "the row must stay where it was queued"
        )
    }

    // MARK: - New-card count after accepting a daily word

    /// `enabledDirections.count` is not the number of cards created: cloze is skipped for an
    /// entry with no maskable example. Assuming it overstated the count on the Today tile.
    func testAcceptReportsCardsActuallyCreatedNotEnabledDirections() throws {
        let context = try TestStore.makeContext()
        let account = try context.activeAccount()
        let preferences = try XCTUnwrap(account.preferences)
        preferences.enabledDirections = [.recognition, .production, .cloze]

        let daily = DailyWordService(context: context)
        let review = ReviewService(context: context)

        // No examples, so cloze cannot be built — 2 cards, not 3.
        let unmaskable = try TestStore.makeEntry(in: context, headword: "unexampled")
        let batch = DailyBatch(
            userID: account.userID, dayKey: "2025-03-15", languageCode: "en",
            entryStableIDs: [unmaskable.stableID]
        )
        context.insert(batch)
        try context.save()

        let created = try daily.accept(
            entry: unmaskable, in: batch, preferences: preferences, reviewService: review
        )
        XCTAssertEqual(created.count, 2)
        XCTAssertNotEqual(
            created.count, preferences.enabledDirections.count,
            "this fixture exists precisely because the two differ"
        )

        // Re-accepting creates nothing, so a caller adding blindly would double-count.
        let again = try daily.accept(
            entry: unmaskable, in: batch, preferences: preferences, reviewService: review
        )
        XCTAssertTrue(again.isEmpty)
    }

    // MARK: - Session counter when a card comes back

    /// Pressing Again re-queues the card, so the session really is longer. Without growing the
    /// denominator the header read "25/20", which looks like a bug rather than a consequence.
    func testSessionDenominatorGrowsWhenACardIsRequeued() throws {
        // The real object graph rather than a bare context: `StudyViewModel.start` reads
        // `dependencies.preferences` and grades through `dependencies.review`, so a fixture
        // built on a separate context would not be the one the session sees. `dependencies.context`
        // *is* the container's `mainContext`, so the cards written below are the cards queued.
        let container = try PersistenceController.makeInMemoryContainer()
        let dependencies = AppDependencies(container: container)
        let context = dependencies.context

        _ = try context.activeAccount()

        // Three separate words, so a re-queued card has somewhere to go.
        for index in 0..<3 {
            let entry = try TestStore.makeEntry(
                in: context, headword: "word\(index)", frequencyRank: index
            )
            try TestStore.makeCard(
                in: context, for: entry, phase: .new, due: referenceDate, intervalDays: 0
            )
        }

        let model = StudyViewModel()
        model.start(
            dependencies: dependencies,
            options: .init(maxNewCards: 3, languageCode: "en"),
            now: referenceDate
        )
        XCTAssertEqual(model.plannedCount, 3, "all three new cards should be queued")
        let planned = model.plannedCount

        model.revealAnswer(now: referenceDate)
        model.grade(.again, dependencies: dependencies, now: referenceDate)

        XCTAssertEqual(model.plannedCount, planned + 1, "Again re-queues, so the session is longer")
        XCTAssertLessThanOrEqual(model.progress, 1.0, "progress must never exceed 1")
        XCTAssertEqual(model.reviewedCount, 1)
    }

    /// Progress is a ratio shown as a bar, so it must stay in `0...1` no matter how many times
    /// a card comes back.
    func testProgressIsAlwaysClamped() throws {
        let model = StudyViewModel()
        XCTAssertEqual(model.progress, 0, "an unstarted session is not complete")
        XCTAssertNil(model.accuracy, "accuracy is unknown before the first answer, not 0%")
    }

    // MARK: - Pausing and resuming a whole word

    /// Resuming a word must unsuspend *all* of its cards.
    ///
    /// The bug was a loop at the call site: "is this word paused?" is derived from the cards, so
    /// unsuspending the first one made the condition false and the loop suspended the second one
    /// instead. A word with two directions could not be resumed at all — it just swapped which
    /// card was paused.
    func testResumingAWordUnsuspendsEveryOneOfItsCards() throws {
        let context = try TestStore.makeContext()
        _ = try context.activeAccount()
        let review = ReviewService(context: context)

        let entry = try TestStore.makeEntry(in: context, headword: "reversible")
        for direction in [CardDirection.recognition, .production] {
            let card = try TestStore.makeCard(
                in: context, for: entry, direction: direction, due: referenceDate
            )
            card.isSuspended = true
        }
        try context.save()
        XCTAssertEqual(entry.cards.count, 2)
        XCTAssertTrue(entry.cards.allSatisfy(\.isSuspended), "the fixture starts fully paused")

        try review.setSuspended(false, for: entry)
        XCTAssertTrue(
            entry.cards.allSatisfy { !$0.isSuspended },
            "every card must resume, not just the first"
        )

        // And the other direction, which never had the bug — the target only flips while resuming.
        try review.setSuspended(true, for: entry)
        XCTAssertTrue(entry.cards.allSatisfy(\.isSuspended))
    }

    /// Resetting a word resets every card, and keeps the review log.
    func testResettingAWordResetsEveryOneOfItsCards() throws {
        let context = try TestStore.makeContext()
        _ = try context.activeAccount()
        let review = ReviewService(context: context)

        let entry = try TestStore.makeEntry(in: context, headword: "recoverable")
        for direction in [CardDirection.recognition, .production] {
            try TestStore.makeCard(
                in: context, for: entry, direction: direction,
                phase: .review, due: referenceDate, intervalDays: 40, stability: 40
            )
        }
        try context.save()

        try review.resetProgress(for: entry, now: referenceDate)
        for card in entry.cards {
            XCTAssertEqual(card.phase, .new, "\(card.direction) was left scheduled")
            XCTAssertEqual(card.intervalDays, 0, accuracy: 1e-9)
        }
    }

    // MARK: - HTTPS enforcement

    /// A bearer token must never leave the device in clear text because someone pointed the
    /// app at a local http server.
    ///
    /// The predicate is tested rather than the initialiser: constructing a rejected
    /// configuration trips `assertionFailure`, which aborts the whole test run.
    func testOnlyHTTPSBaseURLsAreAcceptable() {
        XCTAssertTrue(APIConfiguration.isTransportAcceptable(nil), "no server is the shipping default")
        XCTAssertTrue(APIConfiguration.isTransportAcceptable(URL(string: "https://api.example.com")))
        XCTAssertTrue(APIConfiguration.isTransportAcceptable(URL(string: "HTTPS://api.example.com")))

        for rejected in ["http://api.example.com", "http://localhost:8080", "ws://api.example.com",
                         "file:///tmp/x", "ftp://example.com"] {
            XCTAssertFalse(
                APIConfiguration.isTransportAcceptable(URL(string: rejected)),
                "\(rejected) must be refused"
            )
        }

        XCTAssertNil(APIConfiguration.offline.baseURL, "the shipping default must have no server")
        XCTAssertNotNil(
            APIConfiguration(baseURL: URL(string: "https://api.example.com")).baseURL,
            "a valid https URL must survive the initialiser"
        )
    }
}
