import Foundation

/// What a widget shows at one moment, derived from the snapshot file and nothing else.
///
/// The widget never recomputes the study calendar: the day rollover comes from the file's
/// `dayEndsAt`, written by the app with the user's own rollover hour and time zone.
public struct WidgetDisplayState: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// No file yet, or no App Group: "Open VocabLoop to get started".
        case empty
        /// The file is more than ``WidgetTimelinePlanner/staleAfter`` old: no numbers, sleepy Mochi.
        case stale
        /// Numbers worth showing.
        case current
    }

    public var date: Date
    public var kind: Kind
    /// The snapshot as it should read at ``date``: after a rollover `reviewsToday` is `0`,
    /// `studiedToday` is `false` and `dueNow` is the file's `dueTomorrow`. `nil` only for ``Kind/empty``.
    public var snapshot: WidgetSnapshot?

    public var isStale: Bool { kind == .stale }
    public var isEmpty: Bool { kind == .empty }

    public init(date: Date, kind: Kind, snapshot: WidgetSnapshot?) {
        self.date = date
        self.kind = kind
        self.snapshot = snapshot
    }

    /// `true` when the goal is set and met.
    public var isGoalMet: Bool {
        guard let snapshot, snapshot.dailyGoal > 0 else { return false }
        return snapshot.reviewsToday >= snapshot.dailyGoal
    }

    /// Fraction of the goal, `0…1`; `nil` with no goal or no numbers.
    public var goalProgress: Double? {
        guard kind == .current, let snapshot, snapshot.dailyGoal > 0 else { return nil }
        return min(1, Double(max(0, snapshot.reviewsToday)) / Double(snapshot.dailyGoal))
    }

    /// "All caught up": nothing due and today already has a review.
    public var isCaughtUp: Bool {
        guard kind == .current, let snapshot else { return false }
        return snapshot.dueNow == 0 && snapshot.studiedToday
    }
}

/// The entries a widget timeline holds and when WidgetKit should ask again.
public struct WidgetTimelinePlan: Equatable, Sendable {
    public var entries: [WidgetDisplayState]
    public var reloadAfter: Date
}

/// Turns one snapshot into a timeline.
///
/// The file only changes when the app writes it — and the app then calls
/// `WidgetCenter.reloadAllTimelines()` — so the only time-driven changes are the study-day
/// rollover and the stale cut-off. Everything else would be a refresh that reads the same file.
public enum WidgetTimelinePlanner {
    /// After this long without a write the numbers are probably wrong.
    public static let staleAfter: TimeInterval = 48 * 60 * 60
    /// With nothing scheduled, read the file again after this long anyway.
    public static let safetyReload: TimeInterval = 6 * 60 * 60

    /// The display state at `date`.
    public static func state(of snapshot: WidgetSnapshot?, at date: Date) -> WidgetDisplayState {
        guard var snapshot else {
            return WidgetDisplayState(date: date, kind: .empty, snapshot: nil)
        }
        if date >= snapshot.updatedAt.addingTimeInterval(staleAfter) {
            return WidgetDisplayState(date: date, kind: .stale, snapshot: snapshot)
        }
        if let dayEndsAt = snapshot.dayEndsAt, date >= dayEndsAt {
            // A new study day the app has not seen yet. The streak is left as it was, with a grey
            // flame, rather than guessed at.
            snapshot.reviewsToday = 0
            snapshot.studiedToday = false
            snapshot.dueNow = snapshot.dueTomorrow ?? snapshot.dueNow
        }
        return WidgetDisplayState(date: date, kind: .current, snapshot: snapshot)
    }

    /// Entries at `now`, at the rollover and at the stale cut-off — future ones only, sorted —
    /// and a reload at the last of them, or after ``safetyReload`` when there is only `now`.
    public static func plan(snapshot: WidgetSnapshot?, now: Date) -> WidgetTimelinePlan {
        var dates = [now]
        if let snapshot {
            if let dayEndsAt = snapshot.dayEndsAt, dayEndsAt > now {
                dates.append(dayEndsAt)
            }
            let staleAt = snapshot.updatedAt.addingTimeInterval(staleAfter)
            if staleAt > now {
                dates.append(staleAt)
            }
        }
        dates = Array(Set(dates)).sorted()
        let entries = dates.map { state(of: snapshot, at: $0) }
        let reloadAfter = dates.count >= 2 ? dates[dates.count - 1] : now.addingTimeInterval(safetyReload)
        return WidgetTimelinePlan(entries: entries, reloadAfter: reloadAfter)
    }
}
