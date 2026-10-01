import SwiftUI

/// Mochi with a level badge, built only from values.
///
/// Used by the share card and as the body of the 1.0.8 widgets (engagement plan
/// §1.12), which is why it takes plain values — a ``MochiLook`` and a level, both of which the
/// widget snapshot file carries — and reads nothing from the environment or the store.
struct WidgetMochiView: View {
    let look: MochiLook
    let level: Int
    var mood: Mascot.Mood = .happy
    /// `true` in the widget extension: widgets never animate, so Mochi does not breathe.
    var isStill = false

    var body: some View {
        VStack(spacing: Spacing.xs) {
            Mascot(mood: mood, look: look)
                .still(isStill)
            Text("Level \(level)")
                .font(Typography.chip)
                .foregroundStyle(Palette.onBrand)
                .padding(.horizontal, Spacing.xs)
                .padding(.vertical, Spacing.xxs)
                .background(Capsule().fill(Palette.brandPrimary))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Mochi, level \(level)")
    }
}

#Preview {
    WidgetMochiView(look: .default, level: 4)
        .frame(width: 160, height: 160)
}
