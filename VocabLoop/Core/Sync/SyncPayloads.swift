import Foundation

/// Wire representations of the records the app pushes.
///
/// Separate `Codable` structs rather than making the `@Model` classes `Codable`, for
/// three reasons: a SwiftData model's relationships would recurse, the wire format must
/// be able to change independently of the local schema, and an outbox payload has to be
/// a *snapshot* — by the time it is drained, the live object may have moved on.

public struct CardSyncPayload: Codable, Sendable {
    public var cardID: String
    public var entryStableID: String
    public var languageCode: String
    public var direction: String
    public var phase: Int
    public var stability: Double
    public var difficulty: Double
    public var easeFactor: Double
    public var intervalDays: Double
    public var due: Date
    public var lastReviewedAt: Date?
    public var reps: Int
    public var lapses: Int
    public var stepIndex: Int
    public var scheduler: String
    public var isSuspended: Bool
    public var isFlagged: Bool
    public var updatedAt: Date

    public init(card: Card) {
        self.cardID = card.cardID
        self.entryStableID = card.entry?.stableID ?? ""
        self.languageCode = card.languageCode
        self.direction = card.directionRaw
        self.phase = card.phaseRaw
        self.stability = card.stability
        self.difficulty = card.difficulty
        self.easeFactor = card.easeFactor
        self.intervalDays = card.intervalDays
        self.due = card.due
        self.lastReviewedAt = card.lastReviewedAt
        self.reps = card.reps
        self.lapses = card.lapses
        self.stepIndex = card.stepIndex
        self.scheduler = card.schedulerRaw
        self.isSuspended = card.isSuspended
        self.isFlagged = card.isFlagged
        self.updatedAt = card.updatedAt
    }
}

/// A review, as sent to the server.
///
/// Carries every field an FSRS weight optimiser needs. Review history is an append-only
/// event log, so two devices merge it by union with no conflict resolution — which is why
/// scheduling conflicts are resolved by *replaying* the merged log rather than by picking
/// a winning `S`/`D` pair.
public struct ReviewLogSyncPayload: Codable, Sendable {
    public var cardID: String
    public var entryStableID: String
    public var languageCode: String
    public var direction: String
    public var reviewedAt: Date
    public var rating: Int
    public var phaseBefore: Int
    public var phaseAfter: Int
    public var elapsedDays: Double
    public var scheduledDays: Double
    public var intervalDaysAfter: Double
    public var stabilityBefore: Double
    public var stabilityAfter: Double
    public var difficultyBefore: Double
    public var difficultyAfter: Double
    public var retrievabilityBefore: Double
    public var durationMS: Int
    public var scheduler: String
    public var parametersVersion: String

    public init(log: ReviewLog) {
        self.cardID = log.cardID
        self.entryStableID = log.entryStableID
        self.languageCode = log.languageCode
        self.direction = log.directionRaw
        self.reviewedAt = log.reviewedAt
        self.rating = log.ratingRaw
        self.phaseBefore = log.phaseBeforeRaw
        self.phaseAfter = log.phaseAfterRaw
        self.elapsedDays = log.elapsedDays
        self.scheduledDays = log.scheduledDays
        self.intervalDaysAfter = log.intervalDaysAfter
        self.stabilityBefore = log.stabilityBefore
        self.stabilityAfter = log.stabilityAfter
        self.difficultyBefore = log.difficultyBefore
        self.difficultyAfter = log.difficultyAfter
        self.retrievabilityBefore = log.retrievabilityBefore
        self.durationMS = log.durationMS
        self.scheduler = log.schedulerRaw
        self.parametersVersion = log.parametersVersion
    }
}

public struct PreferencesSyncPayload: Codable, Sendable {
    public var activeLanguageCode: String
    public var installedLanguageCodes: [String]
    public var nativeLanguageCodes: [String]
    public var dailyGoal: Int
    public var newWordsPerDay: Int
    public var maxReviewsPerSession: Int
    public var scheduler: String
    public var desiredRetention: Double
    public var maximumIntervalDays: Double
    public var learningStepsMinutes: [Double]
    public var relearningStepsMinutes: [Double]
    public var fuzzEnabled: Bool
    public var fsrsWeights: [Double]?
    public var cefrFloor: String
    public var cefrCeiling: String
    public var enabledDirections: [String]
    public var remindersEnabled: Bool
    public var reminderHour: Int
    public var reminderMinute: Int
    public var timeZoneIdentifier: String
    public var dayStartHour: Int
    public var updatedAt: Date

