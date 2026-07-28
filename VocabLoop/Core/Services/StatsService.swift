import Foundation
import SwiftData

/// A single day in the review-count heatmap.
public struct HeatmapDay: Identifiable, Hashable, Sendable {
    public let dayKey: String
    public let date: Date
    public let reviews: Int
    public let goalMet: Bool

    public var id: String { dayKey }
}

/// One bar in the forecast: how many cards fall due on a given future day.
public struct ForecastDay: Identifiable, Hashable, Sendable {
    public let dayOffset: Int
    public let date: Date
    public let youngCount: Int
    public let matureCount: Int
    public let learningCount: Int

    public var id: Int { dayOffset }
    public var total: Int { youngCount + matureCount + learningCount }
}

/// Everything the Progress screen shows, computed in one pass.
public struct StudyStatistics: Sendable {
    public var dueNow: Int
    public var dueToday: Int
    public var newAvailable: Int

    public var countsByMaturity: [CardMaturity: Int]
    public var totalEnrolled: Int

    public var reviewsToday: Int
    public var correctToday: Int
    public var newIntroducedToday: Int
    public var studySecondsToday: Int
    public var goalMetToday: Bool

    /// Accuracy over graded recalls in the trailing window. `nil` before the first one.
    public var retentionLast30Days: Double?
    public var reviewsLast30Days: Int
    public var averageDailyReviews: Double

    public var currentStreak: Int
    public var longestStreak: Int

    public var heatmap: [HeatmapDay]
    public var forecast: [ForecastDay]

    public static let empty = StudyStatistics(
        dueNow: 0, dueToday: 0, newAvailable: 0,
        countsByMaturity: [:], totalEnrolled: 0,
        reviewsToday: 0, correctToday: 0, newIntroducedToday: 0,
        studySecondsToday: 0, goalMetToday: false,
        retentionLast30Days: nil, reviewsLast30Days: 0, averageDailyReviews: 0,
        currentStreak: 0, longestStreak: 0,
        heatmap: [], forecast: []
    )

    public var accuracyToday: Double? {
        guard reviewsToday > 0 else { return nil }
        return Double(correctToday) / Double(reviewsToday)
    }
}

/// Computes study statistics from ``Card``, ``ReviewLog`` and ``StudyDay``.
///
/// Reads only — this type never writes. Which is why it is safe to call on every Home
/// and Progress appearance without worrying about what it might mutate.
@MainActor
public final class StatsService {
    private let context: ModelContext

    public init(context: ModelContext) {
        self.context = context
    }

