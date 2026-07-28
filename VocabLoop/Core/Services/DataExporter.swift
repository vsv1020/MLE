import Foundation
import SwiftData

/// Exports everything the user has created, as JSON.
///
/// Not a nicety. Two reasons it ships in v1: GDPR gives users a right to their data in a
/// portable format, and — more practically — the review log is what a future FSRS weight
/// optimiser trains on, so a user must be able to take it with them rather than being locked
/// into our scheduler by their own history.
///
/// Bundled dictionary content is excluded. It is not the user's data, and including it would
/// bury the part that is.
public struct DataExporter {
    private let context: ModelContext

    public init(context: ModelContext) {
        self.context = context
    }

    struct Export: Encodable {
        var formatVersion: Int
        var exportedAt: Date
        var account: AccountExport
        var preferences: PreferencesSyncPayload?
        var cards: [CardSyncPayload]
        var reviews: [ReviewLogSyncPayload]
        var userEntries: [EntrySyncPayload]
        var studyDays: [StudyDayExport]
    }

    struct AccountExport: Encodable {
        var displayName: String
        var email: String?
        var provider: String
        var createdAt: Date
    }

    struct StudyDayExport: Encodable {
        var dayKey: String
        var reviewsCompleted: Int
        var newCardsIntroduced: Int
        var correctCount: Int
        var studySeconds: Int
        var goalMet: Bool
    }

    /// Write the export to a temporary file and return its URL, ready for `ShareLink`.
    ///
    /// A file rather than a `String` because a year of review history is megabytes, and
    /// handing that to the share sheet in memory is how you get terminated by the watchdog.
    public func exportJSON() throws -> URL {
        let account = try context.activeAccount()
        let userID = account.userID

        let export = Export(
            formatVersion: 1,
            exportedAt: Date(),
            account: AccountExport(
                displayName: account.displayName,
                email: account.email,
                provider: account.providerRaw,
                createdAt: account.createdAt
            ),
            preferences: account.preferences.map(PreferencesSyncPayload.init(preferences:)),
            cards: try context.fetch(FetchDescriptor<Card>()).map(CardSyncPayload.init(card:)),
            reviews: try context.fetch(
                FetchDescriptor<ReviewLog>(sortBy: [SortDescriptor(\.reviewedAt)])
            ).map(ReviewLogSyncPayload.init(log:)),
            userEntries: try context.fetch(
                FetchDescriptor<Entry>(predicate: #Predicate { $0.isUserCreated })
            ).map(EntrySyncPayload.init(entry:)),
            studyDays: try context.fetch(
                FetchDescriptor<StudyDay>(
                    predicate: #Predicate { $0.userID == userID },
                    sortBy: [SortDescriptor(\.dayStart)]
                )
            ).map {
                StudyDayExport(
                    dayKey: $0.dayKey,
                    reviewsCompleted: $0.reviewsCompleted,
                    newCardsIntroduced: $0.newCardsIntroduced,
                    correctCount: $0.correctCount,
                    studySeconds: $0.studySeconds,
                    goalMet: $0.goalMet
                )
            }
        )

        let encoder = JSONEncoder()
        // Pretty-printed and sorted: this file is meant to be read and diffed by a human, or
        // fed to a script someone wrote in an afternoon.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601

        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let url = URL.temporaryDirectory.appending(path: "vocabloop-export-\(stamp).json")
        try encoder.encode(export).write(to: url, options: .atomic)
        return url
    }
}
