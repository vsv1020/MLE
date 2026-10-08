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
                    "\(RecapCopy.weekdayName(dayKey: key))：\(studied ? "学习了" : "没有学习")"
                )
            }
        }
    }
}

/// The shareable "my week" card (engagement plan §1.9): headline, seven dots, Mochi and three
/// words nailed this week.
///
/// Since 1.0.8 it is one case of the shared share-card system (sharing plan §3): the layout lives
/// in ``ShareCardView`` inside ``ShareCardFrame``, rendered at 3× to 1080×1350 by
/// ``ShareCardRenderer``. Contains only first-name-free, account-free facts — no name, no email,
/// nothing that identifies the child.
struct RecapCardView: View {
    let recap: WeeklyRecap

    var body: some View {
        ShareCardView(card: .week(recap))
    }
}

/// The 1.0.7 name for ``ShareCardMetrics``, kept so existing call sites and tests read on.
typealias RecapShareMetrics = ShareCardMetrics

/// Turns a recap into a PNG file a `ShareLink` can hand to other apps. A thin wrapper over
/// ``ShareCardRenderer``, kept for the 1.0.7 call sites.
@MainActor
enum RecapShareRenderer {
    /// Render `recap` and write it to the temporary directory. `nil` if rendering or the write
    /// fails — the share button is simply not offered then.
    static func writePNG(for recap: WeeklyRecap) -> URL? {
        ShareCardRenderer.writePNG(.week(recap))
    }

    /// The card exactly as it is rendered, for the on-screen preview too.
    static func shareContent(for recap: WeeklyRecap) -> some View {
        ShareCardRenderer.content(for: .week(recap))
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
        headline: "这周你掌握了 12 个单词"
    ))
}
