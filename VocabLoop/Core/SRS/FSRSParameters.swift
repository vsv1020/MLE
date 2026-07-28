import Foundation

/// The FSRS weight vector, plus the forgetting-curve decay.
///
/// Weights are data, not constants, for two reasons: FSRS is designed to be *fitted*
/// to an individual learner's review history, and moving to a later FSRS revision is
/// mostly a change of weight vector. Keeping `decay` here rather than as a `let`
/// constant is what makes FSRS-6 (which learns decay as `w[20]`) a parameter change
/// instead of a rewrite.
public struct FSRSParameters: Codable, Hashable, Sendable {
    /// FSRS-5 expects exactly 19 weights.
    public static let fsrs5WeightCount = 19

    public var weights: [Double]

    /// Exponent of the power-law forgetting curve. Negative.
    ///
    /// FSRS-4.5 and FSRS-5 both use `-0.5`.
    public var decay: Double

    /// A version tag stored on every `ReviewLog` row so a future optimiser can tell
    /// which weights produced which scheduling decision. Bump it whenever
    /// ``weights`` or ``decay`` change meaning.
    public var version: String

    public init(weights: [Double], decay: Double = -0.5, version: String) {
        self.weights = weights
        self.decay = decay
        self.version = version
    }

    /// Published FSRS-5 default weights — the starting point for a learner with no
    /// review history yet.
    public static let fsrs5Default = FSRSParameters(
        weights: [
            0.40255,  // w0  initial stability, Again
            1.18385,  // w1  initial stability, Hard
            3.17300,  // w2  initial stability, Good
            15.69105, // w3  initial stability, Easy
            7.19490,  // w4  initial difficulty base
            0.53450,  // w5  initial difficulty rating exponent
            1.46040,  // w6  difficulty delta per rating step
            0.00460,  // w7  difficulty mean-reversion weight
            1.54575,  // w8  stability growth scale
            0.11920,  // w9  stability saturation exponent
            1.01925,  // w10 retrievability sensitivity on success
            1.93950,  // w11 post-lapse stability scale
            0.11000,  // w12 post-lapse difficulty exponent
            0.29605,  // w13 post-lapse stability exponent
            2.26980,  // w14 post-lapse retrievability sensitivity
            0.23150,  // w15 Hard penalty
            2.98980,  // w16 Easy bonus
            0.51655,  // w17 same-day stability scale
            0.66210,  // w18 same-day rating offset
        ],
        decay: -0.5,
        version: "fsrs5-default-1"
    )

    /// `FACTOR` in the FSRS papers: `0.9^(1/decay) - 1`.
    ///
    /// Chosen so that `retrievability(t: S, S: S) == 0.9` — i.e. stability is by
    /// definition the interval at which recall probability is 90%.
    public var factor: Double { pow(0.9, 1 / decay) - 1 }

    /// Bounds-checked accessor. Out-of-range indices return `0`, which makes a
    /// truncated persisted weight vector degrade rather than crash on launch.
    public func w(_ index: Int) -> Double {
        guard weights.indices.contains(index) else { return 0 }
        return weights[index]
    }

    public var isValid: Bool {
        weights.count >= Self.fsrs5WeightCount
            && decay < 0
            && weights.allSatisfy { $0.isFinite }
    }

    /// Falls back to the published defaults if a persisted vector is unusable, so a
    /// corrupt preference can never brick scheduling.
    public var validated: FSRSParameters { isValid ? self : .fsrs5Default }
}
