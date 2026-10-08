import SwiftUI
import UIKit

/// "This week" on Progress: the headline, seven dots and a way into the full recap.
struct WeeklyRecapCard: View {
    let recap: WeeklyRecap

    var body: some View {
        CardContainer(style: .crayon, wobbleSeed: 0x57A7_0000) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                HStack(alignment: .top, spacing: Spacing.sm) {
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        Text("本周")
                            .font(Typography.caption)
                            .foregroundStyle(Palette.brandSecondary)
                        Text(RecapCopy.headline(wordsMastered: recap.wordsMastered))
                            .font(Typography.sectionHeader)
                            .foregroundStyle(Palette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Mascot(mood: .happy, look: recap.look)
                        .frame(width: 58, height: 48)
                }

                RecapDayDots(dayKeys: recap.dayKeys, studiedDays: recap.studiedDays)

                Text([
                    RecapCopy.count(recap.reviews, "次复习"),
                    RecapCopy.daysStudied(recap.studiedDays),
                    RecapCopy.count(recap.minutes, "分钟"),
                ].joined(separator: " · "))
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)

                NavigationLink {
                    WeeklyRecapView(recap: recap)
                } label: {
                    HStack(spacing: Spacing.xxs) {
                        Text("看看这一周")
                        Image(systemName: "chevron.right")
                    }
                    .font(Typography.bodyEmphasis)
                    .foregroundStyle(Palette.brandPrimary)
                    .tappableArea()
                }
            }
        }
    }
}

/// The full weekly recap (engagement plan §1.9) with its share card.
///
/// Loads itself when opened without a recap (from the goal screen); Progress passes the one it
/// already has.
struct WeeklyRecapView: View {
    @Environment(\.appDependencies) private var dependencies
    @State private var recap: WeeklyRecap?
    /// The share card, rendered once: shown as the preview and handed to the share sheet.
    @State private var rendered: RenderedShareCard?
    @AppStorage(ShareSettings.enabledKey) private var isSharingEnabled = true
    @State private var didLoad = false

    init(recap: WeeklyRecap? = nil) {
        _recap = State(initialValue: recap)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                if let recap {
                    content(recap)
                } else if didLoad {
                    EmptyStateView(
                        systemImage: "calendar",
                        title: "还没有这一周的回顾",
                        message: "复习几个单词，这一周的回顾就会出现在这里。"
                    )
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .padding(Spacing.md)
            .readableWidth()
        }
        .screenBackground()
        .navigationTitle("本周回顾")
        .navigationBarTitleDisplayMode(.inline)
        .task { load() }
    }

    @ViewBuilder
    private func content(_ recap: WeeklyRecap) -> some View {
        VStack(spacing: Spacing.sm) {
            if let rendered {
                Image(uiImage: rendered.image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 320)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                            .strokeBorder(Palette.separator.opacity(0.5), lineWidth: 2)
                    )
                    .accessibilityLabel(ShareCard.week(recap).accessibilityLabel)
                // The parent switch hides the button, not the picture of the week.
                if isSharingEnabled {
                    ShareCardLink(rendered: rendered, label: "分享我的一周")
                }
            }
        }
        .frame(maxWidth: .infinity)

        CardContainer(style: .crayon, wobbleSeed: 0x2EC4_0001) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                SectionHeader("这七天")
                RecapDayDots(dayKeys: recap.dayKeys, studiedDays: recap.studiedDays)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: Spacing.xs) {
                    StatTile(value: "\(recap.wordsMastered)", label: "掌握的单词", tint: Palette.maturity(.mature))
                    StatTile(value: "\(recap.wordsStarted)", label: "开始学的单词", tint: Palette.maturity(.learning))
                    StatTile(value: "\(recap.reviews)", label: "复习次数")
                    StatTile(value: RecapCopy.percent(recap.accuracy), label: "记住了")
                    StatTile(value: "\(recap.minutes)", label: "分钟")
                    StatTile(value: "\(recap.streak)", label: "连续打卡天数", tint: Palette.brandSecondary, systemImage: "flame.fill")
                    StatTile(value: "\(recap.bestCombo)", label: "最高连击", systemImage: "bolt.fill")
                    StatTile(value: "\(recap.candyEarned)", label: "星星糖", systemImage: "star.fill")
                }
            }
        }

        if !recap.nailedWords.isEmpty {
            wordList("拿下的单词", subtitle: "本周你记得最牢的单词", words: recap.nailedWords, seed: 0x2EC4_0002)
        }
        if !recap.trickyWords.isEmpty {
            wordList("值得再看看", subtitle: "它们会早一点回来复习", words: recap.trickyWords, seed: 0x2EC4_0003)
        }
    }

    private func wordList(_ title: String, subtitle: String, words: [RecapWord], seed: UInt64) -> some View {
        CardContainer(style: .crayon, wobbleSeed: seed) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                SectionHeader(title, subtitle: subtitle)
                ForEach(words) { word in
                    HStack {
                        Text(word.headword)
                            .font(Typography.bodyEmphasis)
                            .foregroundStyle(Palette.textPrimary)
                        Spacer()
                        if let translation = word.translation {
                            Text(translation)
                                .font(Typography.body)
                                .foregroundStyle(Palette.textSecondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func load() {
        if recap == nil, let account = dependencies.account, let preferences = account.preferences {
            recap = try? dependencies.recap.recap(for: account, preferences: preferences, endingAt: Date())
        }
        didLoad = true
        guard let recap, rendered == nil else { return }
        rendered = ShareCardRenderer.render(.week(recap))
    }
}
