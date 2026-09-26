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
    @State private var appeared = false

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.lg) {
                Spacer(minLength: Spacing.xl)

                VStack(spacing: Spacing.sm) {
                    ZStack {
                        if !isResting { SummaryBurst() }
                        Mascot(mood: isResting ? .sleepy : .cheer)
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
        .task { appeared = true }
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
