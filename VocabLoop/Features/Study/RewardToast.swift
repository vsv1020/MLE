import SwiftUI
import UIKit

/// One celebration at a time, at the top of the card.
///
/// The study screen drains ``StudyViewModel/events`` into this one by one; each shows for
/// ``displaySeconds`` and then goes by itself. It sits over the *top* of the card and never over
/// the rating bar — a toast that swallows a tap meant for "Got it" would turn a reward into an
/// obstacle (engagement plan §2.3, §4). For the same reason it takes no taps at all: over the
/// top of the card it would otherwise eat a tap meant for the card or a quiz option.
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
                ? Message(emoji: "🔥", text: "连续打卡 \(streak) 天！")
                : Message(emoji: "🔥", text: "连续打卡开始啦！")
        case .comboMilestone(let combo):
            let bonus = RewardEngine.comboBonus(combo)
            return Message(emoji: "🔥", text: bonus > 0 ? "连对 \(combo) 个！+\(bonus) ⭐" : "连对 \(combo) 个！")
        case .comboEnded(let best):
            return Message(emoji: "🌟", text: "真棒：连对了 \(best) 个！")
        case .stickerLit:
            return Message(emoji: "✨", text: "一张贴纸闪亮啦！+\(RewardEngine.stickerBonus) ⭐")
        case .albumCompleted(_, let title):
            return Message(emoji: "📒", text: "“\(title)”集齐了！+\(RewardEngine.albumBonus) ⭐")
        case .levelUp(let level):
            return Message(emoji: "🎉", text: "麻薯升到 \(level) 级啦！")
        case .achievement(let id):
            let name = AchievementCatalog.achievement(id)?.name ?? "新徽章"
            return Message(emoji: "🏅", text: "\(name)！+\(RewardEngine.achievementBonus) ⭐")
        case .welcomeBack:
            return Message(emoji: "💛", text: "麻薯想你啦！我们来背几个单词吧。")
        }
    }

    var body: some View {
        if let message = Self.message(for: event) {
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
            // Taps go straight through to the card underneath; the toast leaves on its own.
            .allowsHitTesting(false)
            // Still one element that reads the reward, for anyone who swipes to it before it goes.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(message.text)
            .task {
                // Read out once, without moving VoiceOver's focus off the card.
                UIAccessibility.post(notification: .announcement, argument: message.text)
                try? await Task.sleep(for: .seconds(Self.displaySeconds))
                // Cancelled when the toast is replaced; dismissing again then would skip the
                // next one.
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
