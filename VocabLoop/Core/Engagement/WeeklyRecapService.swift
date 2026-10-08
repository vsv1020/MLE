import Foundation
import SwiftData

/// A word named in the recap.
public struct RecapWord: Identifiable, Sendable {
    public let entryStableID: String
    public let headword: String
    /// In the learner's own language, when the entry has one.
    public let translation: String?

    public init(entryStableID: String, headword: String, translation: String?) {
        self.entryStableID = entryStableID
        self.headword = headword
        self.translation = translation
    }

    public var id: String { entryStableID }
}

/// One week of study, ready to show and to share.
///
/// A week is the seven *study days* ending today, in the user's ``StudyCalendar`` — not a
/// calendar week — so the recap is never half empty on a Monday.
public struct WeeklyRecap: Sendable {
    /// Day key of the window's first day.
    public var weekStartKey: String
    /// The seven day keys, oldest first.
    public var dayKeys: [String]
    /// One per ``dayKeys``.
    public var studiedDays: [Bool]
    public var reviews: Int
    public var accuracy: Double?
    public var minutes: Int
    public var wordsMastered: Int
    public var wordsStarted: Int
    public var bestCombo: Int
    public var candyEarned: Int
    public var level: Int
    public var look: MochiLook
    public var streak: Int
    /// Highest stability gained this week.
    public var nailedWords: [RecapWord]
    /// Forgotten twice or more this week. Shown as "worth another look", never "failed".
    public var trickyWords: [RecapWord]
    public var startedWords: [RecapWord]
    /// Change against the seven days before the window.
    public var previous: WeeklyRecapDelta?
    /// "This week you mastered 42 words".
    public var headline: String

    public init(
        weekStartKey: String,
        dayKeys: [String],
        studiedDays: [Bool],
        reviews: Int,
        accuracy: Double?,
        minutes: Int,
        wordsMastered: Int,
        wordsStarted: Int,
        bestCombo: Int,
        candyEarned: Int,
        level: Int,
        look: MochiLook,
        streak: Int,
        nailedWords: [RecapWord] = [],
        trickyWords: [RecapWord] = [],
        startedWords: [RecapWord] = [],
        previous: WeeklyRecapDelta? = nil,
        headline: String
    ) {
        self.weekStartKey = weekStartKey
        self.dayKeys = dayKeys
        self.studiedDays = studiedDays
        self.reviews = reviews
        self.accuracy = accuracy
        self.minutes = minutes
        self.wordsMastered = wordsMastered
        self.wordsStarted = wordsStarted
        self.bestCombo = bestCombo
        self.candyEarned = candyEarned
        self.level = level
        self.look = look
        self.streak = streak
        self.nailedWords = nailedWords
        self.trickyWords = trickyWords
        self.startedWords = startedWords
        self.previous = previous
        self.headline = headline
    }
}

/// This week minus the week before. Positive means more this week.
public struct WeeklyRecapDelta: Sendable {
    public var reviews: Int
    public var minutes: Int
    public var wordsMastered: Int

    public init(reviews: Int, minutes: Int, wordsMastered: Int) {
        self.reviews = reviews
        self.minutes = minutes
        self.wordsMastered = wordsMastered
    }
}

/// Builds the weekly recap from ``StudyDay`` and ``ReviewLog``.
///
/// Counts from ``StudyDay``; words from ``ReviewLog`` rows in the window (engagement plan §1.9);
/// best combo and candy from the ``EngagementProfile`` week when it matches, else candy is
/// reconstructed as a floor.
@MainActor
public final class WeeklyRecapService {
    private let context: ModelContext
    private let engagement: EngagementService

    public init(context: ModelContext, engagement: EngagementService) {
        self.context = context
        self.engagement = engagement
    }

