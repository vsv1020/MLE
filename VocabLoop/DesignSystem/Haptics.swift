import UIKit

/// Haptic feedback for review actions.
///
/// Generators are created per call rather than cached: a long-lived
/// `UIImpactFeedbackGenerator` keeps the Taptic Engine warm and measurably drains
/// battery, which is not a trade worth making for a tap that happens a few times a minute.
@MainActor
public enum Haptics {
    /// Set from `StudyPreferences.hapticsEnabled` so a single flag silences everything.
    public static var isEnabled = true

    /// Rating a card.
    public static func tap() {
        guard isEnabled else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// Revealing an answer.
    public static func reveal() {
        guard isEnabled else { return }
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
    }

    /// Finishing a session, or hitting the daily goal.
    public static func success() {
        guard isEnabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// A failed action — never for rating a card `Again`. Getting a word wrong is part of
    /// learning, and buzzing at the user for it is exactly the punitive design this app
    /// avoids.
    public static func error() {
        guard isEnabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
}
