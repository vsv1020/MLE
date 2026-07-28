import Foundation

/// Deterministic interval spreading.
///
/// Without fuzz, every card introduced on the same day stays clumped together for
/// the rest of its life, and review load arrives in spikes big enough that users
/// abandon the app. Fuzz nudges each interval by a few percent to break the clumps.
///
/// It is *deterministic*, seeded from the card's identity and the interval being
/// fuzzed. That matters more than it sounds: a card's due date must not shift just
/// because a schedule was recomputed, previewed twice, or replayed from the review
/// log during a sync merge. Random fuzz would make all of those non-idempotent.
public enum Fuzz {
    /// Below this, fuzz is skipped — spreading a 1-day interval can only turn it
    /// into 0 or 2 days, both of which are worse than leaving it alone.
    static let minimumFuzzedInterval: Double = 2.5

    private struct Range {
        let start: Double
        let end: Double
        let factor: Double
    }

    /// Progressively wider spread for longer intervals: ±15% in the first week,
    /// ±10% out to three weeks, ±5% beyond. Matches Anki's ranges so that a user's
    /// review load feels the same as the app they are likely migrating from.
    private static let ranges: [Range] = [
        Range(start: 2.5, end: 7.0, factor: 0.15),
        Range(start: 7.0, end: 20.0, factor: 0.10),
        Range(start: 20.0, end: .infinity, factor: 0.05),
    ]

    /// Half-width of the fuzz window, in days.
    static func delta(intervalDays: Double) -> Double {
        var delta = 1.0
        for range in ranges {
            delta += range.factor * max(min(intervalDays, range.end) - range.start, 0)
        }
        return delta
    }

    /// Inclusive `[min, max]` day bounds the interval may be moved to.
    static func bounds(intervalDays: Double, maximumInterval: Double) -> (min: Double, max: Double) {
        let d = delta(intervalDays: intervalDays)
        var lower = (intervalDays - d).rounded()
        var upper = (intervalDays + d).rounded()
        lower = max(2, lower)
        upper = max(lower, min(upper, maximumInterval))
        return (lower, upper)
    }

    /// Fuzz `intervalDays`, returning a whole number of days.
    ///
    /// - Parameter seed: stable per-card value (see `Card.fuzzSeed`). The base
    ///   interval is mixed in as well, so a card draws a different offset at each
    ///   step of its life while any single step stays reproducible.
    public static func apply(intervalDays: Double, seed: UInt64, maximumInterval: Double) -> Double {
        guard intervalDays.isFinite else { return 1 }
        let capped = min(intervalDays, maximumInterval)
        guard capped >= minimumFuzzedInterval else { return max(1, capped.rounded()) }

        let (lower, upper) = bounds(intervalDays: capped, maximumInterval: maximumInterval)
        guard upper > lower else { return lower }

        let span = UInt64(upper - lower) + 1
        let mixed = mix(seed, UInt64(capped.rounded()))
        return lower + Double(mixed % span)
    }

    /// SplitMix64 finaliser. Chosen because it is a handful of lines, has no state
    /// to persist, and gives a well-distributed result from two small integers —
    /// `hashValue` would not, since Swift's hashing is seeded per-process and would
    /// therefore break determinism across launches.
    static func mix(_ a: UInt64, _ b: UInt64) -> UInt64 {
        var z = a ^ (b &* 0x9E37_79B9_7F4A_7C15)
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