    public func statistics(
        for account: UserAccount,
        preferences: StudyPreferences,
        now: Date = Date(),
        heatmapDays: Int = 365,
        forecastDays: Int = 30
    ) throws -> StudyStatistics {
        let calendar = StudyCalendar(preferences: preferences)
        let languageCode = preferences.activeLanguageCode

        let cards = try context.fetch(
            FetchDescriptor<Card>(predicate: #Predicate { $0.languageCode == languageCode })
        )
        let available = cards.filter(\.isAvailable)

        var stats = StudyStatistics.empty
        let endOfToday = calendar.dayEnd(for: now)

        stats.dueNow = available.filter { $0.phase != .new && $0.isDue(at: now) }.count
        stats.dueToday = available.filter { $0.phase != .new && $0.due < endOfToday }.count
        stats.newAvailable = available.filter { $0.phase == .new }.count
        stats.totalEnrolled = cards.count

        var byMaturity: [CardMaturity: Int] = [:]
        for card in cards {
            byMaturity[card.maturity, default: 0] += 1
        }
        stats.countsByMaturity = byMaturity

        // MARK: Today

        let todayKey = calendar.dayKey(for: now)
        let days = try studyDays(userID: account.userID)
        let byDayKey = Dictionary(days.map { ($0.dayKey, $0) }, uniquingKeysWith: { first, _ in first })
        if let today = byDayKey[todayKey] {
            stats.reviewsToday = today.reviewsCompleted
            stats.correctToday = today.correctCount
            stats.newIntroducedToday = today.newCardsIntroduced
            stats.studySecondsToday = today.studySeconds
            stats.goalMetToday = today.goalMet
        }

        // MARK: Retention

        // Only graded recalls count. Including introductions would inflate accuracy,
        // since rating a word you have never seen is not a recall test.
        let windowStart = now.addingTimeInterval(-30 * 86_400)
        let recentLogs = try context.fetch(
            FetchDescriptor<ReviewLog>(
                predicate: #Predicate {
                    $0.languageCode == languageCode
                        && $0.reviewedAt >= windowStart
                        && $0.phaseBeforeRaw != 0
                }
            )
        )
        stats.reviewsLast30Days = recentLogs.count
        if !recentLogs.isEmpty {
            let hits = recentLogs.filter { $0.rating.isSuccess }.count
            stats.retentionLast30Days = Double(hits) / Double(recentLogs.count)
        }
        stats.averageDailyReviews = Double(stats.reviewsLast30Days) / 30

        // MARK: Streak and heatmap

        let streak = StreakService.streak(days: days, calendar: calendar, now: now)
        stats.currentStreak = streak.current
        stats.longestStreak = streak.longest

        stats.heatmap = calendar.recentDayKeys(endingAt: now, count: heatmapDays).map { key in
            let day = byDayKey[key]
            return HeatmapDay(
                dayKey: key,
                date: day?.dayStart ?? Date.distantPast,
                reviews: day?.reviewsCompleted ?? 0,
                goalMet: day?.goalMet ?? false
            )
        }

        stats.forecast = forecast(cards: available, calendar: calendar, now: now, days: forecastDays)
        return stats
    }

    /// How many cards fall due on each of the next `days` study days.
    ///
    /// A projection of *currently scheduled* due dates only — it does not simulate
    /// future ratings. Presenting a simulated forecast as fact would be misleading, and
    /// the honest version is the one that answers "what have I already committed to?"
    func forecast(
        cards: [Card],
        calendar: StudyCalendar,
        now: Date,
        days: Int
    ) -> [ForecastDay] {
        var youngByOffset: [Int: Int] = [:]
        var matureByOffset: [Int: Int] = [:]
        var learningByOffset: [Int: Int] = [:]

        for card in cards where card.phase != .new {
            // Overdue cards land on offset 0 — they are due now, not in the past.
            let offset = max(0, calendar.dayDifference(from: now, to: card.due))
            guard offset < days else { continue }
            switch card.maturity {
            case .mature: matureByOffset[offset, default: 0] += 1
            case .young: youngByOffset[offset, default: 0] += 1
            case .learning, .new: learningByOffset[offset, default: 0] += 1
            }
        }

        let today = calendar.dayStart(for: now)
        return (0..<days).map { offset in
            ForecastDay(
                dayOffset: offset,
                date: today.addingTimeInterval(Double(offset) * 86_400),
                youngCount: youngByOffset[offset] ?? 0,
                matureCount: matureByOffset[offset] ?? 0,
                learningCount: learningByOffset[offset] ?? 0
            )
        }
    }

    private func studyDays(userID: String) throws -> [StudyDay] {
        try context.fetch(
            FetchDescriptor<StudyDay>(
                predicate: #Predicate { $0.userID == userID },
                sortBy: [SortDescriptor(\.dayStart)]
            )
        )
    }

    /// Rating breakdown for the session summary screen.
    public func ratingBreakdown(since: Date, languageCode: String) throws -> [Rating: Int] {
        let logs = try context.fetch(
            FetchDescriptor<ReviewLog>(
                predicate: #Predicate { $0.languageCode == languageCode && $0.reviewedAt >= since }
            )
        )
        var counts: [Rating: Int] = [:]
        for log in logs {
            counts[log.rating, default: 0] += 1
        }
        return counts
    }
}
