import SwiftUI

/// All sixteen badges: earned ones in gold with the day they were earned, the rest as drawn
/// outlines that say what earns them.
///
/// Locked badges are shown, never hidden: a child who can read "Study between 5 am and 7 am" has
/// a reason to try it, and one who cannot see the badge has none. Nothing here can be bought.
struct AchievementsView: View {
    @Environment(\.appDependencies) private var dependencies

    @State private var statuses: [AchievementStatus] = AchievementCatalog.all.map {
        AchievementStatus(achievement: $0, unlockedAt: nil)
    }
    /// For the badge sheet and its share card.
    @State private var look: MochiLook = .default
    @State private var level = 1
    @State private var selected: AchievementStatus?

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: Spacing.sm)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                header
                LazyVGrid(columns: columns, spacing: Spacing.sm) {
                    ForEach(statuses) { status in
                        if status.isUnlocked {
                            // Earned badges open their detail sheet, with a share card.
                            Button {
                                selected = status
                            } label: {
                                BadgeTile(status: status)
                            }
                            .pressable()
                            .accessibilityHint("Shows the badge")
                        } else {
                            BadgeTile(status: status)
                        }
                    }
                }
            }
            .padding(Spacing.md)
            .readableWidth()
        }
        .task { load() }
        .sheet(item: $selected) { status in
            BadgeDetailSheet(status: status, look: look, level: level)
        }
    }

    private var earnedCount: Int { statuses.filter(\.isUnlocked).count }

    private var header: some View {
        CardContainer(style: .crayon, wobbleSeed: 0xBAD6_E500_0001) {
            HStack(spacing: Spacing.md) {
                Mascot(mood: earnedCount > 0 ? .cheer : .happy)
                    .frame(width: 58, height: 48)
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text("\(earnedCount) of \(statuses.count) badges")
                        .font(Typography.sectionHeader)
                        .foregroundStyle(Palette.textPrimary)
                    Text(earnedCount == statuses.count
                         ? "Every badge earned. Mochi is so proud!"
                         : "Each badge adds 10 star candy, and some unlock something for Mochi to wear.")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func load() {
        let engagement = dependencies.engagement
        look = engagement.currentLook()
        if let profile = try? engagement.profile() {
            level = profile.level
        }
        guard let preferences = dependencies.preferences,
              let loaded = try? dependencies.engagement.achievementStatuses(preferences: preferences, now: .now),
              !loaded.isEmpty
        else { return }
        statuses = loaded
    }
}

/// One badge: a drawn medallion with its symbol, its name, what earns it, and when it was earned.
private struct BadgeTile: View {
    let status: AchievementStatus

    private var achievement: Achievement { status.achievement }
    private var reward: MochiAccessory? { WardrobeRules.accessory(unlockedBy: achievement.id) }

    var body: some View {
        VStack(spacing: Spacing.xs) {
            medallion
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)

            Text(achievement.name)
                .font(Typography.bodyEmphasis)
                .foregroundStyle(status.isUnlocked ? Palette.textPrimary : Palette.textSecondary)
                .multilineTextAlignment(.center)

            Text(achievement.detail)
                .font(Typography.caption)
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
                .lineLimit(3, reservesSpace: true)

            if let unlockedAt = status.unlockedAt {
                Chip("Earned \(unlockedAt.formatted(.dateTime.day().month(.abbreviated)))",
                     color: Palette.success, systemImage: "checkmark")
            } else {
                Chip("Not yet", color: Palette.textSecondary, systemImage: "lock.fill")
            }

            if let reward {
                Text(status.isUnlocked ? "Unlocked: \(reward.name)" : "Unlocks: \(reward.name)")
                    .font(Typography.chip)
                    .foregroundStyle(Palette.textSecondary)
            }
        }
        .padding(Spacing.sm)
        .frame(maxWidth: .infinity)
        .drawnPanel(seed: WobbleShape.seed(for: achievement.id.rawValue))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel)
    }

    private var medallion: some View {
        BadgeMedallion(id: achievement.id, symbolName: achievement.symbolName, isUnlocked: status.isUnlocked)
    }

    private var spokenLabel: String {
        var parts = [achievement.name, achievement.detail]
        if let unlockedAt = status.unlockedAt {
            parts.append("Earned \(unlockedAt.formatted(date: .long, time: .omitted))")
        } else {
            parts.append("Not earned yet")
        }
        if let reward {
            parts.append(status.isUnlocked ? "Unlocked \(reward.name) for Mochi" : "Unlocks \(reward.name) for Mochi")
        }
        return parts.joined(separator: ". ")
    }
}

/// A badge's drawn medallion: gold with its symbol once earned, a dotted outline with a lock
/// before. Shared by the grid, the badge sheet and the badge share card.
struct BadgeMedallion: View {
    let id: AchievementID
    let symbolName: String
    let isUnlocked: Bool
    var symbolSize: CGFloat?

    var body: some View {
        let shape = WobbleShape(cornerRadius: 32, amplitude: 1.0, seed: WobbleShape.seed(for: "badge-" + id.rawValue))
        ZStack {
            if isUnlocked {
                shape.fill(Chunky.baseColor).offset(y: 3)
                shape.fill(Palette.rating(.hard))
                shape.stroke(Palette.ratingEdge(.hard), lineWidth: 2.5)
                Image(systemName: symbolName)
                    .font(symbolFont(weight: .bold))
                    .foregroundStyle(Palette.onRating)
            } else {
                shape.fill(Palette.surface)
                shape.stroke(Palette.textTertiary, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [3, 4]))
                Image(systemName: symbolName)
                    .font(symbolFont(weight: .regular))
                    .foregroundStyle(Palette.textTertiary)
                Image(systemName: "lock.fill")
                    .font(.caption2)
                    .foregroundStyle(Palette.textSecondary)
                    .padding(4)
                    .background(Circle().fill(Palette.surfaceRaised))
                    .overlay(Circle().stroke(Palette.textTertiary, lineWidth: 1))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
        }
    }

    /// `.title2` by default, as the grid always drew it; a fixed size where the medallion is
    /// drawn larger (the sheet, the share card).
    private func symbolFont(weight: Font.Weight) -> Font {
        if let symbolSize {
            return .system(size: symbolSize, weight: weight)
        }
        return .title2.weight(weight)
    }
}