    public init(preferences: StudyPreferences) {
        self.activeLanguageCode = preferences.activeLanguageCode
        self.installedLanguageCodes = preferences.installedLanguageCodes
        self.nativeLanguageCodes = preferences.nativeLanguageCodes
        self.dailyGoal = preferences.dailyGoal
        self.newWordsPerDay = preferences.newWordsPerDay
        self.maxReviewsPerSession = preferences.maxReviewsPerSession
        self.scheduler = preferences.schedulerRaw
        self.desiredRetention = preferences.desiredRetention
        self.maximumIntervalDays = preferences.maximumIntervalDays
        self.learningStepsMinutes = preferences.learningStepsMinutes
        self.relearningStepsMinutes = preferences.relearningStepsMinutes
        self.fuzzEnabled = preferences.fuzzEnabled
        self.fsrsWeights = preferences.fsrsWeights
        self.cefrFloor = preferences.cefrFloorRaw
        self.cefrCeiling = preferences.cefrCeilingRaw
        self.enabledDirections = preferences.enabledDirectionsRaw
        self.remindersEnabled = preferences.remindersEnabled
        self.reminderHour = preferences.reminderHour
        self.reminderMinute = preferences.reminderMinute
        self.timeZoneIdentifier = preferences.timeZoneIdentifier
        self.dayStartHour = preferences.dayStartHour
        self.updatedAt = preferences.updatedAt
    }
}

/// A user-authored word. Bundled dictionary entries are not synced — both devices
/// already have them in the app bundle, and shipping them over the wire would be pure
/// waste.
public struct EntrySyncPayload: Codable, Sendable {
    public struct SensePayload: Codable, Sendable {
        public var order: Int
        public var partOfSpeech: String
        public var definition: String
        public var translations: [String: String]
        public var examples: [String]
        public var synonyms: [String]
        public var antonyms: [String]
        public var usageNote: String?
    }

    public var stableID: String
    public var languageCode: String
    public var headword: String
    public var phonetic: String?
    public var cefr: String?
    public var tags: [String]
    public var grammarNotes: [String: String]
    public var senses: [SensePayload]
    public var updatedAt: Date

    public init(entry: Entry) {
        self.stableID = entry.stableID
        self.languageCode = entry.languageCode
        self.headword = entry.headword
        self.phonetic = entry.phonetic
        self.cefr = entry.cefrRaw
        self.tags = entry.tags
        self.grammarNotes = entry.grammarNotes
        self.senses = entry.orderedSenses.map { sense in
            SensePayload(
                order: sense.order,
                partOfSpeech: sense.partOfSpeechRaw,
                definition: sense.definition,
                translations: sense.translations,
                examples: sense.examples.map(\.text),
                synonyms: sense.synonyms,
                antonyms: sense.antonyms,
                usageNote: sense.usageNote
            )
        }
        self.updatedAt = entry.updatedAt
    }
}

/// One batch push. Batched rather than one request per row: a month of offline study is
/// thousands of reviews, and that many round trips would take minutes and drain a battery.
public struct SyncPushRequest: Codable, Sendable {
    public var reviews: [ReviewLogSyncPayload]
    public var cards: [CardSyncPayload]
    public var entries: [EntrySyncPayload]
    public var preferences: PreferencesSyncPayload?
    public var deletedEntryIDs: [String]

    public init(
        reviews: [ReviewLogSyncPayload] = [],
        cards: [CardSyncPayload] = [],
        entries: [EntrySyncPayload] = [],
        preferences: PreferencesSyncPayload? = nil,
        deletedEntryIDs: [String] = []
    ) {
        self.reviews = reviews
        self.cards = cards
        self.entries = entries
        self.preferences = preferences
        self.deletedEntryIDs = deletedEntryIDs
    }

    public var isEmpty: Bool {
        reviews.isEmpty && cards.isEmpty && entries.isEmpty
            && preferences == nil && deletedEntryIDs.isEmpty
    }
}

public struct SyncPushResponse: Codable, Sendable {
    /// Server clock at the time of the push, used as the cursor for the next pull.
    public var serverTime: Date
    /// Rows the server rejected, so they can be dropped instead of retried forever.
    public var rejectedCardIDs: [String]?
}
