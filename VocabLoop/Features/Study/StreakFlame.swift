import SwiftUI

/// The streak, in the study screen's top bar.
///
/// Grey until today's first review, then lit, with a small hop and a "+1" the moment it lights
/// (engagement plan §1.2). Grey is a *waiting* colour, not a warning: there is no red, no
/// countdown and no "at risk" wording here, because a flame that scolds a child at breakfast for
/// not having studied yet is the opposite of an invitation.
struct StreakFlame: View {
    /// Current streak in days. `0` shows a grey flame with no number.
    let streak: Int
    /// Today's first review has landed.
    let isLit: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHopping = false
    @State private var isShowingPlusOne = false

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "flame.fill")
                .foregroundStyle(isLit ? Palette.brandSecondary : Palette.textTertiary)
                .offset(y: isHopping ? -5 : 0)
            if streak > 0 {
                Text("\(streak)")
                    .contentTransition(.numericText(value: Double(streak)))
                    .foregroundStyle(isLit ? Palette.brandSecondary : Palette.textTertiary)
            }
        }
        .font(Typography.buttonInterval)
        .overlay(alignment: .top) {
            if isShowingPlusOne {
                Text("+1")
                    .font(Typography.chip)
                    .foregroundStyle(Palette.brandSecondary)
                    .offset(y: -14)
                    .transition(.opacity.combined(with: .offset(y: 4)))
                    .accessibilityHidden(true)
            }
        }
        .animation(Motion.value(reduceMotion), value: streak)
        .animation(Motion.value(reduceMotion), value: isLit)
        .onChange(of: isLit) { wasLit, nowLit in
            guard !wasLit, nowLit else { return }
            celebrate()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        guard streak > 0 else { return isLit ? "Studied today" : "No streak yet" }
        let days = "\(streak)-day streak"
        return isLit ? "\(days), studied today" : "\(days), not studied yet today"
    }

    /// The hop and the "+1". The colour change alone carries the meaning, so under Reduce Motion
    /// the hop is skipped and the "+1" only fades.
    private func celebrate() {
        if !reduceMotion {
            withAnimation(Motion.pop(false)) { isHopping = true }
        }
        withAnimation(Motion.value(reduceMotion)) { isShowingPlusOne = true }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(260))
            withAnimation(Motion.pop(reduceMotion)) { isHopping = false }
            try? await Task.sleep(for: .milliseconds(900))
            withAnimation(Motion.value(reduceMotion)) { isShowingPlusOne = false }
        }
    }
}

#Preview {
    HStack(spacing: Spacing.lg) {
        StreakFlame(streak: 0, isLit: false)
        StreakFlame(streak: 4, isLit: false)
        StreakFlame(streak: 5, isLit: true)
    }
    .padding()
}
