import SwiftUI

/// The combo and the candy jar, under the study screen's progress row.
///
/// The combo only appears from three in a row. One or two correct answers is not a run, and a
/// "🔥 1" on the first card would be a counter for its own sake. The candy pill is always there,
/// because candy is never lost: it is the number that only goes up, which is what makes an honest
/// *Forgot* feel free (engagement plan §1.1, §1.3).
struct ComboBanner: View {
    let combo: Int
    let candy: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Below this the combo is not shown at all.
    static let visibleFrom = 3

    var isComboVisible: Bool { combo >= Self.visibleFrom }

    var body: some View {
        HStack(spacing: Spacing.xs) {
            if isComboVisible {
                HStack(spacing: Spacing.xxs) {
                    Text("🔥")
                    Text("\(combo)")
                        .contentTransition(.numericText(value: Double(combo)))
                }
                .font(Typography.buttonLabel.monospacedDigit())
                .foregroundStyle(Palette.textPrimary)
                .padding(.horizontal, Spacing.xs)
                .padding(.vertical, 2)
                .background(Palette.brandSecondary.opacity(0.18), in: Capsule(style: .continuous))
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(Palette.brandSecondary.opacity(0.55), lineWidth: 1)
                )
                .transition(reduceMotion ? .opacity : .scale(scale: 0.6).combined(with: .opacity))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("连对 \(combo) 个")
            }

            Spacer(minLength: 0)

            HStack(spacing: Spacing.xxs) {
                Text("⭐")
                Text(candy.formatted())
                    .contentTransition(.numericText(value: Double(candy)))
            }
            .font(Typography.buttonInterval)
            .foregroundStyle(Palette.textSecondary)
            .padding(.horizontal, Spacing.xs)
            .padding(.vertical, 2)
            .background(Palette.surfaceRaised, in: Capsule(style: .continuous))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(candy.formatted()) 颗星星糖")
        }
        .animation(Motion.pop(reduceMotion), value: isComboVisible)
        .animation(Motion.value(reduceMotion), value: combo)
        .animation(Motion.value(reduceMotion), value: candy)
    }
}

#Preview {
    VStack(spacing: Spacing.md) {
        ComboBanner(combo: 0, candy: 12)
        ComboBanner(combo: 12, candy: 1_240)
    }
    .padding()
}
