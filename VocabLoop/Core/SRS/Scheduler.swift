import Foundation

/// Which algorithm produced a scheduling decision.
///
/// Persisted on every `Card` and every `ReviewLog` row so a user who switches
/// algorithms keeps an interpretable history, and so a future weight optimiser can
/// filter its training set to a single algorithm.
public enum SchedulerKind: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case fsrs5
    case sm2

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .fsrs5: "FSRS 5"
        case .sm2: "SM-2"
        }
    }

    public var summary: String {
        switch self {
        case .fsrs5:
            "根据记忆稳定性、难度和你此刻遗忘了多少来安排复习，"
            + "可以自己设定目标记忆率。推荐使用。"
        case .sm2:
            "经典的 SuperMemo 2 算法。更简单，用过 Anki 的话会很熟悉，"
            + "但不能设定目标记忆率。"
        }
    }
}

/// Tunable knobs shared by every scheduler.
///
/// Held as a value type so a preview ("what would each button do?") can be computed
/// without touching persisted user preferences.
public struct SchedulerConfig: Codable, Hashable, Sendable {
    /// Target recall probability. Only FSRS can honour this directly.
    public var desiredRetention: Double
    /// Hard ceiling on any interval, in days.
    public var maximumInterval: Double
    /// Intraday steps, in minutes, for a card being introduced.
    public var learningStepsMinutes: [Double]
    /// Intraday steps, in minutes, for a card that lapsed out of `review`.
    public var relearningStepsMinutes: [Double]
    /// Spread same-day-introduced cards so review load does not arrive in spikes.
    public var fuzzEnabled: Bool
    /// FSRS weight vector and decay.
    public var fsrsParameters: FSRSParameters

    public static let retentionRange: ClosedRange<Double> = 0.70...0.97

    public init(
        desiredRetention: Double = 0.90,
        maximumInterval: Double = 365 * 5,
        learningStepsMinutes: [Double] = [1, 10],
        relearningStepsMinutes: [Double] = [10],
        fuzzEnabled: Bool = true,
        fsrsParameters: FSRSParameters = .fsrs5Default
    ) {
        self.desiredRetention = desiredRetention
        self.maximumInterval = maximumInterval
        self.learningStepsMinutes = learningStepsMinutes
        self.relearningStepsMinutes = relearningStepsMinutes
        self.fuzzEnabled = fuzzEnabled
        self.fsrsParameters = fsrsParameters
    }

    public static let `default` = SchedulerConfig()

    /// Retention outside the supported range makes the interval inversion produce
    /// absurd values (and `1.0` makes it diverge), so it is clamped at the boundary
    /// rather than trusted from persisted preferences.
    public var sanitised: SchedulerConfig {
        var copy = self
        copy.desiredRetention = min(max(desiredRetention, Self.retentionRange.lowerBound),
                                    Self.retentionRange.upperBound)
        copy.maximumInterval = max(1, maximumInterval)
        copy.learningStepsMinutes = learningStepsMinutes.filter { $0 > 0 }.isEmpty
            ? [1, 10] : learningStepsMinutes.filter { $0 > 0 }
        copy.relearningStepsMinutes = relearningStepsMinutes.filter { $0 > 0 }.isEmpty
            ? [10] : relearningStepsMinutes.filter { $0 > 0 }
        return copy
    }
}

/// A memory model that turns a rating into a new scheduling state.
///
/// Implementations must be pure: same inputs, same output. `now` and the fuzz seed
/// are passed in rather than read from the environment precisely so tests can pin
/// them down.
public protocol Scheduler: Sendable {
    var kind: SchedulerKind { get }
    var config: SchedulerConfig { get }

    /// Grade a card.
    /// - Parameter fuzzSeed: Stable per-card value. Passing the same seed for the
    ///   same card guarantees its due date does not drift when a schedule is
    ///   recomputed or replayed from the review log.
    func apply(rating: Rating, to state: SchedulingState, at now: Date, fuzzSeed: UInt64) -> SchedulingOutcome

    /// Recall probability right now, `0…1`. `1` for a card that has never been
    /// answered or is being introduced.
    func retrievability(of state: SchedulingState, at now: Date) -> Double
}

extension Scheduler {
    /// What every button would do, for the rating bar's interval labels.
    ///
    /// Showing the consequence of each choice is what makes the scheduler feel
    /// trustworthy instead of arbitrary, so this is not a debug affordance.
    public func preview(state: SchedulingState, at now: Date, fuzzSeed: UInt64) -> [Rating: SchedulingOutcome] {
        var result: [Rating: SchedulingOutcome] = [:]
        for rating in Rating.allCases {
            result[rating] = apply(rating: rating, to: state, at: now, fuzzSeed: fuzzSeed)
        }
        return result
    }
}

public enum SchedulerFactory {
    public static func make(_ kind: SchedulerKind, config: SchedulerConfig) -> any Scheduler {
        switch kind {
        case .fsrs5: FSRSScheduler(config: config)
        case .sm2: SM2Scheduler(config: config)
        }
    }
}
