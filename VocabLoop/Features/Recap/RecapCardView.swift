import SwiftUI
import UIKit

/// The seven study days as dots, oldest first, with a weekday letter under each.
///
/// Filled for a day with any review, an outline otherwise — an empty day is drawn as a space
/// waiting, never as a cross.
struct RecapDayDots: View {
    let dayKeys: [String]
    let studiedDays: [Bool]
    var dotSize: CGFloat = 22

    var body: some View {
        HStack(spacing: Spacing.xs) {
            ForEach(Array(dayKeys.enumerated()), id: \.offset) { index, key in
                let studied = index < studiedDays.count && studiedDays[index]
                VStack(spacing: Spacing.xxs) {
                    ZStack {
                        Circle()
                            .fill(studied ? Palette.brandSecondary : Palette.surfaceRaised)
                        Circle()
                            .strokeBorder(
                                studied ? Palette.brandSecondary : Palette.textTertiary,
                                lineWidth: 2
                            )
                        if studied {
                            Image(systemName: "checkmark")
                                .font(.system(size: dotSize * 0.45, weight: .heavy, design: .rounded))
                                .foregroundStyle(Palette.onBrand)
                        }
                    }
                    .frame(width: dotSize, height: dotSize)
                    Text(RecapCopy.weekdayInitial(dayKey: key))
                        .font(Typography.chip)
                        .foregroundStyle(Palette.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    "\(RecapCopy.weekdayName(dayKey: key)): \(studied ? "studied" : "not studied")"
                )
            }
        }
    }
}

/// The shareable "my week" card (engagement plan §1.9): headline, seven dots, Mochi and three
/// words nailed this week.
///
/// Laid out for exactly ``RecapShareMetrics/pointSize`` and rendered at 3× to 1080×1350, the
/// 4:5 portrait size social apps show uncropped. Always drawn in the light (paper) appearance and
/// at a fixed text size: it is an image that leaves the app, and must look the same wherever it
/// lands.
///
/// Contains only first-name-free, account-free facts — no name, no email, nothing that
/// identifies the child.
struct RecapCardView: View {
    let recap: WeeklyRecap

    var body: some View {
        VStack(spacing: Spacing.md) {
            HStack(spacing: Spacing.xxs) {
                Image(systemName: "sparkles")
                Text("My week on VocabLoop")
            }
            .font(Typography.caption)
            .foregroundStyle(Palette.brandSecondary)

            Text(RecapCopy.headline(wordsMastered: recap.wordsMastered))
                .font(Typography.screenTitle)
                .foregroundStyle(Palette.textPrimary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .minimumScaleFactor(0.7)

            WidgetMochiView(look: recap.look, level: recap.level, mood: .cheer)
                .frame(width: 132, height: 128)

            RecapDayDots(dayKeys: recap.dayKeys, studiedDays: recap.studiedDays, dotSize: 24)
                .padding(.horizontal, Spacing.xs)

            if !recap.nailedWords.isEmpty {
                VStack(spacing: Spacing.xs) {
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

            Spacer(minLength: 0)

            HStack(spacing: Spacing.md) {
                footerStat(RecapCopy.count(recap.reviews, "review"), symbol: "checkmark.circle.fill")
                footerStat(RecapCopy.count(recap.minutes, "min", "min"), symbol: "clock.fill")
                if recap.streak > 0 {
                    footerStat("\(recap.streak)-day streak", symbol: "flame.fill")
                }
            }
        }
        .padding(Spacing.lg)
        .frame(width: RecapShareMetrics.pointSize.width, height: RecapShareMetrics.pointSize.height)
        .background(Palette.canvas)
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

/// Size of the share image. Not actor-bound, so layout and tests can read it anywhere.
enum RecapShareMetrics {
    /// Layout size in points.
    static let pointSize = CGSize(width: 360, height: 450)
    /// Render scale: 360×450 pt → 1080×1350 px.
    static let scale: CGFloat = 3

    /// The image size the share card is rendered at.
    static var pixelSize: CGSize {
        CGSize(width: pointSize.width * scale, height: pointSize.height * scale)
    }
}

/// Turns a recap into a PNG file a `ShareLink` can hand to other apps.
///
/// A file URL rather than an `Image`: `ShareLink` with an `Image` needs a `Transferable`
/// wrapper, whereas `URL` is `Transferable` already and a PNG on disk is what every share
/// target expects (engagement plan §4, risks).
@MainActor
enum RecapShareRenderer {
    /// Render `recap` and write it to the temporary directory. `nil` if rendering or the write
    /// fails — the share button is simply not offered then.
    static func writePNG(for recap: WeeklyRecap) -> URL? {
        let renderer = ImageRenderer(content: shareContent(for: recap))
        renderer.scale = RecapShareMetrics.scale
        renderer.proposedSize = ProposedViewSize(RecapShareMetrics.pointSize)
        guard let data = renderer.uiImage?.pngData() else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("VocabLoop-my-week-\(recap.weekStartKey).png")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// The card exactly as it is rendered, for the on-screen preview too.
    static func shareContent(for recap: WeeklyRecap) -> some View {
        RecapCardView(recap: recap)
            .environment(\.colorScheme, .light)
            .dynamicTypeSize(.large)
    }
}

#Preview {
    RecapCardView(recap: WeeklyRecap(
        weekStartKey: "2026-09-25",
        dayKeys: ["2026-09-25", "2026-09-26", "2026-09-27", "2026-09-28", "2026-09-29", "2026-09-30", "2026-10-01"],
        studiedDays: [true, true, false, true, true, true, true],
        reviews: 182, accuracy: 0.86, minutes: 64, wordsMastered: 12, wordsStarted: 20,
        bestCombo: 17, candyEarned: 260, level: 6, look: .default, streak: 5,
        nailedWords: [
            RecapWord(entryStableID: "a", headword: "because", translation: "因为"),
            RecapWord(entryStableID: "b", headword: "window", translation: "窗户"),
            RecapWord(entryStableID: "c", headword: "brave", translation: "勇敢"),
        ],
        headline: "This week you mastered 12 words"
    ))
}
