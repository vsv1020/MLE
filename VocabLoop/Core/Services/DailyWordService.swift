import Foundation
import SwiftData

/// Chooses each day's new words.
///
/// The selection is **deterministic** in `(userID, dayKey, languageCode)`: the same
/// user on the same day always gets the same words, with no server call, offline, and
/// identically after a reinstall. That property is what makes "daily word" trustworthy
/// — a word that changes when you reopen the app reads as a bug — and it is why the
/// shuffle is seeded rather than random.
///
/// Words already enrolled or previously dismissed are excluded, so the surface never
/// re-offers something the user has already answered.
@MainActor
public final class DailyWordService {
    private let context: ModelContext
    private let entitlements: Entitlements

    /// - Parameter entitlements: Defaults to `nil` → the shared instance, rather than to
    ///   `.shared` directly: a default argument is evaluated nonisolated, and `Entitlements` is
    ///   `@MainActor`.
    public init(context: ModelContext, entitlements: Entitlements? = nil) {
        self.context = context
        self.entitlements = entitlements ?? .shared
    }

    /// Today's batch, generating and persisting it if it does not exist yet.
    ///
    /// Persisted rather than recomputed on every read because the *acceptance* record
    /// is not derivable, and because the words a user saw this morning must still be
    /// there this evening.
    @discardableResult
    public func batch(
        for account: UserAccount,
        preferences: StudyPreferences,
        now: Date = Date()
    ) throws -> DailyBatch {
        let calendar = StudyCalendar(preferences: preferences)
        let dayKey = calendar.dayKey(for: now)
        let language = preferences.activeLanguage
        let key = DailyBatch.makeKey(
            userID: account.userID, dayKey: dayKey, languageCode: language.rawValue
        )

        var descriptor = FetchDescriptor<DailyBatch>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1
        if let existing = try context.fetch(descriptor).first {
            return existing
        }

        let stableIDs = try selectEntryStableIDs(
            for: account, preferences: preferences, dayKey: dayKey
        )
        let batch = DailyBatch(
            userID: account.userID,
            dayKey: dayKey,
            languageCode: language.rawValue,
            entryStableIDs: stableIDs,
            now: now
        )
        context.insert(batch)
        try context.save()
        return batch
    }

    /// Resolve a batch's IDs to entries, in presentation order.
    public func entries(in batch: DailyBatch) throws -> [Entry] {
        try context.entries(stableIDs: batch.entryStableIDs)
    }

    // MARK: - Selection

    /// Pick this day's candidate words.
    ///
    /// Selection is a *weighted* deterministic draw, not a plain shuffle: candidates
    /// are ordered by frequency rank, then permuted with a seeded generator. The
    /// weighting matters — a uniform shuffle over a 10,000-word dictionary would serve
    /// mostly rare words, and a learner meeting "ubiquitous" before "because" will
    /// conclude the app is broken.
    func selectEntryStableIDs(
        for account: UserAccount,
        preferences: StudyPreferences,
        dayKey: String
    ) throws -> [String] {
        let languageCode = preferences.activeLanguage.rawValue
        let ranked = try rankedEligibleEntries(for: account, preferences: preferences)
        guard !ranked.isEmpty else { return [] }

        // Draw from a window at the front of the ranked list rather than the whole
        // dictionary, so the words offered stay level-appropriate while still varying
        // day to day.
        let target = max(0, preferences.newWordsPerDay)
        let window = Array(ranked.prefix(max(target * 12, 60)))

        var generator = SeededGenerator(
            seed: Self.seed(userID: account.userID, dayKey: dayKey, languageCode: languageCode)
        )
        return window.shuffled(using: &generator).prefix(target).map(\.stableID)
    }

    /// The next words to start, most useful first, for a session that has run out of cards.
    ///
    /// Not the daily batch. The batch is an *offer* — a handful of words shown for the user to
    /// accept or decline. This is what the endless card queue draws from once everything due
    /// and everything already enrolled is done: the same eligibility rules (language, level
    /// range, not declined, deck active), in plain frequency order, with no daily shuffle,
    /// because a session that keeps going should keep going through the most common words.
    public func nextEntriesToIntroduce(
        for account: UserAccount,
        preferences: StudyPreferences,
        limit: Int
    ) throws -> [Entry] {
        guard limit > 0 else { return [] }
        return Array(try rankedEligibleEntries(for: account, preferences: preferences).prefix(limit))
    }

