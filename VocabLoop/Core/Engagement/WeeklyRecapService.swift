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
/// Foundation (W0) scope: counts from ``StudyDay`` only — reviews, accuracy, minutes, days studied,
/// words started — plus streak, level and look. Words mastered, the word lists, best combo and
/// candy are filled in by the full implementation (engagement plan §1.9).
@MainActor
public final class WeeklyRecapService {
    private let context: ModelContext
    private let engagement: EngagementService

    public init(context: ModelContext, engagement: EngagementService) {
        self.context = context
        self.engagement = engagement
    }

    public func recap(for account: UserAccount, preferences: StudyPreferences, endingAt now: Date) throws -> WeeklyRecap {
        let calendar = StudyCalendar(preferences: preferences)
        let days = try studyDays(userID: account.userID)
        let byKey = Dictionary(days.map { ($0.dayKey, $0) }, uniquingKeysWith: { first, _ in first })

        let dayKeys = calendar.recentDayKeys(endingAt: now, count: 7)
        let window = Self.totals(dayKeys: dayKeys, byKey: byKey)

        // The seven study days before the window: the older half of a fourteen-day run.
        let previousKeys = Array(calendar.recentDayKeys(endingAt: now, count: 14).prefix(7))
        let before = Self.totals(dayKeys: previousKeys, byKey: byKey)
        let previous = WeeklyRecapDelta(
            reviews: window.reviews - before.reviews,
            minutes: window.minutes - before.minutes,
            wordsMastered: 0
        )

        let profile = try engagement.profile()
        let streak = try engagement.streak(preferences: preferences, now: now)

        return WeeklyRecap(
            weekStartKey: dayKeys.first ?? calendar.dayKey(for: now),
            dayKeys: dayKeys,
            studiedDays: dayKeys.map { (byKey[$0]?.reviewsCompleted ?? 0) > 0 },
            reviews: window.reviews,
            accuracy: window.reviews > 0 ? Double(window.correct) / Double(window.reviews) : nil,
            minutes: window.minutes,
            wordsMastered: 0,
            wordsStarted: window.started,
            bestCombo: 0,
            candyEarned: 0,
            level: profile.level,
            look: engagement.currentLook(),
            streak: streak.current,
            previous: previous,
            headline: Self.headline(wordsMastered: 0)
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

    /// "This week you mastered 42 words", with the singular and a kind zero.
    static func headline(wordsMastered: Int) -> String {
        switch wordsMastered {
        case ..<1: return "This week you kept your words growing"
        case 1: return "This week you mastered 1 word"
        default: return "This week you mastered \(wordsMastered) words"
        }
    }

    // MARK: - Private

    private struct Totals {
        var reviews = 0
        var correct = 0
        var minutes = 0
        var started = 0
    }

    private static func totals(dayKeys: [String], byKey: [String: StudyDay]) -> Totals {
        var totals = Totals()
        var seconds = 0
        for key in dayKeys {
            guard let day = byKey[key] else { continue }
            totals.reviews += day.reviewsCompleted
            totals.correct += day.correctCount
            totals.started += day.newCardsIntroduced
            seconds += day.studySeconds
        }
        totals.minutes = seconds / 60
        return totals
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
