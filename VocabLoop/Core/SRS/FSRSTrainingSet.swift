import Foundation

/// One review, in the shape an FSRS weight optimiser consumes.
///
/// Deliberately *not* ``ReviewLog``: an optimiser needs the review history grouped per card
/// and ordered in time, with a `deltaT` measured from the previous review of that same card —
/// which is a different shape from an append-only event table. Keeping the two apart means
/// the storage schema and the training format can change independently.
///
/// Field names match the CSV columns `fsrs-optimizer` and `fsrs-rs` expect, so a set exported
/// here can be fed to either without a translation step.
public struct FSRSTrainingRow: Codable, Hashable, Sendable {
    /// Groups rows into one card's history.
    public var cardID: String
    /// Seconds since the epoch, so a consumer needs no date parsing.
    public var reviewTime: Int
    /// `1…4`.
    public var rating: Int
    /// Lifecycle phase the card was in when shown. `0` marks the introduction.
    public var state: Int
    /// Days since the previous review of *this* card. `-1` for the first, matching the
    /// convention the optimisers use for "no previous review".
    public var deltaT: Double

    public init(cardID: String, reviewTime: Int, rating: Int, state: Int, deltaT: Double) {
        self.cardID = cardID
        self.reviewTime = reviewTime
        self.rating = rating
        self.state = state
        self.deltaT = deltaT
    }
}

/// A complete, ordered training set plus the facts needed to decide whether fitting is
/// worthwhile.
public struct FSRSTrainingSet: Sendable {
    public var rows: [FSRSTrainingRow]
    /// Distinct cards represented. An optimiser needs breadth as well as volume — 2,000
    /// reviews of 20 cards says much less than 2,000 reviews of 500.
    public var cardCount: Int
    /// Weight vector these reviews were scheduled under, so a consumer can warm-start.
    public var currentParametersVersion: String

    public var reviewCount: Int { rows.count }

    /// CSV in the column order `fsrs-optimizer` expects.
    ///
    /// CSV rather than JSON because that is what the existing tooling reads; a user who wants
    /// to fit their own weights today can export this and run the published optimiser without
    /// waiting for us to ship one.
    public func csv() -> String {
        var out = "card_id,review_time,review_rating,review_state,delta_t\n"
        for row in rows {
            out += "\(row.cardID),\(row.reviewTime),\(row.rating),\(row.state),\(row.deltaT)\n"
        }
        return out
    }
}

/// Why the optimiser is or is not available yet.
///
/// Fitting 19 weights to 30 reviews produces confident nonsense, so the gate is part of the
/// feature rather than an afterthought. Thresholds follow the published FSRS guidance: usable
/// from a few hundred reviews, meaningfully better than the defaults from around a thousand.
public struct OptimizerReadiness: Hashable, Sendable {
    /// Below this, fitting is refused outright.
    public static let minimumReviews = 400
    /// Below this, fitted weights are unlikely to beat the defaults.
    public static let recommendedReviews = 1_000
    /// Breadth floor. Volume concentrated on a handful of cards does not generalise.
    public static let minimumCards = 50

    public var reviewCount: Int
    public var cardCount: Int
    /// Weights already fitted for this user, if any.
    public var hasFittedWeights: Bool
    /// Reviews at the last fit, so the "re-fit when it doubles" rule can be applied.
    public var reviewCountAtLastFit: Int?

    public var meetsMinimum: Bool {
        reviewCount >= Self.minimumReviews && cardCount >= Self.minimumCards
    }

    public var meetsRecommended: Bool {
        reviewCount >= Self.recommendedReviews && cardCount >= Self.minimumCards
    }

    /// Reviews still needed to reach the recommended volume. `0` once there.
    public var reviewsUntilRecommended: Int {
        max(0, Self.recommendedReviews - reviewCount)
    }

    /// FSRS guidance is to re-fit whenever the review count doubles — often early, rarely later.
    public var shouldRefit: Bool {
        guard let reviewCountAtLastFit, reviewCountAtLastFit > 0 else { return meetsMinimum }
        return reviewCount >= reviewCountAtLastFit * 2
    }

    /// What to tell the user. Concrete numbers rather than "not enough data", because the
    /// only useful version of this message says how much further there is to go.
    public var explanation: String {
        if !meetsMinimum {
            if cardCount < Self.minimumCards {
                return "Tuning needs a wider sample — at least \(Self.minimumCards) different "
                    + "cards, and you have \(cardCount)."
            }
            let remaining = Self.minimumReviews - reviewCount
            return "Not enough history yet. About \(remaining) more "
                + "\(remaining == 1 ? "review" : "reviews") and this becomes available."
        }
        if !meetsRecommended {
            return "Available, but \(reviewsUntilRecommended) more reviews would make the "
                + "result noticeably more reliable."
        }
        if hasFittedWeights, !shouldRefit {
            return "Tuned to your history. Worth repeating once your review count has doubled."
        }
        return "Ready. \(reviewCount) reviews across \(cardCount) cards is enough to fit the "
            + "model to how you actually forget."
    }
}
