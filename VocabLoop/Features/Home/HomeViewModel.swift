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
            let created = try dependencies.dailyWords.accept(
                entry: entry, in: batch, preferences: preferences,
                reviewService: dependencies.review
            )
            // The count of cards actually created, not the number of enabled directions: a
            // cloze card is skipped when the entry has no maskable example, so assuming would
            // overstate the new-card count on the tile the user is looking at.
            statistics.newAvailable += created.count
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

    /// Fill for the ring, or `nil` when there is nothing to fill toward.
    ///
    /// Optional now that the daily goal is optional. Returning 0 would draw an empty ring around
    /// the due count and imply the user was failing at a target they never set.
    var goalProgress: Double? {
        // Capped at 1 but the count keeps rising — going round twice would read as a bug.
        guard let goal = goalTarget, goal > 0 else { return nil }
        return min(Double(statistics.reviewsToday) / Double(goal), 1)
    }

    var goalTarget: Int?

    /// What is waiting, phrased for the actual situation.
    ///
    /// A description now, not a call to action. This screen used to be the app's entry point and
    /// its job was to get you into a session; the session is the root now, so Today's job is to
    /// tell you where you stand. The verb moved to the button, which returns you to the card
    /// you were already on.
    ///
    /// "Study ahead" is deliberately *not* one of these any more. It used to be the fallback
    /// whenever nothing was due, which made the most damaging action in the app its own default
    /// — see `HomeView.studyAheadFooter`.
    var statusTitle: String {
        if reviewsDue > 0 {
            return "\(reviewsDue) card\(reviewsDue == 1 ? "" : "s") due"
        }
        if newAvailable > 0 {
            return "\(newAvailable) new word\(newAvailable == 1 ? "" : "s") ready"
        }
        return "Nothing due"
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
