import SwiftUI

/// One share card, laid out for exactly ``ShareCardMetrics/pointSize``.
///
/// Draws only what its payload carries: no environment reads beyond appearance, no store.
struct ShareCardView: View {
    let card: ShareCard

    var body: some View {
        content
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(card.accessibilityLabel)
    }

    @ViewBuilder
    private var content: some View {
        switch card {
        case .goalComplete(let goal):
            GoalShareCardView(card: goal)
        case .streak(let streak):
            StreakShareCardView(card: streak)
        case .badge(let badge):
            BadgeShareCardView(card: badge)
        case .mochi(let mochi):
            MochiShareCardView(card: mochi)
        case .word(let word):
            WordShareCardView(card: word)
        case .album(let album):
            AlbumShareCardView(card: album)
        case .week(let recap):
            WeekShareCardView(recap: recap)
        }
    }
}

// MARK: - Goal

private struct GoalShareCardView: View {
    let card: GoalCard

    var body: some View {
        ShareCardFrame(
            kind: .goal,
            headline: ShareCopy.goalHeadline(reviews: card.reviewsToday),
            hero: .mochi(look: card.look, level: card.level, mood: .cheer, height: 132)
        ) {
            VStack(spacing: Spacing.xs) {
                HStack(spacing: Spacing.xs) {
                    ShareStatChip(text: RecapCopy.count(card.reviewsToday, "review"), systemImage: "checkmark.circle.fill")
                    if let minutes = ShareCopy.minutes(card.minutes) {
                        ShareStatChip(text: minutes, systemImage: "clock.fill")
                    }
                }
                HStack(spacing: Spacing.xs) {
                    if let streak = ShareCopy.streakChip(card.streak) {
                        ShareStatChip(text: streak, systemImage: "flame.fill")
                    }
                    if let goal = ShareCopy.goalChip(card.dailyGoal) {
                        ShareStatChip(text: goal, systemImage: "target")
                    }
                }
            }
        }
    }
}

// MARK: - Streak

private struct StreakShareCardView: View {
    let card: StreakCard

    var body: some View {
        ShareCardFrame(
            kind: .streak,
            headline: ShareCopy.streakHeadline(days: card.streak),
            hero: .mochi(look: card.look, level: card.level, mood: .cheer, height: 132)
        ) {
            VStack(spacing: Spacing.sm) {
                // One flame per day, up to a week: a picture of the habit, not a score.
                HStack(spacing: Spacing.xs) {
                    ForEach(0..<min(max(card.streak, 0), 7), id: \.self) { _ in
                        Image(systemName: "flame.fill")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundStyle(Palette.brandSecondary)
                    }
                    if card.streak > 7 {
                        Text("+\(card.streak - 7)")
                            .font(Typography.bodyEmphasis)
                            .foregroundStyle(Palette.brandSecondary)
                    }
                }
                if let longest = ShareCopy.longestChip(current: card.streak, longest: card.longest) {
                    ShareStatChip(text: longest, systemImage: "trophy.fill")
                }
            }
        }
    }
}

// MARK: - Badge

private struct BadgeShareCardView: View {
    let card: BadgeCard

