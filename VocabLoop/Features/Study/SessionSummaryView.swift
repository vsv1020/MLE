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
    /// `phase` becomes `.finished` on three paths that reviewed nothing: the `catch` in
    /// `StudyViewModel.start`, its `guard let preferences` early return, and `skipCurrent` after a
    /// bury or suspend. Without this gate, burying your last card fires confetti, and a store
    /// failure fires confetti behind an error.
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
                        Image(systemName: didStudy ? "checkmark.seal.fill" : "sparkles")
                            // A token, not `size: 52`. The seal is the reward for finishing a
                            // session; it should grow with Dynamic Type like everything else.
                            .font(Typography.heroGlyph)
                            .foregroundStyle(Palette.success)
                            .scaleEffect(appeared || !didStudy ? 1 : 0.6)
                            .symbolEffect(
                                .bounce.up,
                                options: .nonRepeating,
                                // Not trusted to honour the setting on its own.
                                value: reduceMotion ? 0 : (appeared ? 1 : 0)
                            )
                    }
                    .frame(width: 160, height: 160)
                    .clipped()

                    Text(didStudy ? "Session complete" : "Nothing due")
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
                PrimaryButton("Done", action: onDone)
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

    private var subtitle: String {
        guard model.reviewedCount > 0 else {
            return "You are caught up. Come back when the next card is ready, or study ahead from Today."
        }
        if model.deferredCount > 0 {
            return "\(model.deferredCount) more card\(model.deferredCount == 1 ? "" : "s") are still due today."
        }
        return "That is everything due for now."
    }

    private var statsGrid: some View {
        HStack(spacing: Spacing.xs) {
            StatTile(value: "\(model.reviewedCount)", label: "Cards reviewed")
            // No green tint on accuracy.
            //
            // The grade is a *self-report*, and colouring it as a success rewards the distribution
            // the user chose. On a screen shown after every session that is a slow nudge toward
            // pressing Good, and Good-inflation is the one failure mode that corrupts FSRS's input.
            // The completion count is what deserves the emphasis; it cannot be gamed.
            StatTile(
                value: model.accuracy.map { "\(Int($0 * 100))%" } ?? "—",
                label: "Recalled"
            )
            StatTile(value: formattedDuration, label: "Time")
        }
    }

    private var formattedDuration: String {
        let seconds = model.elapsedSeconds
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        return minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h \(minutes % 60)m"
    }

    private var ratingBreakdown: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            SectionHeader("How it went")
            ForEach(Rating.allCases) { rating in
                let count = model.ratingCounts[rating] ?? 0
                HStack(spacing: Spacing.sm) {
                    Text(rating.shortLabel)
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                        .frame(width: 52, alignment: .leading)

                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Palette.surfaceRaised)
                            Capsule()
                                .fill(Palette.rating(rating))
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
                .accessibilityLabel("\(rating.shortLabel): \(count)")
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
