import SwiftUI
import UIKit

/// One celebration at a time, at the top of the card.
///
/// The study screen drains ``StudyViewModel/events`` into this one by one; each shows for
/// ``displaySeconds`` and can be tapped away. It sits over the *top* of the card and never over
/// the rating bar — a toast that swallows a tap meant for "Got it" would turn a reward into an
/// obstacle (engagement plan §2.3, §4).
///
/// The copy never mentions a loss. A broken combo is announced as the run it was ("Nice run:
/// 12 in a row!"), and the plain per-answer candy has no toast at all — it ticks up in the candy
/// pill, and a toast on every card would make all of them noise.
struct RewardToast: View {
    /// What a toast says.
    struct Message: Equatable {
        let emoji: String
        let text: String
    }

    let event: EngagementEvent
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How long each toast stays up.
    static let displaySeconds: Double = 1.6

    /// The words for `event`, or `nil` for events that are shown elsewhere and get no toast.
    ///
    /// Pure, so the copy — the one place a child reads what the app thinks of them — is pinned by
    /// tests rather than proofread on a device.
    static func message(for event: EngagementEvent) -> Message? {
        switch event {
        case .candy:
            return nil
        case .firstReviewToday(let streak):
            return streak > 1
                ? Message(emoji: "🔥", text: "\(streak) days in a row!")
                : Message(emoji: "🔥", text: "Your streak has started!")
        case .comboMilestone(let combo):
            let bonus = RewardEngine.comboBonus(combo)
            return Message(emoji: "🔥", text: bonus > 0 ? "\(combo) in a row! +\(bonus) ⭐" : "\(combo) in a row!")
        case .comboEnded(let best):
            return Message(emoji: "🌟", text: "Nice run: \(best) in a row!")
        case .stickerLit:
            return Message(emoji: "✨", text: "A sticker lit up! +\(RewardEngine.stickerBonus) ⭐")
        case .albumCompleted(_, let title):
            return Message(emoji: "📒", text: "\(title) complete! +\(RewardEngine.albumBonus) ⭐")
        case .levelUp(let level):
            return Message(emoji: "🎉", text: "Mochi reached level \(level)!")
        case .achievement(let id):
            let name = AchievementCatalog.achievement(id)?.name ?? "New badge"
            return Message(emoji: "🏅", text: "\(name)! +\(RewardEngine.achievementBonus) ⭐")
        case .welcomeBack:
            return Message(emoji: "💛", text: "Mochi missed you! Let's do a few words.")
        }
    }

    var body: some View {
        if let message = Self.message(for: event) {
            Button(action: onDismiss) {
                HStack(spacing: Spacing.xs) {
                    Text(message.emoji)
                        .accessibilityHidden(true)
                    Text(message.text)
                        .font(Typography.bodyEmphasis)
                        .foregroundStyle(Palette.textPrimary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.sm)
                .background {
                    let shape = WobbleShape(cornerRadius: Radius.button, amplitude: 0.8, seed: 0x7A57_0000_0000_0001)
                    ZStack {
                        shape.fill(Chunky.baseColor).offset(y: 3)
                        shape.fill(Palette.surface)
                            .overlay(shape.stroke(Palette.brandSecondary.opacity(0.7), lineWidth: 2))
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(message.text)
            .accessibilityHint("Dismisses this message")
            .task {
                // Read out once, without moving VoiceOver's focus off the card.
                UIAccessibility.post(notification: .announcement, argument: message.text)
                try? await Task.sleep(for: .seconds(Self.displaySeconds))
                // Cancelled when the toast is tapped away or replaced; dismissing again then would
                // skip the next one.
                guard !Task.isCancelled else { return }
                onDismiss()
            }
        }
    }
}

#Preview {
    VStack(spacing: Spacing.md) {
        RewardToast(event: .comboEnded(best: 12)) {}
        RewardToast(event: .levelUp(5)) {}
        RewardToast(event: .welcomeBack(daysAway: 4)) {}
    }
    .padding()
}
