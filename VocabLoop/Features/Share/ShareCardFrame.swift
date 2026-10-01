import SwiftUI

/// Size of every share image. Not actor-bound, so layout and tests can read it anywhere.
///
/// 360×450 pt rendered at 3× is 1080×1350 px: 4:5 portrait, the size Messages and Instagram show
/// uncropped.
enum ShareCardMetrics {
    /// Layout size in points.
    static let pointSize = CGSize(width: 360, height: 450)
    /// Render scale: 360×450 pt → 1080×1350 px.
    static let scale: CGFloat = 3

    /// The image size every share card is rendered at.
    static var pixelSize: CGSize {
        CGSize(width: pointSize.width * scale, height: pointSize.height * scale)
    }

    /// How far the crayon border sits inside the image edge.
    static let borderInset: CGFloat = 10
}

/// The shared layout of every share card (sharing plan §2): paper, a crayon border seeded by the
/// card's kind, eyebrow, headline, Mochi, the card's own middle, and a fixed footer with the app
/// name, one invite line and the App Store link.
///
/// Always drawn light and at a fixed text size by ``ShareCardRenderer``: it is an image that
/// leaves the app and must look the same wherever it lands.
struct ShareCardFrame<Middle: View>: View {
    /// The Mochi at the top of the card.
    enum Hero {
        /// Mochi with the level capsule, `height` points tall.
        case mochi(look: MochiLook, level: Int, mood: Mascot.Mood, height: CGFloat)
        /// No hero: the card's middle draws its own Mochi (the word card needs the room).
        case none
    }

    private let kind: ShareCard.Kind
    private let headline: Text
    private let hero: Hero
    private let middle: Middle

    init(kind: ShareCard.Kind, headline: Text, hero: Hero, @ViewBuilder middle: () -> Middle) {
        self.kind = kind
        self.headline = headline
        self.hero = hero
        self.middle = middle()
    }

    init(kind: ShareCard.Kind, headline: String, hero: Hero, @ViewBuilder middle: () -> Middle) {
        self.init(kind: kind, headline: Text(headline), hero: hero, middle: middle)
    }

    private var seed: UInt64 { WobbleShape.seed(for: "share-" + kind.rawValue) }

    var body: some View {
        VStack(spacing: Spacing.sm) {
            VStack(spacing: Spacing.xxs) {
                HStack(spacing: Spacing.xxs) {
                    Image(systemName: "sparkles")
                    Text(ShareCopy.eyebrow(kind))
                }
                .font(Typography.caption)
                .foregroundStyle(Palette.brandSecondary)

                headline
                    .font(Typography.screenTitle)
                    .foregroundStyle(Palette.textPrimary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .minimumScaleFactor(0.7)
            }

            heroView

            middle

            Spacer(minLength: Spacing.xs)

            footer
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.md + ShareCardMetrics.borderInset / 2)
        .frame(width: ShareCardMetrics.pointSize.width, height: ShareCardMetrics.pointSize.height)
        .background { paper }
    }

    @ViewBuilder
    private var heroView: some View {
        switch hero {
        case let .mochi(look, level, mood, height):
            WidgetMochiView(look: look, level: level, mood: mood)
                .frame(width: height * 1.05, height: height)
        case .none:
            EmptyView()
        }
    }

    private var paper: some View {
        let border = WobbleShape(cornerRadius: Radius.card, amplitude: 1.3, seed: seed)
            .inset(by: ShareCardMetrics.borderInset)
        return ZStack {
            Palette.canvas
            PaperGrain(density: 900, seed: seed)
            border.stroke(Palette.separator, lineWidth: 3)
        }
    }

    private var footer: some View {
        VStack(spacing: 2) {
            HStack(spacing: Spacing.xxs) {
                Text(ShareCopy.appName)
                    .font(Typography.sectionHeader)
                    .foregroundStyle(Palette.brandPrimary)
                Text("·")
                    .foregroundStyle(Palette.textTertiary)
                Text(ShareCopy.invite)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            Text(ShareCopy.appStoreShortLink)
                .font(Typography.chip)
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(1)
        }
    }
}

/// A small fact on a card: an icon and a few words in a drawn capsule.
struct ShareStatChip: View {
    let text: String
    let systemImage: String

    var body: some View {
        HStack(spacing: Spacing.xxs) {
            Image(systemName: systemImage)
                .foregroundStyle(Palette.brandSecondary)
            Text(text)
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .font(Typography.caption)
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xxs + 2)
        .background(Capsule().fill(Palette.surfaceRaised))
        .overlay(Capsule().strokeBorder(Palette.separator.opacity(0.5), lineWidth: 1.5))
    }
}
