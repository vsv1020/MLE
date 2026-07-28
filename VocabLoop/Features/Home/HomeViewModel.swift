import Foundation
import SwiftData
import Observation

/// State for the Today screen.
///
/// Loads on appearance rather than observing continuously. Statistics involve a handful of
/// aggregate scans, and recomputing them on every keystroke elsewhere in the app would be
/// wasteful — `@Query` would do exactly that.
@MainActor
@Observable
final class HomeViewModel {
    var statistics: StudyStatistics = .empty
    var dailyEntries: [Entry] = []
    var acceptedStableIDs: Set<String> = []
    var dismissedStableIDs: Set<String> = []
    var isLoading = true
    var errorMessage: String?

    private var batch: DailyBatch?

    func load(dependencies: AppDependencies, now: Date = Date()) {
        guard let account = dependencies.account, let preferences = account.preferences else {
            isLoading = false
            return
        }

        do {
            statistics = try dependencies.stats.statistics(
                for: account, preferences: preferences, now: now
            )
            let batch = try dependencies.dailyWords.batch(
                for: account, preferences: preferences, now: now
            )
            self.batch = batch
            dailyEntries = try dependencies.dailyWords.entries(in: batch)
            acceptedStableIDs = Set(batch.acceptedEntryStableIDs)
            dismissedStableIDs = Set(batch.dismissedEntryStableIDs)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    /// Enrol a daily word. Optimistic: the check mark appears immediately and the write
    /// follows, because the alternative is a visible lag on the app's most-tapped control.
    func accept(_ entry: Entry, dependencies: AppDependencies) {
        guard let batch, let preferences = dependencies.preferences else { return }
        acceptedStableIDs.insert(entry.stableID)
        do {
            try dependencies.dailyWords.accept(
                entry: entry, in: batch, preferences: preferences,
                reviewService: dependencies.review
            )
            statistics.newAvailable += preferences.enabledDirections.count
            Haptics.tap()
        } catch {
            acceptedStableIDs.remove(entry.stableID)
            errorMessage = error.localizedDescription
        }
    }

    func dismiss(_ entry: Entry, dependencies: AppDependencies) {
        guard let batch else { return }
        dismissedStableIDs.insert(entry.stableID)
        do {
            try dependencies.dailyWords.dismiss(entry: entry, in: batch)
        } catch {
            dismissedStableIDs.remove(entry.stableID)
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Derived display values

    var reviewsDue: Int { statistics.dueNow }
    var newAvailable: Int { statistics.newAvailable }

    /// Fill for the daily-goal ring.
    var goalProgress: Double {
        // The ring is capped at 1 but the count keeps rising — going round twice would read
        // as a rendering bug.
        guard let goal = goalTarget, goal > 0 else { return 0 }
        return min(Double(statistics.reviewsToday) / Double(goal), 1)
    }

    var goalTarget: Int?

    /// The primary call to action, phrased for the actual situation.
    var primaryActionTitle: String {
        if reviewsDue > 0 {
            return "Review \(reviewsDue) card\(reviewsDue == 1 ? "" : "s")"
        }
        if newAvailable > 0 {
            return "Learn \(newAvailable) new card\(newAvailable == 1 ? "" : "s")"
        }
        return "Study ahead"
    }

    var hasWorkToDo: Bool { reviewsDue > 0 || newAvailable > 0 }

    /// Shown when nothing is due, so "all caught up" is informative rather than a dead end.
    func nextDueDescription(dependencies: AppDependencies, now: Date = Date()) -> String? {
        guard reviewsDue == 0 else { return nil }
        guard let languageCode = dependencies.preferences?.activeLanguageCode else { return nil }
        var descriptor = FetchDescriptor<Card>(
            predicate: #Predicate { $0.languageCode == languageCode && !$0.isSuspended && $0.phaseRaw != 0 },
            sortBy: [SortDescriptor(\.due)]
        )
        descriptor.fetchLimit = 1
        guard let next = try? dependencies.context.fetch(descriptor).first else { return nil }
        return IntervalFormatter.dueDescription(due: next.due, now: now)
    }

    var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return "Good morning"
        case 12..<18: return "Good afternoon"
        case 18..<23: return "Good evening"
        default: return "Still up?"
        }
    }

    var todayDescription: String {
        Date().formatted(.dateTime.weekday(.wide).day().month(.wide))
    }
}