    var body: some View {
        ShareCardFrame(
            kind: .badge,
            headline: ShareCopy.badgeHeadline(name: card.name),
            hero: .mochi(look: card.look, level: card.level, mood: .cheer, height: 112)
        ) {
            HStack(spacing: Spacing.md) {
                BadgeMedallion(id: card.id, symbolName: card.symbolName, isUnlocked: true, symbolSize: 30)
                    .frame(width: 80, height: 80)
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(card.detail)
                        .font(Typography.body)
                        .foregroundStyle(Palette.textPrimary)
                        .lineLimit(3)
                        .minimumScaleFactor(0.8)
                        .fixedSize(horizontal: false, vertical: true)
                    if let unlockedAt = card.unlockedAt {
                        ShareStatChip(text: ShareCopy.earned(unlockedAt), systemImage: "checkmark")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(Spacing.sm)
            .drawnPanel(seed: WobbleShape.seed(for: "share-badge-" + card.id.rawValue))
        }
    }
}

// MARK: - Mochi

private struct MochiShareCardView: View {
    let card: MochiCard

    var body: some View {
        ShareCardFrame(
            kind: .mochi,
            headline: ShareCopy.mochiHeadline(level: card.level),
            hero: .mochi(look: card.look, level: card.level, mood: .happy, height: 176)
        ) {
            HStack(spacing: Spacing.xs) {
                ShareStatChip(text: card.stageName, systemImage: "sparkles")
                ShareStatChip(text: ShareCopy.candy(card.candy), systemImage: "star.fill")
            }
        }
    }
}

// MARK: - Word

/// Dictionary content only: headword, phonetic, the first definition and one example.
private struct WordShareCardView: View {
    let card: WordCard

    var body: some View {
        ShareCardFrame(
            kind: .word,
            headline: Text(ShareCopy.wordHeadlinePrefix) + Text(card.headword).italic(),
            hero: .none
        ) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack(alignment: .center, spacing: Spacing.sm) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(card.headword)
                            .font(Typography.wordDisplay)
                            .foregroundStyle(Palette.textPrimary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                        if let phonetic = card.phonetic {
                            Text(phonetic)
                                .font(Typography.phonetic)
                                .foregroundStyle(Palette.textSecondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                    }
                    Spacer(minLength: 0)
                    Mascot(mood: .happy, look: card.look)
                        .frame(width: 66, height: 55)
                }

                Text(card.definition)
                    .font(Typography.body)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(3)
                    .minimumScaleFactor(0.8)
                    .fixedSize(horizontal: false, vertical: true)

                if let example = card.example {
                    exampleText(example)
                        .font(Typography.example)
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(3)
                        .minimumScaleFactor(0.8)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.sm)
            .drawnPanel(seed: WobbleShape.seed(for: "share-word-" + card.headword))
        }
    }

    private func exampleText(_ example: String) -> Text {
        guard let parts = ShareCopy.emphasis(in: example, cloze: card.exampleCloze, headword: card.headword) else {
            return Text(example)
        }
        return Text(parts.before)
            + Text(parts.match).bold().foregroundColor(Palette.textPrimary)
            + Text(parts.after)
    }
}

// MARK: - Album

private struct AlbumShareCardView: View {
    let card: AlbumCard

    private var stars: Int { min(max(card.stickerCount, 0), Album.pageSize) }

    var body: some View {
        ShareCardFrame(
            kind: .album,
            headline: ShareCopy.albumHeadline(stickers: card.stickerCount),
            hero: .mochi(look: card.look, level: card.level, mood: .cheer, height: 112)
        ) {
            VStack(spacing: Spacing.sm) {
                Text(card.albumTitle)
                    .font(Typography.sectionHeader)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                // The page's stickers, all shining: two rows of six.
                VStack(spacing: Spacing.xs) {
                    starRow(count: min(stars, 6))
                    if stars > 6 {
                        starRow(count: stars - 6)
                    }
                }
                HStack(spacing: Spacing.xs) {
                    ShareStatChip(text: "\(card.albumLevel) \(card.familyTitle)", systemImage: "book.fill")
                    ShareStatChip(text: "Page \(card.page)", systemImage: "square.grid.3x3.fill")
                }
            }
        }
    }

    private func starRow(count: Int) -> some View {
        HStack(spacing: Spacing.xs) {
            ForEach(0..<count, id: \.self) { _ in
                Image(systemName: "star.fill")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Palette.brandSecondary)
            }
        }
    }
}

// MARK: - Week

/// The weekly recap (engagement plan §1.9): seven dots, three words nailed, and the week's numbers.
private struct WeekShareCardView: View {
    let recap: WeeklyRecap

    var body: some View {
        ShareCardFrame(
            kind: .week,
            headline: RecapCopy.headline(wordsMastered: recap.wordsMastered),
            hero: .mochi(look: recap.look, level: recap.level, mood: .cheer, height: 100)
        ) {
            VStack(spacing: Spacing.xs) {
                RecapDayDots(dayKeys: recap.dayKeys, studiedDays: recap.studiedDays, dotSize: 24)
                    .padding(.horizontal, Spacing.xs)

                if !recap.nailedWords.isEmpty {
                    VStack(spacing: Spacing.xxs) {
                        Text("Words I nailed")
                            .font(Typography.caption)
                            .foregroundStyle(Palette.textSecondary)
                        HStack(spacing: Spacing.xs) {
                            ForEach(Array(recap.nailedWords.prefix(3))) { word in
                                Text(word.headword)
                                    .font(Typography.bodyEmphasis)
                                    .foregroundStyle(Palette.textPrimary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.6)
                                    .padding(.horizontal, Spacing.sm)
                                    .padding(.vertical, Spacing.xxs)
                                    .background(Capsule().fill(Palette.surfaceRaised))
                                    .overlay(Capsule().strokeBorder(Palette.separator.opacity(0.5), lineWidth: 1.5))
                            }
                        }
                    }
                }

                HStack(spacing: Spacing.md) {
                    footerStat(RecapCopy.count(recap.reviews, "review"), symbol: "checkmark.circle.fill")
                    footerStat(RecapCopy.count(recap.minutes, "min", "min"), symbol: "clock.fill")
                    if recap.streak > 0 {
                        footerStat("\(recap.streak)-day streak", symbol: "flame.fill")
                    }
                }
            }
        }
    }

    private func footerStat(_ text: String, symbol: String) -> some View {
        HStack(spacing: Spacing.xxs) {
            Image(systemName: symbol)
                .foregroundStyle(Palette.brandSecondary)
            Text(text)
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(1)
        }
        .font(Typography.caption)
    }
}
