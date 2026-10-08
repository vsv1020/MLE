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
                            title: "还没有可显示的内容",
                            message: "在“今天”页添加几个单词，第一次复习后，你的进度就会出现在这里。"
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
            .navigationTitle("统计")
            .refreshable { reload() }
            .task { reload() }
        }
    }

    // MARK: - Retention

    private var retentionCard: some View {
        CardContainer(style: .crayon, wobbleSeed: 0x57A7_0001) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("记忆正确率")
                    .font(Typography.sectionHeader)
                HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                    Text(statistics.retentionLast30Days.map { "\(Int($0 * 100))%" } ?? "—")
                        .font(Typography.statValue)
                        .foregroundStyle(Palette.textPrimary)
                    Text("最近 30 天")
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
                Text("\(statistics.reviewsLast30Days) 次复习 · 平均每天 \(String(format: "%.0f", statistics.averageDailyReviews)) 次")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textTertiary)
            }
        }
    }

    private func retentionCommentary(actual: Double, target: Double) -> String {
        let delta = actual - target
        if abs(delta) <= 0.03 {
            return "正好达到你 \(Int(target * 100))% 的目标，复习安排很适合你。"
        }
        if delta > 0 {
            return "高于你 \(Int(target * 100))% 的目标。可以在“设置”里调低目标，用更少的复习达到同样的效果。"
        }
        return "低于你 \(Int(target * 100))% 的目标。在“设置”里调高目标，复习就会安排得更早。"
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
                        label: "分享我的连续打卡"
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
                    Text("连续打卡天数")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                }
                Divider().frame(height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(statistics.longestStreak)")
                        .font(Typography.statValueSmall)
                        .foregroundStyle(Palette.textPrimary)
                    Text("最长")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                }
                Spacer()
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("连续打卡 \(statistics.currentStreak) 天。最长 \(statistics.longestStreak) 天。")
        }
    }

    // MARK: - Forecast

    private var forecastCard: some View {
        CardContainer(style: .crayon, wobbleSeed: 0x57A7_0003) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                SectionHeader(
                    "接下来",
                    subtitle: "未来 30 天已安排的卡片"
                )
                Chart {
                    ForEach(statistics.forecast) { day in
                        // Stacked by maturity, so a wall of red learning cards reads
                        // differently from a wall of mature ones.
                        BarMark(
                            x: .value("天", day.dayOffset),
                            y: .value("卡片", day.learningCount)
                        )
                        .foregroundStyle(Palette.maturity(.learning))

                        BarMark(
                            x: .value("天", day.dayOffset),
                            y: .value("卡片", day.youngCount)
                        )
                        .foregroundStyle(Palette.maturity(.young))

                        BarMark(
                            x: .value("天", day.dayOffset),
                            y: .value("卡片", day.matureCount)
                        )
                        .foregroundStyle(Palette.maturity(.mature))
                    }
                }
                .chartXAxis {
                    AxisMarks(values: [0, 7, 14, 21, 29]) { value in
                        AxisValueLabel {
                            if let offset = value.as(Int.self) {
                                Text(offset == 0 ? "今天" : "+\(offset) 天")
                            }
                        }
                    }
                }
                .chartYAxis { AxisMarks(position: .leading) }
                .frame(height: 160)
                .accessibilityLabel("复习预测")
                .accessibilityValue(forecastSummary)

                legend
            }
        }
    }

    private var forecastSummary: String {
        let total = statistics.forecast.reduce(0) { $0 + $1.total }
        let peak = statistics.forecast.max { $0.total < $1.total }
        guard let peak else { return "没有安排卡片。" }
        return "30 天内共 \(total) 张卡片。最多的一天是\(peak.dayOffset == 0 ? "今天" : " \(peak.dayOffset) 天后")，有 \(peak.total) 张。"
    }

    private var legend: some View {
        HStack(spacing: Spacing.sm) {
            legendItem("学习中", .learning)
            legendItem("认识了", .young)
            legendItem("记得很牢", .mature)
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
                SectionHeader("复习记录", subtitle: "最近 12 个月")
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
                                    .accessibilityLabel("\(day.dayKey)：\(day.reviews) 次复习")
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
                Text("过去一年里有 \(statistics.heatmap.filter { $0.reviews > 0 }.count) 天在学习")
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
                SectionHeader("你的卡片", subtitle: "\(statistics.totalEnrolled) 张卡片")
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
                Text("“记得很牢”指复习间隔达到 \(Int(CardMaturity.matureThresholdDays)) 天或以上。")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textTertiary)
            }
        }
    }

    private func maturityLabel(_ maturity: CardMaturity) -> String {
        switch maturity {
        case .new: "未开始"
        case .learning: "学习中"
        case .young: "认识了"
        case .mature: "记得很牢"
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
