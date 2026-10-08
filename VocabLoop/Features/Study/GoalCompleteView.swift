import SwiftUI

/// Shown once, on the card that meets today's goal.
///
/// The session underneath is endless, which is right for someone who wants to keep going and
/// wrong for someone who set a goal *so that* they would know when to stop — to them "34 / 30"
/// with the next card already up reads as the app not noticing. So the goal gets its moment, and
/// both answers are offered with equal standing: stopping is not the lesser choice.
///
/// "Done for today" does not close anything at the root, because there is nothing behind it. It
/// turns this screen into a resting state instead, which still has a way back in.
struct GoalCompleteView: View {
    let model: StudyViewModel
    let onContinue: () -> Void
    let onDone: () -> Void

    /// `true` after "Done for today" at the root.
    var isResting = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appDependencies) private var dependencies
    @State private var appeared = false

    // MARK: Engagement (1.0.7)

    /// Read once when the screen appears; the goal screen is a moment, not a live readout.
    @State private var streak = 0
    @State private var level = 1
    @State private var candyTotal = 0
    @State private var look: MochiLook = .default
    /// Decided once on appearance so the chip does not vanish while it is being looked at.
    @State private var offersWeeklyRecap = false
    @State private var isShowingRecap = false
    /// The study day the goal was met on, for the share card's file name.
    @State private var dayKey = ShareCard.dayKey(for: Date())
    /// `true` once Mochi's look and level are read, so the share card is rendered once, right.
    @State private var didLoadEngagement = false

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.lg) {
                Spacer(minLength: Spacing.xl)

                VStack(spacing: Spacing.sm) {
                    ZStack {
                        if !isResting { SummaryBurst() }
                        Mascot(mood: isResting ? .sleepy : .cheer, look: look)
                            .frame(width: 104, height: 86)
                            .scaleEffect(appeared || isResting ? 1 : 0.6)
                    }
                    .frame(width: 160, height: 160)
                    .clipped()

                    Text(isResting ? "明天见" : "今日目标完成 🎉")
                        .accessibilityIdentifier("goal.title")
                        .font(Typography.screenTitle)
                        .foregroundStyle(Palette.textPrimary)
                        .multilineTextAlignment(.center)
                    Text(subtitle)
                        .font(Typography.body)
                        .foregroundStyle(Palette.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .animation(Motion.celebrate(reduceMotion), value: appeared)

                if !isResting {
                    HStack(spacing: Spacing.xs) {
                        StatTile(value: "\(model.reviewsToday)", label: "今天")
                        StatTile(
                            value: model.accuracy.map { "\(Int($0 * 100))%" } ?? "—",
                            label: "记住了"
                        )
                        StatTile(value: formattedDuration, label: "用时")
                    }

                    rewardsRow

                    // "See your week" and "Share today" side by side where they fit.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: Spacing.sm) { celebrationActions }
                        VStack(spacing: Spacing.sm) { celebrationActions }
                    }
                }

                Spacer(minLength: Spacing.lg)

                VStack(spacing: Spacing.sm) {
                    if isResting {
                        PrimaryButton("再学一会儿", systemImage: "arrow.right", action: onContinue)
                    } else {
                        PrimaryButton("今天就到这里", systemImage: "checkmark", action: onDone)
                        PrimaryButton("继续背", role: .secondary, action: onContinue)
                    }
                }
            }
            .padding(Spacing.md)
            .readableWidth()
        }
        .task {
            appeared = true
            loadEngagement()
        }
        .sheet(isPresented: $isShowingRecap) {
            NavigationStack {
                WeeklyRecapView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完成") { isShowingRecap = false }
                        }
                    }
            }
        }
    }

    @ViewBuilder
    private var celebrationActions: some View {
        if offersWeeklyRecap {
            Button {
                isShowingRecap = true
            } label: {
                Label("看看这一周", systemImage: "calendar")
                    .font(Typography.bodyEmphasis)
                    .foregroundStyle(Palette.brandPrimary)
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, Spacing.xs)
                    .background(Capsule().fill(Palette.brandPrimary.opacity(0.12)))
                    .overlay(Capsule().strokeBorder(Palette.brandPrimary.opacity(0.4), lineWidth: 1.5))
                    .tappableArea()
            }
            .pressable()
        }
        if didLoadEngagement {
            ShareCardButton(card: .goalComplete(goalCard), label: "分享今天")
        }
    }

    /// Today's goal as a share card: counts and Mochi only, nothing that names the child.
    private var goalCard: GoalCard {
        GoalCard(
            reviewsToday: model.reviewsToday,
            dailyGoal: model.goalTarget ?? model.reviewsToday,
            streak: streak,
            minutes: sessionMinutes,
            look: look,
            level: level,
            dayKey: dayKey
        )
    }

    /// Whole minutes, rounded up so a two-minute sprint never reads as zero. Read once with the
    /// rest of the card: a ticking clock would re-render the image every second.
    @State private var sessionMinutes = 0

    /// Streak, Mochi's level and the star candy so far — what today added up to.
    private var rewardsRow: some View {
        // One line where it fits, stacked at large text sizes rather than truncated.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Spacing.xs) { rewardChips }
            VStack(spacing: Spacing.xs) { rewardChips }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var rewardChips: some View {
        if streak > 0 {
            Chip("连续打卡 \(streak) 天", color: Palette.brandSecondary, systemImage: "flame.fill")
        }
        Chip("麻薯 \(level) 级", color: Palette.brandPrimary, systemImage: "heart.fill")
        Chip("\(candyTotal.formatted()) 颗星星糖", color: Palette.brandSecondary, systemImage: "star.fill")
    }

    private func loadEngagement() {
        let engagement = dependencies.engagement
        if let profile = try? engagement.profile() {
            level = profile.level
            candyTotal = profile.candyTotal
        }
        look = engagement.currentLook()
        sessionMinutes = (model.elapsedSeconds + 59) / 60
        guard let preferences = dependencies.preferences else {
            didLoadEngagement = true
            return
        }
        let now = Date()
        streak = (try? engagement.streak(preferences: preferences, now: now).current) ?? 0
        dayKey = StudyCalendar(preferences: preferences).dayKey(for: now)
        didLoadEngagement = true

        // "See your week", once per calendar week, and only on the celebration — not on the
        // resting screen, which is about stopping.
        guard !isResting else { return }
        let defaults = UserDefaults.standard
        let week = RecapNudge.weekKey(for: now, timeZone: preferences.timeZone)
        let seen = defaults.string(forKey: RecapNudge.seenWeekKey)
        if RecapNudge.shouldOffer(currentWeekKey: week, seenWeekKey: seen) {
            offersWeeklyRecap = true
            defaults.set(week, forKey: RecapNudge.seenWeekKey)
        }
    }

    private var subtitle: String {
        if isResting {
            return "今天的 \(model.goalTarget ?? model.reviewsToday) 张卡片都学完了。再多学就是额外收获，卡片都还在这儿。"
        }
        return "今天学了 \(model.reviewsToday) 张卡片。可以停在这里，也可以继续背，多复习的也有助于记住。"
    }

    private var formattedDuration: String {
        let seconds = model.elapsedSeconds
        if seconds < 60 { return "\(seconds) 秒" }
        let minutes = seconds / 60
        return minutes < 60 ? "\(minutes) 分钟" : "\(minutes / 60) 小时 \(minutes % 60) 分"
    }
}