    /// The seven study days ending with the one containing `now`.
    ///
    /// Counts (reviews, accuracy, minutes, days studied) come from ``StudyDay``, the same rollup
    /// Progress shows, so the two never disagree. Words — mastered, started, nailed, tricky —
    /// come from the ``ReviewLog`` rows inside the window, fetched by date range only. Whole
    /// study days: the window runs from the first day's rollover to the last day's, so a recap
    /// for a past `now` includes the rest of that day exactly as its ``StudyDay`` does.
    public func recap(for account: UserAccount, preferences: StudyPreferences, endingAt now: Date) throws -> WeeklyRecap {
        let calendar = StudyCalendar(preferences: preferences)
        let days = try studyDays(userID: account.userID)
        let byKey = Dictionary(days.map { ($0.dayKey, $0) }, uniquingKeysWith: { first, _ in first })

        let dayKeys = calendar.recentDayKeys(endingAt: now, count: 7)
        let window = Self.totals(dayKeys: dayKeys, byKey: byKey)

        // The seven study days before the window: the older half of a fourteen-day run.
        let previousKeys = Array(calendar.recentDayKeys(endingAt: now, count: 14).prefix(7))
        let before = Self.totals(dayKeys: previousKeys, byKey: byKey)

        let bounds = Self.windowBounds(endingAt: now, calendar: calendar)
        let previousStart = bounds.previousStart
        let windowEnd = bounds.end
        let logs = try context.fetch(
            FetchDescriptor<ReviewLog>(
                predicate: #Predicate { $0.reviewedAt >= previousStart && $0.reviewedAt < windowEnd },
                sortBy: [SortDescriptor(\.reviewedAt)]
            )
        )
        let thisWeek = logs.filter { $0.reviewedAt >= bounds.start }
        let lastWeek = logs.filter { $0.reviewedAt < bounds.start }

        let mastered = Self.masteredCount(logs: thisWeek)
        let previous = WeeklyRecapDelta(
            reviews: window.reviews - before.reviews,
            minutes: window.minutes - before.minutes,
            wordsMastered: mastered - Self.masteredCount(logs: lastWeek)
        )

        let trickyIDs = Self.trickyWordIDs(logs: thisWeek, limit: 3)
        let nailedIDs = Self.nailedWordIDs(logs: thisWeek, excluding: Set(trickyIDs), limit: 3)
        let startedIDs = Self.startedWordIDs(logs: thisWeek)
        let words = try recapWords(
            stableIDs: Array(Set(trickyIDs + nailedIDs + startedIDs)),
            nativeCodes: preferences.readingLanguageCodes
        )

        let profile = try engagement.profile()
        let streak = try engagement.streak(preferences: preferences, now: now)

        // Best combo and candy are kept on the profile per Monday-start week, and only for the
        // latest week studied. Use them when this window ends inside that week; other windows
        // have no record of their combos, and their candy is reconstructed from what was logged.
        let profileWeekMatches = profile.weekKey == EngagementService.weekKey(for: now, calendar: calendar)
        let bestCombo = profileWeekMatches ? profile.bestComboThisWeek : 0

        let achievementsInWindow = profile.unlockedAchievements.filter {
            $0.unlockedAt >= bounds.start && $0.unlockedAt < bounds.end
        }.count
        let estimatedCandy = Self.estimatedCandy(
            reviews: window.reviews,
            studiedDays: window.studiedDays,
            goalDays: window.goalDays,
            wordsMastered: mastered,
            achievements: achievementsInWindow
        )
        let candyEarned = profileWeekMatches
            ? max(estimatedCandy, profile.candyThisWeek)
            : estimatedCandy

        return WeeklyRecap(
            weekStartKey: dayKeys.first ?? calendar.dayKey(for: now),
            dayKeys: dayKeys,
            studiedDays: dayKeys.map { (byKey[$0]?.reviewsCompleted ?? 0) > 0 },
            reviews: window.reviews,
            accuracy: window.reviews > 0 ? Double(window.correct) / Double(window.reviews) : nil,
            minutes: window.minutes,
            wordsMastered: mastered,
            wordsStarted: startedIDs.count,
            bestCombo: bestCombo,
            candyEarned: candyEarned,
            level: profile.level,
            look: engagement.currentLook(),
            streak: streak.current,
            nailedWords: nailedIDs.compactMap { words[$0] },
            trickyWords: trickyIDs.compactMap { words[$0] },
            startedWords: startedIDs.compactMap { words[$0] },
            previous: previous,
            headline: Self.headline(wordsMastered: mastered)
        )
    }

    /// The last `weeks` recaps, newest first, each ending seven study days before the next.
    public func history(for account: UserAccount, preferences: StudyPreferences, weeks: Int, now: Date) throws -> [WeeklyRecap] {
        guard weeks > 0 else { return [] }
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = preferences.timeZone
        var result: [WeeklyRecap] = []
        for week in 0..<weeks {
            let end = gregorian.date(byAdding: .day, value: -7 * week, to: now) ?? now
            result.append(try recap(for: account, preferences: preferences, endingAt: end))
        }
        return result
    }

    // MARK: - Pure parts

    /// Words whose card crossed into maturity in `logs`: completed an interval under 21 days and
    /// was given one of 21 or more. Counted per word, so a word with two cards counts once.
    static func masteredCount(logs: [ReviewLog]) -> Int {
        var words = Set<String>()
        for log in logs
        where log.scheduledDays < CardMaturity.matureThresholdDays
            && log.intervalDaysAfter >= CardMaturity.matureThresholdDays {
            words.insert(log.entryStableID)
        }
        return words.count
    }

    /// Instants bounding the recap window ending with the study day containing `now`, and the
    /// seven study days before it: `[previousStart, start)` and `[start, end)`.
    ///
    /// Built from day starts with calendar arithmetic, never by subtracting 86,400 seconds, so a
    /// DST change inside the fortnight cannot shift a boundary by an hour.
    static func windowBounds(endingAt now: Date, calendar: StudyCalendar) -> (previousStart: Date, start: Date, end: Date) {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        let today = calendar.dayStart(for: now)
        let end = calendar.dayEnd(for: now)
        let start = gregorian.date(byAdding: .day, value: -6, to: today).map(calendar.dayStart(for:)) ?? today
        let previousStart = gregorian.date(byAdding: .day, value: -13, to: today).map(calendar.dayStart(for:)) ?? start
        return (previousStart, start, end)
    }

