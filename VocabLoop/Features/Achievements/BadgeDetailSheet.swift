import SwiftUI

/// One earned badge, up close: the medallion, its name, what earned it, the day, what it gave
/// Mochi, and a share card (sharing plan §1).
///
/// Opened by tapping an earned tile in ``AchievementsView``. Locked badges do not open it — they
/// already say what earns them, and there is nothing to share yet.
struct BadgeDetailSheet: View {
    let status: AchievementStatus
    let look: MochiLook
    let level: Int

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    private var achievement: Achievement { status.achievement }
    private var reward: MochiAccessory? { WardrobeRules.accessory(unlockedBy: achievement.id) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Spacing.lg) {
                    BadgeMedallion(
                        id: achievement.id,
                        symbolName: achievement.symbolName,
                        isUnlocked: status.isUnlocked,
                        symbolSize: 44
                    )
                    .frame(width: 120, height: 120)
                    .scaleEffect(appeared ? 1 : 0.7)
                    .animation(Motion.pop(reduceMotion), value: appeared)
                    .accessibilityHidden(true)
                    .padding(.top, Spacing.md)

                    VStack(spacing: Spacing.xs) {
                        Text(achievement.name)
                            .font(Typography.screenTitle)
                            .foregroundStyle(Palette.textPrimary)
                            .multilineTextAlignment(.center)
                        Text(achievement.detail)
                            .font(Typography.body)
                            .foregroundStyle(Palette.textSecondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        if let unlockedAt = status.unlockedAt {
                            Chip(ShareCopy.earned(unlockedAt), color: Palette.success, systemImage: "checkmark")
                        }
                    }
                    .accessibilityElement(children: .combine)

                    HStack(spacing: Spacing.sm) {
                        Mascot(mood: .cheer, look: look)
                            .frame(width: 58, height: 48)
                            .accessibilityHidden(true)
                        Text(rewardLine)
                            .font(Typography.caption)
                            .foregroundStyle(Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(Spacing.sm)
                    .drawnPanel(seed: WobbleShape.seed(for: "badge-sheet-" + achievement.id.rawValue))

                    if let card = BadgeCard(status: status, look: look, level: level) {
                        ShareCardButton(card: .badge(card), label: "Share my badge")
                    }
                }
                .padding(Spacing.md)
                .readableWidth()
            }
            .screenBackground()
            .navigationTitle("Badge")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
        .task { appeared = true }
    }

    /// What the badge gave Mochi: ten star candy always, and a wardrobe item for some.
    private var rewardLine: String {
        if let reward {
            return "Mochi got 10 star candy and something new to wear: \(reward.name)."
        }
        return "Mochi got 10 star candy for this one."
    }
}
