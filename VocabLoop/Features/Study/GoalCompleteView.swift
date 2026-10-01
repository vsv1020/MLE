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

                    Text(isResting ? "See you tomorrow" : "Daily goal complete 🎉")
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
                        StatTile(value: "\(model.reviewsToday)", label: "Today")
                        StatTile(
                            value: model.accuracy.map { "\(Int($0 * 100))%" } ?? "—",
                            label: "Recalled"
                        )
                        StatTile(value: formattedDuration, label: "Time")
                    }

                    rewardsRow

                    if offersWeeklyRecap {
                        Button {
                            isShowingRecap = true
                        } label: {
                            Label("See your week", systemImage: "calendar")
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
                }

                Spacer(minLength: Spacing.lg)

                VStack(spacing: Spacing.sm) {
                    if isResting {
                        PrimaryButton("Study a bit more", systemImage: "arrow.right", action: onContinue)
                    } else {
                        PrimaryButton("Done for today", systemImage: "checkmark", action: onDone)
                        PrimaryButton("Keep going", role: .secondary, action: onContinue)
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
                            Button("Done") { isShowingRecap = false }
                        }
                    }
            }
        }
    }

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
            Chip("\(streak)-day streak", color: Palette.brandSecondary, systemImage: "flame.fill")
        }
        Chip("Mochi level \(level)", color: Palette.brandPrimary, systemImage: "heart.fill")
        Chip("\(candyTotal.formatted()) star candy", color: Palette.brandSecondary, systemImage: "star.fill")
    }

    private func loadEngagement() {
        let engagement = dependencies.engagement
        if let profile = try? engagement.profile() {
            level = profile.level
            candyTotal = profile.candyTotal
        }
        look = engagement.currentLook()
        guard let preferences = dependencies.preferences else { return }
        let now = Date()
        streak = (try? engagement.streak(preferences: preferences, now: now).current) ?? 0

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
            return "Today's \(model.goalTarget ?? model.reviewsToday) cards are done. Anything extra is a bonus — it will all still be here."
        }
        return "\(model.reviewsToday) cards today. Stop here, or keep going — extra reviews still count toward remembering."
    }

    private var formattedDuration: String {
        let seconds = model.elapsedSeconds
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        return minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h \(minutes % 60)m"
    }
}