    /// Words forgotten (``Rating/again``) at least twice in `logs`, most-forgotten first, then
    /// most recently forgotten. Shown as "worth another look".
    static func trickyWordIDs(logs: [ReviewLog], limit: Int) -> [String] {
        var counts: [String: Int] = [:]
        var latest: [String: Date] = [:]
        for log in logs where log.rating == .again && !log.entryStableID.isEmpty {
            counts[log.entryStableID, default: 0] += 1
            latest[log.entryStableID] = max(latest[log.entryStableID] ?? .distantPast, log.reviewedAt)
        }
        let ranked = counts
            .filter { $0.value >= 2 }
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                let l = latest[lhs.key] ?? .distantPast
                let r = latest[rhs.key] ?? .distantPast
                if l != r { return l > r }
                return lhs.key < rhs.key
            }
        return ranked.prefix(max(0, limit)).map { $0.key }
    }

    /// Words with the highest stability reached this week, from successful recalls only — an
    /// introduction is not a recall, and a forgotten word was not nailed.
    static func nailedWordIDs(logs: [ReviewLog], excluding: Set<String>, limit: Int) -> [String] {
        var best: [String: Double] = [:]
        for log in logs
        where log.rating.isSuccess && log.isGradedRecall
            && !log.entryStableID.isEmpty && !excluding.contains(log.entryStableID) {
            best[log.entryStableID] = max(best[log.entryStableID] ?? 0, log.stabilityAfter)
        }
        let ranked = best.sorted { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value > rhs.value }
            return lhs.key < rhs.key
        }
        return ranked.prefix(max(0, limit)).map { $0.key }
    }

    /// Words introduced in `logs` (their first ever answer), once each, in the order started.
    static func startedWordIDs(logs: [ReviewLog]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for log in logs.sorted(by: { $0.reviewedAt < $1.reviewedAt })
        where log.phaseBefore == .new && !log.entryStableID.isEmpty {
            if seen.insert(log.entryStableID).inserted { ordered.append(log.entryStableID) }
        }
        return ordered
    }

    /// Candy a window must at least have earned, rebuilt from what was logged: one per review,
    /// the first-review bonus per day studied, the goal bonus per goal day, a sticker per word
    /// mastered and the badge bonus per achievement. Combo and album bonuses leave no dated
    /// trace, so this is a floor.
    static func estimatedCandy(reviews: Int, studiedDays: Int, goalDays: Int, wordsMastered: Int, achievements: Int) -> Int {
        reviews * RewardEngine.candyPerReview
            + studiedDays * RewardEngine.firstReviewBonus
            + goalDays * RewardEngine.goalBonus
            + wordsMastered * RewardEngine.stickerBonus
            + achievements * RewardEngine.achievementBonus
    }

    /// "This week you mastered 42 words", with the singular and a kind zero.
    static func headline(wordsMastered: Int) -> String {
        switch wordsMastered {
        case ..<1: return "这周你的单词一直在长大"
        case 1: return "这周你掌握了 1 个单词"
        default: return "这周你掌握了 \(wordsMastered) 个单词"
        }
    }

    // MARK: - Private

    private struct Totals {
        var reviews = 0
        var correct = 0
        var minutes = 0
        var started = 0
        var studiedDays = 0
        var goalDays = 0
    }

    private static func totals(dayKeys: [String], byKey: [String: StudyDay]) -> Totals {
        var totals = Totals()
        var seconds = 0
        for key in dayKeys {
            guard let day = byKey[key] else { continue }
            totals.reviews += day.reviewsCompleted
            totals.correct += day.correctCount
            totals.started += day.newCardsIntroduced
            if day.reviewsCompleted > 0 { totals.studiedDays += 1 }
            if day.goalMet { totals.goalDays += 1 }
            seconds += day.studySeconds
        }
        totals.minutes = seconds / 60
        return totals
    }

    /// Headword and translation for each word, from one entry fetch. Words whose entry no longer
    /// exists (a deleted personal word) are left out rather than shown as IDs.
    private func recapWords(stableIDs: [String], nativeCodes: [String]) throws -> [String: RecapWord] {
        var result: [String: RecapWord] = [:]
        for entry in try context.entries(stableIDs: stableIDs) {
            result[entry.stableID] = RecapWord(
                entryStableID: entry.stableID,
                headword: entry.headword,
                translation: entry.primarySense?.translation(preferring: nativeCodes)
            )
        }
        return result
    }

    private func studyDays(userID: String) throws -> [StudyDay] {
        try context.fetch(
            FetchDescriptor<StudyDay>(
                predicate: #Predicate { $0.userID == userID },
                sortBy: [SortDescriptor(\.dayStart)]
            )
        )
    }
}
