import Foundation
import SwiftUI

/// Every word the Home Screen and Lock Screen widgets say, from a ``WidgetDisplayState``.
///
/// Pure and shared so `WidgetCopyTests` can hold the kids-audience rule — nothing counts what
/// did not happen: no "missed", no "only", no "0 left" — over every state the widget can be in.
public enum WidgetCopy {
    public static let emptyTitle = "Open VocabLoop to get started"
    public static let staleTitle = "Mochi is waiting for you"
    public static let caughtUp = "All caught up"
    public static let openApp = "Open VocabLoop"
    public static let startReview = "Start review"

    /// "12".
    public static func dueCount(_ dueNow: Int) -> String { "\(max(0, dueNow))" }

    /// "12 due".
    public static func due(_ dueNow: Int) -> String { "\(max(0, dueNow)) due" }

    /// "12 words due" / "1 word due".
    public static func dueWords(_ dueNow: Int) -> String {
        let count = max(0, dueNow)
        return count == 1 ? "1 word due" : "\(count) words due"
    }

    /// "8 of 30 today".
    public static func goal(reviewsToday: Int, dailyGoal: Int) -> String {
        "\(max(0, reviewsToday)) of \(dailyGoal) today"
    }

    /// "8/30 today".
    public static func goalShort(reviewsToday: Int, dailyGoal: Int) -> String {
        "\(max(0, reviewsToday))/\(dailyGoal) today"
    }

    /// "7-day streak".
    public static func streak(_ streak: Int) -> String { "\(streak)-day streak" }

    /// "Level 4".
    public static func level(_ level: Int) -> String { "Level \(level)" }

    /// "640 ⭐".
    public static func candy(_ candy: Int) -> String { "\(max(0, candy)) ⭐" }

    /// The accessoryInline line: "12 words due · 7-day streak" / "All caught up" / "Open VocabLoop".
    public static func inline(_ state: WidgetDisplayState) -> String {
        guard state.kind == .current, let snapshot = state.snapshot else { return openApp }
        if snapshot.dueNow == 0 { return caughtUp }
        let words = dueWords(snapshot.dueNow)
        return snapshot.streak > 0 ? "\(words) · \(streak(snapshot.streak))" : words
    }

    /// The accessoryRectangular second line: "12 due · 8/30 today", or "12 due" with no goal.
    public static func rectangularDetail(_ state: WidgetDisplayState) -> String {
        guard let snapshot = state.snapshot else { return emptyTitle }
        if state.kind == .stale { return staleTitle }
        let head = snapshot.dueNow == 0 ? caughtUp : due(snapshot.dueNow)
        guard snapshot.dailyGoal > 0 else { return head }
        return "\(head) · \(goalShort(reviewsToday: snapshot.reviewsToday, dailyGoal: snapshot.dailyGoal))"
    }

    /// One sentence for VoiceOver, for every family.
    public static func accessibilityLabel(_ state: WidgetDisplayState) -> String {
        switch state.kind {
        case .empty: return emptyTitle
        case .stale: return staleTitle
        case .current:
            guard let snapshot = state.snapshot else { return emptyTitle }
            var parts: [String] = [state.isCaughtUp ? caughtUp : dueWords(snapshot.dueNow)]
            if snapshot.dailyGoal > 0 {
                parts.append(goal(reviewsToday: snapshot.reviewsToday, dailyGoal: snapshot.dailyGoal))
            }
            if snapshot.streak > 0 { parts.append(streak(snapshot.streak)) }
            return parts.joined(separator: ", ")
        }
    }

    /// Mochi's mood on the Mochi widget: cheering when the goal is met, happy once today has a
    /// review, curious otherwise, sleepy when the numbers are stale.
    public static func mochiMood(_ state: WidgetDisplayState) -> Mascot.Mood {
        switch state.kind {
        case .empty: return .curious
        case .stale: return .sleepy
        case .current:
            if state.isGoalMet { return .cheer }
            if state.snapshot?.studiedToday == true { return .happy }
            return .curious
        }
    }
}
