import XCTest
@testable import VocabLoop

/// Fuzz must be *deterministic*. A card's due date shifting because a schedule was previewed
/// twice, recomputed, or replayed from the review log during a sync merge would make every one
/// of those operations non-idempotent — which is a far worse bug than clumped reviews.
final class FuzzTests: XCTestCase {
    func testFuzzIsDeterministicForTheSameSeedAndInterval() {
        for interval in [3.0, 10.0, 45.0, 400.0] {
            let first = Fuzz.apply(intervalDays: interval, seed: 12_345, maximumInterval: 3650)
            for _ in 0..<20 {
                XCTAssertEqual(
                    Fuzz.apply(intervalDays: interval, seed: 12_345, maximumInterval: 3650),
                    first,
                    "fuzz must be stable for interval \(interval)"
                )
            }
        }
    }

    func testShortIntervalsAreNotFuzzed() {
        // Spreading a 1-day interval can only produce 0 or 2 days, both worse than leaving it.
        for interval in [1.0, 1.5, 2.0, 2.4] {
            XCTAssertEqual(
                Fuzz.apply(intervalDays: interval, seed: 999, maximumInterval: 3650),
                max(1, interval.rounded())
            )
        }
    }

    func testFuzzedIntervalStaysInsideItsBounds() {
        for interval in stride(from: 3.0, through: 500.0, by: 7.0) {
            let bounds = Fuzz.bounds(intervalDays: interval, maximumInterval: 3650)
            for seed in UInt64(0)..<64 {
                let fuzzed = Fuzz.apply(intervalDays: interval, seed: seed, maximumInterval: 3650)
                XCTAssertGreaterThanOrEqual(fuzzed, bounds.min, "interval \(interval) seed \(seed)")
                XCTAssertLessThanOrEqual(fuzzed, bounds.max, "interval \(interval) seed \(seed)")
            }
        }
    }

    /// The spread widens with interval length — that is what stops a 400-day card being moved
    /// by only a day while a 5-day card is moved by one too.
    func testDeltaGrowsWithInterval() {
        var previous = 0.0
        for interval in [3.0, 7.0, 20.0, 60.0, 365.0] {
            let delta = Fuzz.delta(intervalDays: interval)
            XCTAssertGreaterThan(delta, previous, "delta must grow at interval \(interval)")
            previous = delta
        }
    }

    /// Different cards must land on different offsets, or fuzz achieves nothing.
    func testDifferentSeedsSpreadAcrossTheRange() {
        let interval = 30.0
        let results = Set((UInt64(0)..<200).map {
            Fuzz.apply(intervalDays: interval, seed: $0 &* 0x9E37_79B9, maximumInterval: 3650)
        })
        XCTAssertGreaterThan(results.count, 2, "fuzz should spread cards over several days")
    }

    func testFuzzRespectsMaximumInterval() {
        let fuzzed = Fuzz.apply(intervalDays: 10_000, seed: 42, maximumInterval: 365)
        XCTAssertLessThanOrEqual(fuzzed, 365)
    }

    func testNonFiniteIntervalDoesNotEscape() {
        XCTAssertEqual(Fuzz.apply(intervalDays: .nan, seed: 1, maximumInterval: 365), 1)
        XCTAssertEqual(Fuzz.apply(intervalDays: .infinity, seed: 1, maximumInterval: 365), 1)
    }

    /// `hashValue` is seeded per process, so a card would fuzz differently on every launch.
    /// This checks the FNV seed on `Card` is the stable kind.
    func testCardFuzzSeedDependsOnlyOnCardID() {
        let card = Card(
            cardID: "en:abandon:1#recognition",
            direction: .recognition,
            languageCode: "en",
            state: .newCard(due: Date()),
            scheduler: .fsrs5
        )
        let twin = Card(
            cardID: "en:abandon:1#recognition",
            direction: .recognition,
            languageCode: "en",
            state: .newCard(due: Date().addingTimeInterval(9_999)),
            scheduler: .sm2
        )
        XCTAssertEqual(card.fuzzSeed, twin.fuzzSeed)

        let different = Card(
            cardID: "en:abandon:1#production",
            direction: .production,
            languageCode: "en",
            state: .newCard(due: Date()),
            scheduler: .fsrs5
        )
        XCTAssertNotEqual(card.fuzzSeed, different.fuzzSeed)
    }
}