    /// Unenrolled, undeclined, level-appropriate entries in active decks, by frequency rank.
    private func rankedEligibleEntries(
        for account: UserAccount,
        preferences: StudyPreferences
    ) throws -> [Entry] {
        let languageCode = preferences.activeLanguage.rawValue
        let floor = preferences.cefrFloor
        let ceiling = preferences.cefrCeiling

        let candidates = try context.fetch(
            FetchDescriptor<Entry>(predicate: #Predicate { $0.languageCode == languageCode })
        )

        // Excluded: already enrolled, dismissed on any earlier day, or offered by a
        // deck the user has parked.
        let dismissed = try previouslyDismissed(userID: account.userID, languageCode: languageCode)
        var activeDeckSlugs = try activeDeckSlugs(languageCode: languageCode)
        // Plus packs still show in Decks and Browse — seeing what is in them is how anyone
        // decides to buy — but only offer new words once unlocked.
        if !entitlements.isPlus {
            activeDeckSlugs.subtract(PlusCatalog.premiumDeckSlugs)
        }

        let eligible = candidates.filter { entry in
            guard !entry.isEnrolled else { return false }
            guard !dismissed.contains(entry.stableID) else { return false }
            if let level = entry.cefr, level < floor || level > ceiling { return false }
            // An entry in no deck at all (a user's own word) is always eligible.
            guard !entry.decks.isEmpty else { return true }
            return entry.decks.contains { activeDeckSlugs.contains($0.slug) }
        }

        // Rank first so any draw is over useful words.
        return eligible.sorted { lhs, rhs in
            let a = lhs.frequencyRank ?? Int.max
            let b = rhs.frequencyRank ?? Int.max
            return a == b ? lhs.stableID < rhs.stableID : a < b
        }
    }

    private func previouslyDismissed(userID: String, languageCode: String) throws -> Set<String> {
        let batches = try context.fetch(
            FetchDescriptor<DailyBatch>(
                predicate: #Predicate { $0.userID == userID && $0.languageCode == languageCode }
            )
        )
        return Set(batches.flatMap(\.dismissedEntryStableIDs))
    }

    private func activeDeckSlugs(languageCode: String) throws -> Set<String> {
        let decks = try context.fetch(
            FetchDescriptor<Deck>(predicate: #Predicate { $0.languageCode == languageCode })
        )
        return Set(decks.filter(\.isActiveForNewWords).map(\.slug))
    }

    /// Stable 64-bit seed from the three inputs that define a batch.
    ///
    /// FNV-1a rather than `Hasher`, because Swift's hashing is seeded per process — the
    /// same inputs would produce a different batch on every launch, which is precisely
    /// the bug this whole design exists to prevent.
    static func seed(userID: String, dayKey: String, languageCode: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in "\(userID)|\(dayKey)|\(languageCode)".utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }

    // MARK: - Actions

    /// Enrol a daily word and record the acceptance.
    ///
    /// - Returns: The cards actually created. This is **not** always
    ///   `preferences.enabledDirections.count` — a cloze card is skipped for an entry with no
    ///   maskable example, and re-accepting a word creates nothing. Callers that display a
    ///   card count must use this rather than assuming.
    @discardableResult
    public func accept(
        entry: Entry,
        in batch: DailyBatch,
        preferences: StudyPreferences,
        reviewService: ReviewService,
        now: Date = Date()
    ) throws -> [Card] {
        let created = try reviewService.enroll(entry: entry, preferences: preferences, now: now)
        batch.markAccepted(entry.stableID, now: now)
        try context.save()
        return created
    }

    /// Decline a daily word. It will not be offered again.
    public func dismiss(entry: Entry, in batch: DailyBatch, now: Date = Date()) throws {
        batch.markDismissed(entry.stableID, now: now)
        try context.save()
    }
}
