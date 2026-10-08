import Foundation
import SwiftData
import OSLog

/// Turns the review log into a training set, and reports whether fitting is worth doing.
///
/// **What this does not do yet:** fit the weights. That needs an optimiser — `fsrs-rs` has
/// full training support and can be bridged over FFI — and adding the project's first
/// non-Apple dependency deserves its own decision about binary size and build complexity.
///
/// What it does do is everything either side of that call: build the training set in the exact
/// format the published optimisers read, gate the feature on having enough history, expose the
/// export so a user can fit their own weights today, and provide the write path that applies a
/// result. When the optimiser lands it slots into ``applyFittedWeights(_:reviewCount:)`` and
/// nothing else changes.
///
/// This is the reason `ReviewLog` is append-only and never pruned.
@MainActor
public final class OptimizerService {
    private let context: ModelContext
    private let logger = Logger(subsystem: "com.vocabloop.app", category: "optimizer")

    /// Persisted alongside the weights so the "re-fit when reviews double" rule survives
    /// relaunches. Device-local, not user data — it describes a computation, not a fact about
    /// the learner.
    private static let lastFitReviewCountKey = "optimizer.reviewCountAtLastFit"

    public init(context: ModelContext) {
        self.context = context
    }

    // MARK: - Readiness

    public func readiness(preferences: StudyPreferences) throws -> OptimizerReadiness {
        let languageCode = preferences.activeLanguageCode
        // Introductions are excluded: grading a word you have never seen is not a recall
        // observation, and feeding it to the optimiser would bias the first interval.
        let logs = try context.fetch(
            FetchDescriptor<ReviewLog>(
                predicate: #Predicate { $0.languageCode == languageCode && $0.phaseBeforeRaw != 0 }
            )
        )
        let lastFit = UserDefaults.standard.object(forKey: Self.lastFitReviewCountKey) as? Int

        return OptimizerReadiness(
            reviewCount: logs.count,
            cardCount: Set(logs.map(\.cardID)).count,
            hasFittedWeights: preferences.fsrsWeights != nil,
            reviewCountAtLastFit: lastFit
        )
    }

    // MARK: - Training set

    /// Build the training set for the active language.
    ///
    /// Rows are grouped by card and ordered in time, and `deltaT` is measured against the
    /// previous review *of that card* — which is why this cannot just be a `map` over the log.
    /// The first review of each card gets `-1`, the convention the optimisers use for "no
    /// previous review".
    public func trainingSet(preferences: StudyPreferences) throws -> FSRSTrainingSet {
        let languageCode = preferences.activeLanguageCode
        let logs = try context.fetch(
            FetchDescriptor<ReviewLog>(
                predicate: #Predicate { $0.languageCode == languageCode },
                sortBy: [SortDescriptor(\.reviewedAt)]
            )
        )

        var previousReviewByCard: [String: Date] = [:]
        var rows: [FSRSTrainingRow] = []
        rows.reserveCapacity(logs.count)

        for log in logs {
            let deltaT: Double
            if let previous = previousReviewByCard[log.cardID] {
                // Recomputed from timestamps rather than trusting the stored `elapsedDays`,
                // so a row whose elapsed value was written by an older build cannot poison
                // the fit.
                deltaT = max(0, log.reviewedAt.timeIntervalSince(previous) / 86_400)
            } else {
                deltaT = -1
            }
            previousReviewByCard[log.cardID] = log.reviewedAt

            rows.append(FSRSTrainingRow(
                cardID: log.cardID,
                reviewTime: Int(log.reviewedAt.timeIntervalSince1970),
                rating: log.ratingRaw,
                state: log.phaseBeforeRaw,
                deltaT: deltaT
            ))
        }

        return FSRSTrainingSet(
            rows: rows,
            cardCount: previousReviewByCard.count,
            currentParametersVersion: preferences.schedulerConfig.fsrsParameters.version
        )
    }

    /// Write the training set to a file for `ShareLink`.
    ///
    /// Shipped now rather than waiting for the built-in optimiser: a user with enough history
    /// can fit their own weights with the published tooling today, and paste the result into
    /// Settings. That also makes the format testable against real consumers before we depend
    /// on it ourselves.
    public func exportTrainingSet(preferences: StudyPreferences) throws -> URL {
        let set = try trainingSet(preferences: preferences)
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        // Through DataExporter's helper, so this file gets the same treatment: previous exports
        // removed, encrypted at rest while the device is locked, excluded from backup. A review
        // log is a detailed record of when the user was awake and studying.
        return try DataExporter.writeTemporaryFile(
            Data(set.csv().utf8),
            named: "vocabloop-revlog-\(preferences.activeLanguageCode)-\(stamp).csv"
        )
    }

    // MARK: - Applying a result

    public enum ApplyError: LocalizedError {
        case wrongWeightCount(expected: Int, got: Int)
        case notFinite

        public var errorDescription: String? {
            switch self {
            case .wrongWeightCount(let expected, let got):
                "FSRS-5 需要正好 \(expected) 个权重，这组有 \(got) 个。"
            case .notFinite:
                "这组权重里有一个不是有限数值。"
            }
        }
    }

    /// Apply a fitted weight vector.
    ///
    /// Validated before it is stored, because a bad vector here would silently corrupt every
    /// future interval and there is no user-visible symptom until cards start coming back at
    /// absurd times. `FSRSParameters.validated` is a second net at read time.
    ///
    /// Existing cards keep their stability and difficulty — those were measured, not assumed —
    /// and simply get scheduled by the new weights from their next review onward.
    public func applyFittedWeights(
        _ weights: [Double],
        preferences: StudyPreferences,
        reviewCount: Int
    ) throws {
        guard weights.count == FSRSParameters.fsrs5WeightCount else {
            throw ApplyError.wrongWeightCount(
                expected: FSRSParameters.fsrs5WeightCount, got: weights.count
            )
        }
        guard weights.allSatisfy({ $0.isFinite }) else { throw ApplyError.notFinite }

        let candidate = FSRSParameters(weights: weights, version: "fitted-\(Int(Date().timeIntervalSince1970))")
        guard candidate.isValid else { throw ApplyError.notFinite }

        preferences.fsrsWeights = weights
        preferences.fsrsParametersVersion = candidate.version
        preferences.touch()
        try context.save()
        UserDefaults.standard.set(reviewCount, forKey: Self.lastFitReviewCountKey)
        logger.info("Applied fitted weights \(candidate.version, privacy: .public) from \(reviewCount) reviews")
    }

    /// Return to the published defaults.
    public func resetToDefaultWeights(preferences: StudyPreferences) throws {
        preferences.fsrsWeights = nil
        preferences.fsrsParametersVersion = FSRSParameters.fsrs5Default.version
        preferences.touch()
        try context.save()
        UserDefaults.standard.removeObject(forKey: Self.lastFitReviewCountKey)
    }

    /// Parse a weight vector pasted from the published optimiser, which prints a bracketed,
    /// comma-separated list.
    public static func parseWeights(_ text: String) -> [Double]? {
        let cleaned = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let parts = cleaned
            .split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let values = parts.compactMap(Double.init)
        guard values.count == parts.count, !values.isEmpty else { return nil }
        return values
    }
}
