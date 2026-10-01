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
                        Text("This week")
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
                    RecapCopy.count(recap.reviews, "review"),
                    RecapCopy.daysStudied(recap.studiedDays),
                    RecapCopy.count(recap.minutes, "minute"),
                ].joined(separator: " · "))
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)

                NavigationLink {
                    WeeklyRecapView(recap: recap)
                } label: {
                    HStack(spacing: Spacing.xxs) {
                        Text("See your week")
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
                        title: "No week to show yet",
                        message: "Review a few words and your week will appear here."
                    )
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .padding(Spacing.md)
            .readableWidth()
        }
        .screenBackground()
        .navigationTitle("Your week")
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
                    ShareCardLink(rendered: rendered, label: "Share my week")
                }
            }
        }
        .frame(maxWidth: .infinity)

        CardContainer(style: .crayon, wobbleSeed: 0x2EC4_0001) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                SectionHeader("Seven days")
                RecapDayDots(dayKeys: recap.dayKeys, studiedDays: recap.studiedDays)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: Spacing.xs) {
                    StatTile(value: "\(recap.wordsMastered)", label: "Words mastered", tint: Palette.maturity(.mature))
                    StatTile(value: "\(recap.wordsStarted)", label: "Words started", tint: Palette.maturity(.learning))
                    StatTile(value: "\(recap.reviews)", label: "Reviews")
                    StatTile(value: RecapCopy.percent(recap.accuracy), label: "Recalled")
                    StatTile(value: "\(recap.minutes)", label: "Minutes")
                    StatTile(value: "\(recap.streak)", label: "Day streak", tint: Palette.brandSecondary, systemImage: "flame.fill")
                    StatTile(value: "\(recap.bestCombo)", label: "Best combo", systemImage: "bolt.fill")
                    StatTile(value: "\(recap.candyEarned)", label: "Star candy", systemImage: "star.fill")
                }
            }
        }

        if !recap.nailedWords.isEmpty {
            wordList("Words you nailed", subtitle: "Your strongest words this week", words: recap.nailedWords, seed: 0x2EC4_0002)
        }
        if !recap.trickyWords.isEmpty {
            wordList("Worth another look", subtitle: "They will come back a little sooner", words: recap.trickyWords, seed: 0x2EC4_0003)
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
