import Foundation

// The study-session Live Activity, minus ActivityKit: what it shows, when it starts, how long it
// lingers. Pure, so `StudyActivityPolicyTests` can cover every rule without a device, and shared,
// so the extension's views and the app's `StudyActivityController` read the same numbers.
// See `docs/WIDGET-PLAN.md` §1.2.

/// Where the session is, as far as the Lock Screen is concerned.
public enum StudyActivityPhase: String, Codable, Hashable, Sendable, CaseIterable {
    /// Cards on screen.
    case studying
    /// The daily goal was just met; the goal screen is up.
    case goalReached
    /// The library ran out — the session summary is up.
    case finished
    /// "Done for today" on the goal screen.
    case resting
}

/// Why an activity is being ended, which decides how long it stays on the Lock Screen.
public enum StudyActivityEnding: Hashable, Sendable, CaseIterable {
    /// The queue ran out (`phase == .finished`).
    case finished
    /// "Done for today".
    case resting
    /// The study screen was closed mid-session.
    case left
    /// The Settings toggle was switched off: gone at once.
    case disabled
    /// Left behind by a previous process, or stale when the app came back: gone at once.
    case abandoned

    /// The phase the final content shows.
    public var finalPhase: StudyActivityPhase {
        switch self {
        case .finished: return .finished
        case .resting: return .resting
        case .left, .disabled, .abandoned: return .studying
        }
    }
}

/// The activity's changing content. `StudyActivityAttributes.ContentState` is this type.
public struct StudyActivityState: Codable, Hashable, Sendable {
    public var reviewsToday: Int
    public var combo: Int
    public var streak: Int
    public var studiedToday: Bool
    public var phase: StudyActivityPhase
    public var updatedAt: Date

    public init(
        reviewsToday: Int,
        combo: Int,
        streak: Int,
        studiedToday: Bool,
        phase: StudyActivityPhase,
        updatedAt: Date
    ) {
        self.reviewsToday = reviewsToday
        self.combo = combo
        self.streak = streak
        self.studiedToday = studiedToday
        self.phase = phase
        self.updatedAt = updatedAt
    }
}

public enum StudyActivityPolicy {
    /// Every update moves the stale date this far ahead. An app killed mid-session leaves an
    /// activity behind; after half an hour it shows "Tap to pick up where you left off" instead
    /// of numbers that have stopped moving.
    public static let staleInterval: TimeInterval = 30 * 60

    /// The combo chip appears from this run length — the first combo milestone.
    public static let comboChipThreshold = 3

    /// Whether a session that just landed on a card should start (or update) an activity.
    ///
    /// - Parameters:
    ///   - settingEnabled: The "Show progress on Lock Screen" toggle.
    ///   - systemEnabled: `ActivityAuthorizationInfo().areActivitiesEnabled`.
    ///   - isReviewing: The session is showing a card (not loading, not a summary).
    ///   - queueIsEmpty: Nothing left to study.
    public static func shouldStart(
        settingEnabled: Bool, systemEnabled: Bool, isReviewing: Bool, queueIsEmpty: Bool
    ) -> Bool {
        settingEnabled && systemEnabled && isReviewing && !queueIsEmpty
    }

    /// The content for the session's current numbers. Negative inputs (an undo past zero, which
    /// the model already clamps) are clamped again here so the Lock Screen never shows "-1".
    public static func state(
        reviewsToday: Int,
        combo: Int,
        streak: Int,
        studiedToday: Bool,
        phase: StudyActivityPhase,
        now: Date
    ) -> StudyActivityState {
        StudyActivityState(
            reviewsToday: max(0, reviewsToday),
            combo: max(0, combo),
            streak: max(0, streak),
            studiedToday: studiedToday || reviewsToday > 0,
            phase: phase,
            updatedAt: now
        )
    }

    /// When the content stops being trustworthy.
    public static func staleDate(now: Date) -> Date {
        now.addingTimeInterval(staleInterval)
    }

    /// How long an ended activity stays on the Lock Screen; `nil` means remove it immediately.
    public static func dismissalDate(for ending: StudyActivityEnding, now: Date) -> Date? {
        switch ending {
        case .finished: return now.addingTimeInterval(10 * 60)
        case .resting: return now.addingTimeInterval(15 * 60)
        case .left: return now.addingTimeInterval(5 * 60)
        case .disabled, .abandoned: return nil
        }
    }

    /// `true` when an activity found on returning to the app should be ended at once rather than
    /// updated: its content went stale while the app was away. The next grade requests a new one.
    public static func shouldEndOnReturn(staleDate: Date?, now: Date) -> Bool {
        guard let staleDate else { return false }
        return now >= staleDate
    }

    /// Fraction of the goal, `0…1`, or `nil` when there is no goal.
    public static func goalProgress(reviewsToday: Int, dailyGoal: Int) -> Double? {
        guard dailyGoal > 0 else { return nil }
        return min(1, Double(max(0, reviewsToday)) / Double(dailyGoal))
    }

    /// `true` when the combo chip is shown.
    public static func showsCombo(_ combo: Int) -> Bool {
        combo >= comboChipThreshold
    }
}

/// Every word the Live Activity says. Kids audience: nothing here counts what did not happen.
public enum StudyActivityCopy {
    /// The bottom line of the Lock Screen view and the expanded Dynamic Island.
    public static func line(for state: StudyActivityState, isStale: Bool = false) -> String {
        if isStale { return "轻点一下，从上次停下的地方继续" }
        switch state.phase {
        case .studying: return "继续背 —— 麻薯在为你加油"
        case .goalReached: return "今日目标完成 ⭐"
        case .finished: return "暂时都学完啦"
        case .resting: return "明天见"
        }
    }

    /// "12 of 30 today", or "12 reviews today" when there is no goal.
    public static func progress(reviewsToday: Int, dailyGoal: Int) -> String {
        let count = max(0, reviewsToday)
        if dailyGoal > 0 { return "今天已学 \(count)/\(dailyGoal)" }
        return count == 1 ? "今天复习了 1 张" : "今天复习了 \(count) 张"
    }

    /// The compact trailing Dynamic Island label: "12/30", or "12 ✓" when there is no goal.
    public static func compact(reviewsToday: Int, dailyGoal: Int) -> String {
        let count = max(0, reviewsToday)
        if dailyGoal > 0 { return "\(count)/\(dailyGoal)" }
        return "\(count) ✓"
    }

    /// "×5".
    public static func combo(_ combo: Int) -> String {
        "×\(combo)"
    }

    /// "7-day streak".
    public static func streak(_ streak: Int) -> String {
        "连续打卡 \(streak) 天"
    }

    /// One sentence for VoiceOver on the Lock Screen view.
    public static func accessibilitySummary(
        for state: StudyActivityState, dailyGoal: Int, isStale: Bool = false
    ) -> String {
        var parts = [progress(reviewsToday: state.reviewsToday, dailyGoal: dailyGoal)]
        if StudyActivityPolicy.showsCombo(state.combo) { parts.append("连对 \(state.combo) 张") }
        if state.streak > 0 { parts.append(streak(state.streak)) }
        parts.append(line(for: state, isStale: isStale))
        return parts.joined(separator: "，")
    }
}
