import SwiftUI
import Charts

/// Progress.
///
/// Everything here is computed locally from ``ReviewLog`` and ``StudyDay`` — no server, no
/// network, and identical whether or not the user has an account.
struct StatsView: View {
    @Environment(\.appDependencies) private var dependencies
    @State private var statistics: StudyStatistics = .empty
    @State private var isLoading = true
    /// The rolling seven-day recap (engagement plan §1.9). `nil` until loaded or if it fails —
    /// the rest of Progress never waits on it.
    @State private var recap: WeeklyRecap?
    /// Mochi as they look now and their level, for the streak share card.
    @State private var look: MochiLook = .default
    @State private var level = 1

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    if isLoading {
                        ProgressView().frame(maxWidth: .infinity)
                    } else if statistics.totalEnrolled == 0 {
                        EmptyStateView(
                            systemImage: "chart.bar",
                            title: "Nothing to show yet",
                            message: "Add a few words from Today, and your progress will appear here after the first review."
                        )
                    } else {
                        if let recap {
                            WeeklyRecapCard(recap: recap)
                        }
                        retentionCard
                        streakCard
                        forecastCard
                        heatmapCard
                        collectionCard
                    }
                }
                .padding(Spacing.md)
                .readableWidth()
            }
            .screenBackground()
            .navigationTitle("Progress")
            .refreshable { reload() }
            .task { reload() }
        }
    }

    // MARK: - Retention

    private var retentionCard: some View {
        CardContainer(style: .crayon, wobbleSeed: 0x57A7_0001) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Recall accuracy")
                    .font(Typography.sectionHeader)
                HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                    Text(statistics.retentionLast30Days.map { "\(Int($0 * 100))%" } ?? "—")
                        .font(Typography.statValue)
                        .foregroundStyle(Palette.textPrimary)
                    Text("last 30 days")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                }
                // Compare against what the user asked for, not against 100%. Someone targeting
                // 90% who scores 89% is on target, and telling them otherwise would push them
                // toward over-reviewing.
                if let retention = statistics.retentionLast30Days,
                   let target = dependencies.preferences?.desiredRetention {
                    Text(retentionCommentary(actual: retention, target: target))
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("\(statistics.reviewsLast30Days) reviews · \(String(format: "%.0f", statistics.averageDailyReviews)) per day on average")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textTertiary)
            }
        }
    }

    private func retentionCommentary(actual: Double, target: Double) -> String {
        let delta = actual - target
        if abs(delta) <= 0.03 {
            return "Right on your \(Int(target * 100))% target — the scheduler is well calibrated for you."
        }
        if delta > 0 {
            return "Above your \(Int(target * 100))% target. You could lower the target in Settings to see fewer reviews for the same result."
        }
        return "Below your \(Int(target * 100))% target. Raising it in Settings will schedule reviews sooner."
    }

    // MARK: - Streak

    private var streakCard: some View {
        CardContainer(style: .crayon, wobbleSeed: 0x57A7_0002) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                streakNumbers
                // Offered from three days: one or two is not yet a habit worth posting.
                if statistics.currentStreak >= StreakCard.minimumToShare {
                    ShareCardButton(
                        card: .streak(StreakCard(
                            streak: statistics.currentStreak,
                            longest: statistics.longestStreak,
                            look: look,
                            level: level
                        )),
                        label: "Share my streak"
                    )
                }
            }
        }
    }

    private var streakNumbers: some View {
        Group {
            HStack(spacing: Spacing.md) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: Spacing.xxs) {
                        Image(systemName: "flame.fill")
                            .foregroundStyle(Palette.brandSecondary)
                        Text("\(statistics.currentStreak)")
                            .font(Typography.statValue)
                            .foregroundStyle(Palette.textPrimary)
                    }
                    Text("day streak")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                }
                Divider().frame(height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(statistics.longestStreak)")
                        .font(Typography.statValueSmall)
                        .foregroundStyle(Palette.textPrimary)
                    Text("longest")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                }
                Spacer()
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(statistics.currentStreak) day streak. Longest: \(statistics.longestStreak) days.")
        }
    }

    // MARK: - Forecast

    private var forecastCard: some View {
        CardContainer(style: .crayon, wobbleSeed: 0x57A7_0003) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                SectionHeader(
                    "Coming up",
                    subtitle: "Cards already scheduled over the next 30 days"
                )
                Chart {
                    ForEach(statistics.forecast) { day in
                        // Stacked by maturity, so a wall of red learning cards reads
                        // differently from a wall of mature ones.
                        BarMark(
                            x: .value("Day", day.dayOffset),
                            y: .value("Cards", day.learningCount)
                        )
                        .foregroundStyle(Palette.maturity(.learning))

                        BarMark(
                            x: .value("Day", day.dayOffset),
                            y: .value("Cards", day.youngCount)
                        )
                        .foregroundStyle(Palette.maturity(.young))

                        BarMark(
                            x: .value("Day", day.dayOffset),
                            y: .value("Cards", day.matureCount)
                        )
                        .foregroundStyle(Palette.maturity(.mature))
                    }
                }
                .chartXAxis {
                    AxisMarks(values: [0, 7, 14, 21, 29]) { value in
                        AxisValueLabel {
                            if let offset = value.as(Int.self) {
                                Text(offset == 0 ? "Today" : "+\(offset)d")
                            }
                        }
                    }
                }
                .chartYAxis { AxisMarks(position: .leading) }
                .frame(height: 160)
                .accessibilityLabel("Review forecast")
                .accessibilityValue(forecastSummary)

                legend
            }
        }
    }

    private var forecastSummary: String {
        let total = statistics.forecast.reduce(0) { $0 + $1.total }
        let peak = statistics.forecast.max { $0.total < $1.total }
        guard let peak else { return "No cards scheduled." }
        return "\(total) cards over 30 days. Busiest day is \(peak.dayOffset == 0 ? "today" : "in \(peak.dayOffset) days") with \(peak.total)."
    }

    private var legend: some View {
        HStack(spacing: Spacing.sm) {
            legendItem("Learning", .learning)
            legendItem("Known", .young)
            legendItem("Well known", .mature)
        }
        .accessibilityHidden(true)
    }

    private func legendItem(_ label: String, _ maturity: CardMaturity) -> some View {
        HStack(spacing: Spacing.xxs) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Palette.maturity(maturity))
                .frame(width: 10, height: 10)
            Text(label)
                .font(Typography.chip)
                .foregroundStyle(Palette.textSecondary)
        }
    }

    // MARK: - Heatmap

    private var heatmapCard: some View {
        CardContainer(style: .crayon, wobbleSeed: 0x57A7_0004) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                SectionHeader("Review history", subtitle: "Last 12 months")
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        // Seven rows, one per weekday, filled column by column — the layout every
                        // contribution graph uses, and the only one that fits a year on a phone.
                        LazyHGrid(rows: Array(repeating: GridItem(.fixed(12), spacing: 3), count: 7), spacing: 3) {
                            ForEach(statistics.heatmap) { day in
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Palette.heatmapLevel(day.reviews, max: heatmapPeak))
                                    .frame(width: 12, height: 12)
                                    .id(day.dayKey)
                                    .accessibilityLabel("\(day.dayKey): \(day.reviews) reviews")
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .onAppear {
                        // Land on today, not on twelve months ago.
                        if let last = statistics.heatmap.last {
                            proxy.scrollTo(last.dayKey, anchor: .trailing)
                        }
                    }
                }
                Text("\(statistics.heatmap.filter { $0.reviews > 0 }.count) active days in the last year")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textTertiary)
            }
        }
    }

    private var heatmapPeak: Int {
        max(statistics.heatmap.map(\.reviews).max() ?? 1, 1)
    }

    // MARK: - Collection

    private var collectionCard: some View {
        CardContainer(style: .crayon, wobbleSeed: 0x57A7_0005) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                SectionHeader("Your collection", subtitle: "\(statistics.totalEnrolled) cards")
                ForEach(CardMaturity.allCases, id: \.self) { maturity in
                    let count = statistics.countsByMaturity[maturity] ?? 0
                    HStack(spacing: Spacing.sm) {
                        MaturityDot(maturity)
                        Text(maturityLabel(maturity))
                            .font(Typography.body)
                            .foregroundStyle(Palette.textPrimary)
                        Spacer()
                        Text("\(count)")
                            .font(Typography.bodyEmphasis)
                            .monospacedDigit()
                            .foregroundStyle(Palette.textSecondary)
                    }
                    .accessibilityElement(children: .combine)
                }
                Text("“Well known” means an interval of \(Int(CardMaturity.matureThresholdDays)) days or more.")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textTertiary)
            }
        }
    }

    private func maturityLabel(_ maturity: CardMaturity) -> String {
        switch maturity {
        case .new: "Not started"
        case .learning: "Learning"
        case .young: "Known"
        case .mature: "Well known"
        }
    }

    private func reload() {
        guard let account = dependencies.account, let preferences = account.preferences else {
            isLoading = false
            return
        }
        statistics = (try? dependencies.stats.statistics(for: account, preferences: preferences)) ?? .empty
        recap = try? dependencies.recap.recap(for: account, preferences: preferences, endingAt: Date())
        let engagement = dependencies.engagement
        look = engagement.currentLook()
        if let profile = try? engagement.profile() {
            level = profile.level
        }
        isLoading = false
    }
}

#Preview {
    StatsView()
}
