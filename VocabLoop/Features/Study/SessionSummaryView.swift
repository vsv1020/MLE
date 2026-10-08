import SwiftUI

/// End of session.
///
/// Reports what happened without grading the user. No "you could do better", no comparison to
/// yesterday — a session that ends in a scolding is a session people stop starting.
struct SessionSummaryView: View {
    let model: StudyViewModel
    let onDone: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Flipped once in `.task` so the whole set piece has something to animate *from*. Views born
    /// holding their final state animate nothing, which is why this screen used to be static
    /// despite the design system having had a `celebrate` spring the whole time.
    @State private var appeared = false
    @State private var barsRevealed = false

    /// Only a finished session earns the set piece.
    ///
    /// `phase` still becomes `.finished` on paths that reviewed nothing: the `catch` in
    /// `StudyViewModel.start`, its `guard let preferences` early return, and an empty first
    /// build. Burying or suspending no longer ends a session — that path refills now — but the
    /// gate stays, because without it a store failure fires confetti behind an error.
    private var didStudy: Bool { model.reviewedCount > 0 }

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.lg) {
                Spacer(minLength: Spacing.xl)

                VStack(spacing: Spacing.sm) {
                    // The burst is confined to this 160pt frame and clipped, so no particle ever
                    // travels behind the headline. Mounting it as the whole block's background put
                    // confetti under text at 1.16:1 — a WCAG 1.4.3 failure that a decorative-fill
                    // test would happily report green.
                    ZStack {
                        if didStudy {
                            SummaryBurst()
                        }
                        // Mochi in the middle of the burst, rather than a seal. The glyph said
                        // "task complete"; a cheering face says "well done", which is what this
                        // moment is for. Asleep when there was nothing to study — no confetti,
                        // and nothing that implies the user failed to do something.
                        Mascot(mood: didStudy ? .cheer : .sleepy)
                            .frame(width: 104, height: 86)
                            .scaleEffect(appeared || !didStudy ? 1 : 0.6)
                    }
                    .frame(width: 160, height: 160)
                    .clipped()

                    Text(didStudy ? "都复习完了" : "现在没有要学的")
                        .font(Typography.screenTitle)
                        .foregroundStyle(Palette.textPrimary)
                    Text(subtitle)
                        .font(Typography.body)
                        .foregroundStyle(Palette.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .animation(Motion.celebrate(reduceMotion), value: appeared)

                if didStudy {
                    statsGrid
                    ratingBreakdown
                }

                Spacer(minLength: Spacing.lg)
                PrimaryButton("完成", action: onDone)
            }
            .padding(Spacing.md)
            .readableWidth()
        }
        .task {
            // No `Haptics.success()` here. It already fires from `StudyViewModel.grade`, and a
            // second one 100ms later is a double buzz, not a bigger moment.
            appeared = true
            guard didStudy else { return }
            try? await Task.sleep(for: .seconds(0.5))
            withAnimation(Motion.reveal(reduceMotion)) { barsRevealed = true }
        }
    }

    /// Reaching this screen means something much rarer than it used to.
    ///
    /// The queue refills itself now, so `.finished` is no longer "this batch is over" — it is
    /// "there is nothing left in the library at all", which for most people never happens. The
    /// copy has to say that rather than implying the user should come back tomorrow for more of
    /// a pile that is already empty.
    private var subtitle: String {
        guard model.reviewedCount > 0 else {
            return "没有待复习的卡片，也没有新词了。可以添加一些单词，或者等下一张卡片到期再来。"
        }
        if model.deferredCount > 0 {
            return "今天还有 \(model.deferredCount) 张卡片待复习。"
        }
        return "能学的都学过了：没有待复习的，也没有新词可以开始了。"
    }

    private var statsGrid: some View {
        HStack(spacing: Spacing.xs) {
            StatTile(value: "\(model.reviewedCount)", label: "复习卡片")
            // No green tint on accuracy.
            //
            // The grade is a *self-report*, and colouring it as a success rewards the distribution
            // the user chose. On a screen shown after every session that is a slow nudge toward
            // pressing Good, and Good-inflation is the one failure mode that corrupts FSRS's input.
            // The completion count is what deserves the emphasis; it cannot be gamed.
            StatTile(
                value: model.accuracy.map { "\(Int($0 * 100))%" } ?? "—",
                label: "记住了"
            )
            StatTile(value: formattedDuration, label: "用时")
        }
    }

    private var formattedDuration: String {
        let seconds = model.elapsedSeconds
        if seconds < 60 { return "\(seconds) 秒" }
        let minutes = seconds / 60
        return minutes < 60 ? "\(minutes) 分钟" : "\(minutes / 60) 小时 \(minutes % 60) 分"
    }

    private var ratingBreakdown: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            SectionHeader("这次的表现")
            ForEach(Rating.allCases) { rating in
                let count = model.ratingCounts[rating] ?? 0
                HStack(spacing: Spacing.sm) {
                    // Wide enough for "Instant". The old 52 was sized for "Easy", and the
                    // labels grew when they stopped being scheduler vocabulary.
                    Text(rating.shortLabel)
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                        .frame(width: 64, alignment: .leading)

                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Palette.surfaceRaised)
                            Capsule()
                                .fill(Palette.rating(rating))
                                // Not optional. These bars are the reason `ratingEdge` exists: a
                                // 400-weight fill on `surfaceRaised` is 1.46:1 at worst, and a bar
                                // chart is a graphical object WCAG 1.4.11 holds to 3:1. The fill
                                // alone would have made the data unreadable in light mode.
                                .overlay(Capsule().strokeBorder(Palette.ratingEdge(rating), lineWidth: 1))
                                .frame(width: proxy.size.width * (barsRevealed ? share(count) : 0))
                        }
                    }
                    .frame(height: 10)

                    Text("\(count)")
                        .font(Typography.buttonInterval)
                        .foregroundStyle(Palette.textSecondary)
                        .frame(width: 28, alignment: .trailing)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(rating.shortLabel)：\(count)")
                // Staggered by rating so the four bars read as a sequence rather than a jump.
                .animation(
                    Motion.reveal(reduceMotion).delay(Double(rating.rawValue - 1) * 0.06),
                    value: barsRevealed
                )
            }
        }
    }

    private func share(_ count: Int) -> Double {
        // Scaled against the largest bucket rather than the total, so a session of mostly
        // `Good` still shows readable bars for the others.
        let peak = model.ratingCounts.values.max() ?? 0
        guard peak > 0 else { return 0 }
        return Double(count) / Double(peak)
    }
}
