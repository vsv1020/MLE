import XCTest
import SwiftData
@testable import VocabLoop

/// Queue ordering. These rules are what make a session feel fair rather than arbitrary, so they
/// are pinned rather than left to emerge from the fetch order.
@MainActor
final class ReviewQueueTests: XCTestCase {
    private let builder = ReviewQueueBuilder()

    private func makeContext() throws -> ModelContext {
        let context = try TestStore.makeContext()
        _ = try TestStore.makeAccount(in: context)
        return context
    }

    func testOnlyDueCardsAreIncludedByDefault() throws {
        let context = try makeContext()
        let due = try TestStore.makeEntry(in: context, headword: "duenow")
        let later = try TestStore.makeEntry(in: context, headword: "duelater")
        try TestStore.makeCard(in: context, for: due, due: referenceDate.addingTimeInterval(-3600))
        try TestStore.makeCard(in: context, for: later, due: referenceDate.addingTimeInterval(86_400))

        let queue = try builder.build(in: context, at: referenceDate, options: .init())
        XCTAssertEqual(queue.items.map(\.entryStableID), [due.stableID])
    }

    func testStudyAheadIncludesNotYetDueCards() throws {
        let context = try makeContext()
        let later = try TestStore.makeEntry(in: context, headword: "duelater")
        try TestStore.makeCard(in: context, for: later, due: referenceDate.addingTimeInterval(86_400))

        let queue = try builder.build(
            in: context, at: referenceDate, options: .init(includeAhead: true)
        )
        XCTAssertEqual(queue.count, 1)
    }

    /// Intraday steps are time-critical by construction: a card the user saw two minutes ago and
    /// rated `Again` must come back promptly or the step means nothing.
    func testLearningCardsComeBeforeReviewCards() throws {
        let context = try makeContext()
        let review = try TestStore.makeEntry(in: context, headword: "mature", frequencyRank: 1)
        let learning = try TestStore.makeEntry(in: context, headword: "learning", frequencyRank: 2)

        try TestStore.makeCard(
            in: context, for: review, phase: .review,
            due: referenceDate.addingTimeInterval(-10 * 86_400), intervalDays: 30
        )
        try TestStore.makeCard(
            in: context, for: learning, phase: .learning,
            due: referenceDate.addingTimeInterval(-60), intervalDays: 0.007
        )

        let queue = try builder.build(in: context, at: referenceDate, options: .init())
        XCTAssertEqual(queue.items.first?.entryStableID, learning.stableID)
    }

    /// Most overdue *relative to its own interval*, not by raw lateness. A 1-day card two days
    /// late has decayed far more than a 200-day card two days late.
    func testReviewsAreOrderedByOverdueRatioNotRawLateness() throws {
        let context = try makeContext()
        let shortInterval = try TestStore.makeEntry(in: context, headword: "shortinterval")
        let longInterval = try TestStore.makeEntry(in: context, headword: "longinterval")

        // Two days late on a one-day interval: 200% overdue.
        try TestStore.makeCard(
            in: context, for: shortInterval, phase: .review,
            due: referenceDate.addingTimeInterval(-2 * 86_400), intervalDays: 1
        )
        // Five days late on a 200-day interval: 2.5% overdue.
        try TestStore.makeCard(
            in: context, for: longInterval, phase: .review,
            due: referenceDate.addingTimeInterval(-5 * 86_400), intervalDays: 200
        )

        let queue = try builder.build(in: context, at: referenceDate, options: .init())
        XCTAssertEqual(
            queue.items.first?.entryStableID, shortInterval.stableID,
            "the more decayed card must come first even though it is less late in absolute terms"
        )
    }

    /// Frequency order, so early sessions teach useful vocabulary rather than whatever the fetch
    /// happened to return.
    func testNewCardsAreOrderedByFrequencyRank() throws {
        let context = try makeContext()
        let rare = try TestStore.makeEntry(in: context, headword: "ubiquitous", frequencyRank: 11_500)
        let common = try TestStore.makeEntry(in: context, headword: "because", frequencyRank: 91)
        try TestStore.makeCard(in: context, for: rare, phase: .new, due: referenceDate, intervalDays: 0)
        try TestStore.makeCard(in: context, for: common, phase: .new, due: referenceDate, intervalDays: 0)

        let queue = try builder.build(in: context, at: referenceDate, options: .init(maxNewCards: 5))
        XCTAssertEqual(queue.items.map(\.entryStableID), [common.stableID, rare.stableID])
    }

    func testNewCardsAreCapped() throws {
        let context = try makeContext()
        for index in 0..<10 {
            let entry = try TestStore.makeEntry(
                in: context, headword: "word\(index)", frequencyRank: index
            )
            try TestStore.makeCard(in: context, for: entry, phase: .new, due: referenceDate, intervalDays: 0)
        }
        let queue = try builder.build(in: context, at: referenceDate, options: .init(maxNewCards: 3))
        XCTAssertEqual(queue.count, 3)
    }

