import SwiftUI

/// End of session.
///
/// Reports what happened without grading the user. No "you could do better", no comparison to
/// yesterday — a session that ends in a scolding is a session people stop starting.
struct SessionSummaryView: View {
    let model: StudyViewModel
    let onDone: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.lg) {
                Spacer(minLength: Spacing.xl)

                VStack(spacing: Spacing.sm) {
                    Image(systemName: model.reviewedCount > 0 ? "checkmark.circle.fill" : "sparkles")
                        .font(.system(size: 52))
                        .foregroundStyle(Palette.success)
                    Text(model.reviewedCount > 0 ? "Session complete" : "Nothing due")
                        .font(Typography.screenTitle)
                        .foregroundStyle(Palette.textPrimary)
                    Text(subtitle)
                        .font(Typography.body)
                        .foregroundStyle(Palette.textSecondary)
                        .multilineTextAlignment(.center)
                }

                if model.reviewedCount > 0 {
                    statsGrid
                    ratingBreakdown
                }

                Spacer(minLength: Spacing.lg)
                PrimaryButton("Done", action: onDone)
            }
            .padding(Spacing.md)
            .readableWidth()
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
            StatTile(
                value: model.accuracy.map { "\(Int($0 * 100))%" } ?? "—",
                label: "Recalled",
                tint: Palette.success
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
                                .frame(width: proxy.size.width * share(count))
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
