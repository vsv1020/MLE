import SwiftUI

/// Mochi's level at a glance: a ring filling toward the next level, the star candy behind it, and
/// what the next level brings.
///
/// Candy is XP and is never spent, so this card has no balance to protect and no price anywhere:
/// the number only ever goes up. Usable anywhere a summary of Mochi fits — Today's Mochi row can
/// show it as-is.
struct MochiStatusCard: View {
    private let candy: Int

    init(candy: Int) {
        self.candy = max(0, candy)
    }

    private var level: Int { RewardEngine.level(forCandy: candy) }
    private var stage: MochiStage { RewardEngine.stage(forLevel: level) }

    var body: some View {
        CardContainer(style: .crayon, wobbleSeed: 0x3C41_5747_0001) {
            HStack(alignment: .center, spacing: Spacing.md) {
                ZStack {
                    ProgressRing(progress: RewardEngine.progressToNextLevel(candy: candy), lineWidth: 9)
                        .frame(width: 76, height: 76)
                    VStack(spacing: 0) {
                        Text("\(level)")
                            .font(Typography.statValue)
                            .foregroundStyle(Palette.textPrimary)
                        Text("level")
                            .font(Typography.caption)
                            .foregroundStyle(Palette.textSecondary)
                    }
                }
                .frame(width: 76, height: 76)

                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(WardrobeRules.stageName(stage))
                        .font(Typography.sectionHeader)
                        .foregroundStyle(Palette.textPrimary)
                    HStack(spacing: Spacing.xxs) {
                        Image(systemName: "star.fill")
                            .foregroundStyle(Palette.brandSecondary)
                            .accessibilityHidden(true)
                        Text("\(candy.formatted()) star candy")
                            .font(Typography.bodyEmphasis)
                            .foregroundStyle(Palette.textPrimary)
                    }
                    if let remaining = WardrobeRules.candyToNextLevel(candy: candy) {
                        Text("\(remaining.formatted()) more to level \(level + 1)")
                            .font(Typography.caption)
                            .foregroundStyle(Palette.textSecondary)
                    } else {
                        Text("Top level. Mochi is as big as Mochi gets!")
                            .font(Typography.caption)
                            .foregroundStyle(Palette.textSecondary)
                    }
                    if let next = WardrobeRules.nextUnlock(after: level) {
                        Text("Next: \(next.name) at level \(next.level)")
                            .font(Typography.caption)
                            .foregroundStyle(Palette.textSecondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenSummary)
    }

    private var spokenSummary: String {
        var parts = ["\(WardrobeRules.stageName(stage)), level \(level)", "\(candy.formatted()) star candy"]
        if let remaining = WardrobeRules.candyToNextLevel(candy: candy) {
            parts.append("\(remaining.formatted()) more to level \(level + 1)")
        }
        if let next = WardrobeRules.nextUnlock(after: level) {
            parts.append("Next unlock: \(next.name) at level \(next.level)")
        }
        return parts.joined(separator: ". ")
    }
}