    /// Capping the session must not imply the backlog is gone — the UI reports this number.
    func testSessionCapReportsWhatItDeferred() throws {
        let context = try makeContext()
        for index in 0..<10 {
            let entry = try TestStore.makeEntry(in: context, headword: "word\(index)")
            try TestStore.makeCard(
                in: context, for: entry, phase: .review,
                due: referenceDate.addingTimeInterval(-3600), intervalDays: 5
            )
        }
        let queue = try builder.build(
            in: context, at: referenceDate, options: .init(maxCards: 4, maxNewCards: 0)
        )
        XCTAssertEqual(queue.count, 4)
        XCTAssertEqual(queue.deferredCount, 6)
    }

    func testSuspendedAndBuriedCardsAreExcluded() throws {
        let context = try makeContext()
        let suspended = try TestStore.makeEntry(in: context, headword: "suspended")
        let buried = try TestStore.makeEntry(in: context, headword: "buried")
        let normal = try TestStore.makeEntry(in: context, headword: "normal")

        let suspendedCard = try TestStore.makeCard(
            in: context, for: suspended, due: referenceDate.addingTimeInterval(-60)
        )
        suspendedCard.isSuspended = true

        let buriedCard = try TestStore.makeCard(
            in: context, for: buried, due: referenceDate.addingTimeInterval(-60)
        )
        buriedCard.buriedUntil = referenceDate.addingTimeInterval(86_400)

        try TestStore.makeCard(in: context, for: normal, due: referenceDate.addingTimeInterval(-60))
        try context.save()

        let queue = try builder.build(in: context, at: referenceDate, options: .init())
        XCTAssertEqual(queue.items.map(\.entryStableID), [normal.stableID])
    }

    /// Answering a word's recognition card and then immediately its production card tests
    /// short-term memory, not recall.
    func testSiblingCardsAreSeparatedInTheQueue() throws {
        let context = try makeContext()
        var cards: [Card] = []
        for index in 0..<4 {
            let entry = try TestStore.makeEntry(
                in: context, headword: "word\(index)", frequencyRank: index
            )
            for direction in CardDirection.allCases {
                cards.append(try TestStore.makeCard(
                    in: context, for: entry, direction: direction, phase: .new,
                    due: referenceDate, intervalDays: 0
                ))
            }
        }

        let separated = builder.separateSiblings(cards, minimumGap: 4)
        XCTAssertEqual(separated.count, cards.count, "no card may be lost or duplicated")
        XCTAssertEqual(
            Set(separated.map(\.cardID)), Set(cards.map(\.cardID)),
            "the same set of cards must come out"
        )

        var lastPosition: [String: Int] = [:]
        for (position, card) in separated.enumerated() {
            let key = card.entry?.stableID ?? card.cardID
            if let previous = lastPosition[key] {
                XCTAssertGreaterThanOrEqual(
                    position - previous, 4,
                    "siblings of \(key) landed \(position - previous) apart"
                )
            }
            lastPosition[key] = position
        }
    }

    /// Separation is best-effort: it must never drop or duplicate a card even when the gap cannot
    /// be honoured, which is what happens near the end of a queue.
    func testSiblingSeparationIsLosslessWhenTheGapCannotBeMet() throws {
        let context = try makeContext()
        let entry = try TestStore.makeEntry(in: context, headword: "onlyword")
        let cards = try CardDirection.allCases.map {
            try TestStore.makeCard(
                in: context, for: entry, direction: $0, phase: .new,
                due: referenceDate, intervalDays: 0
            )
        }
        let separated = builder.separateSiblings(cards, minimumGap: 10)
        XCTAssertEqual(Set(separated.map(\.cardID)), Set(cards.map(\.cardID)))
        XCTAssertEqual(separated.count, cards.count)
    }

    func testLanguageFilterScopesTheQueue() throws {
        let context = try makeContext()
        let english = try TestStore.makeEntry(in: context, headword: "english", language: .english)
        let french = try TestStore.makeEntry(in: context, headword: "français", language: .french)
        try TestStore.makeCard(in: context, for: english, due: referenceDate.addingTimeInterval(-60))
        try TestStore.makeCard(in: context, for: french, due: referenceDate.addingTimeInterval(-60))

        let queue = try builder.build(
            in: context, at: referenceDate, options: .init(languageCode: "fr")
        )
        XCTAssertEqual(queue.items.map(\.entryStableID), [french.stableID])
    }

    func testDeckFilterScopesTheQueue() throws {
        let context = try makeContext()
        let deck = Deck(slug: "test-deck", name: "Test", languageCode: "en")
        context.insert(deck)

        let inDeck = try TestStore.makeEntry(in: context, headword: "indeck")
        let outside = try TestStore.makeEntry(in: context, headword: "outside")
        inDeck.decks.append(deck)
        try context.save()

        try TestStore.makeCard(in: context, for: inDeck, due: referenceDate.addingTimeInterval(-60))
        try TestStore.makeCard(in: context, for: outside, due: referenceDate.addingTimeInterval(-60))

        let queue = try builder.build(
            in: context, at: referenceDate, options: .init(deckSlug: "test-deck")
        )
        XCTAssertEqual(queue.items.map(\.entryStableID), [inDeck.stableID])
    }

    func testEmptyStoreProducesAnEmptyQueueRatherThanFailing() throws {
        let context = try makeContext()
        let queue = try builder.build(in: context, at: referenceDate, options: .init())
        XCTAssertTrue(queue.isEmpty)
        XCTAssertEqual(queue.deferredCount, 0)
    }
}
