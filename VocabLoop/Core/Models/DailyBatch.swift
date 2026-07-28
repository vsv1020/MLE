import Foundation
import SwiftData

/// The set of new words offered on one day, for one user, in one language.
///
/// Persisted rather than recomputed on every launch so that the words a user saw this
/// morning are still there this evening — a "daily word" that changes when you reopen
/// the app is a bug, not a feature. The generator is deterministic anyway (see
/// ``DailyWordService``), so this row is a cache; but it also records *which* words
/// were accepted, which is not derivable.
@Model
public final class DailyBatch {
    /// `"<userID>|<yyyy-MM-dd>|<languageCode>"`. Unique, so two concurrent generators
    /// upsert rather than producing two batches for the same day.
    @Attribute(.unique) public var key: String

    public var userID: String
    /// `yyyy-MM-dd` in the user's timezone, respecting their configured day start.
    public var dayKey: String
    public var languageCode: String

    /// Offered words, in presentation order.
    public var entryStableIDs: [String]
    /// Words the user chose to enrol. A subset of ``entryStableIDs``.
    public var acceptedEntryStableIDs: [String]
    /// Words the user explicitly dismissed — excluded from future batches so "not this
    /// one" is respected rather than re-offered tomorrow.
    public var dismissedEntryStableIDs: [String]

    public var createdAt: Date
    public var updatedAt: Date

    public init(
        userID: String,
        dayKey: String,
        languageCode: String,
        entryStableIDs: [String],
        now: Date = Date()
    ) {
        self.key = DailyBatch.makeKey(userID: userID, dayKey: dayKey, languageCode: languageCode)
        self.userID = userID
        self.dayKey = dayKey
        self.languageCode = languageCode
        self.entryStableIDs = entryStableIDs
        self.acceptedEntryStableIDs = []
        self.dismissedEntryStableIDs = []
        self.createdAt = now
        self.updatedAt = now
    }

    public static func makeKey(userID: String, dayKey: String, languageCode: String) -> String {
        "\(userID)|\(dayKey)|\(languageCode)"
    }

    public var isFullyHandled: Bool {
        let handled = Set(acceptedEntryStableIDs).union(dismissedEntryStableIDs)
        return Set(entryStableIDs).isSubset(of: handled)
    }

    public func markAccepted(_ stableID: String, now: Date = Date()) {
        guard !acceptedEntryStableIDs.contains(stableID) else { return }
        acceptedEntryStableIDs.append(stableID)
        dismissedEntryStableIDs.removeAll { $0 == stableID }
        updatedAt = now
    }

    public func markDismissed(_ stableID: String, now: Date = Date()) {
        guard !dismissedEntryStableIDs.contains(stableID) else { return }
        dismissedEntryStableIDs.append(stableID)
        acceptedEntryStableIDs.removeAll { $0 == stableID }
        updatedAt = now
    }
}

/// Per-day activity rollup: the streak, the heatmap, and the daily goal ring.
///
/// A separate table rather than an aggregation over ``ReviewLog`` because the streak
/// and heatmap are read on every launch and would otherwise scan the entire review
/// history — which grows without bound by design.
@Model
public final class StudyDay {
    /// `"<userID>|<yyyy-MM-dd>"`.
    @Attribute(.unique) public var key: String

    public var userID: String
    public var dayKey: String
    /// Start of the study day as an absolute instant, for range queries and sorting.
    public var dayStart: Date

    public var reviewsCompleted: Int
    public var newCardsIntroduced: Int
    public var correctCount: Int
    public var studySeconds: Int
    /// Latched `true` the moment the goal is reached, and never recomputed — lowering
    /// the daily goal must not retroactively award past days, and raising it must not
    /// take them away.
    public var goalMet: Bool

    public init(userID: String, dayKey: String, dayStart: Date) {
        self.key = StudyDay.makeKey(userID: userID, dayKey: dayKey)
        self.userID = userID
        self.dayKey = dayKey
        self.dayStart = dayStart
        self.reviewsCompleted = 0
        self.newCardsIntroduced = 0
        self.correctCount = 0
        self.studySeconds = 0
        self.goalMet = false
    }

    public static func makeKey(userID: String, dayKey: String) -> String {
        "\(userID)|\(dayKey)"
    }

    public var accuracy: Double? {
        guard reviewsCompleted > 0 else { return nil }
        return Double(correctCount) / Double(reviewsCompleted)
    }
}
