import SwiftUI

/// Size of every share image. Not actor-bound, so layout and tests can read it anywhere.
///
/// 360×480 pt rendered at 3× is 1080×1440 px: a 3:4 portrait poster, the shape 小红书 shows
/// uncropped and WeChat Moments opens full screen without cutting anything off.
enum ShareCardMetrics {
    /// Layout size in points.
    static let pointSize = CGSize(width: 360, height: 480)
    /// Render scale: 360×480 pt → 1080×1440 px.
    static let scale: CGFloat = 3

    /// The image size every share card is rendered at.
    static var pixelSize: CGSize {
        CGSize(width: pointSize.width * scale, height: pointSize.height * scale)
    }

    /// How far the crayon border sits inside the image edge.
    static let borderInset: CGFloat = 10

    /// The QR code's side in the footer, quiet zone included: 228 px in the image, about six
    /// pixels per module — comfortably above what WeChat's long-press recogniser needs.
    static let qrSide: CGFloat = 76
}

/// The shared layout of every share poster (sharing plan §2): paper, a crayon border seeded by
/// the card's kind, eyebrow and headline at the top, the hero (Mochi) and the card's own middle
/// centred in the space between, and a footer band at the bottom with the app's mark, name,
/// slogan, how to find it, and a QR code to the China App Store page.
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

    /// Who is sharing, set by ``ShareCardRenderer``; `nil` prints no name.
    @Environment(\.shareSharerName) private var sharerName

    private var seed: UInt64 { WobbleShape.seed(for: "share-" + kind.rawValue) }

    var body: some View {
        VStack(spacing: 0) {
            header

            Spacer(minLength: Spacing.sm)

            VStack(spacing: Spacing.sm) {
                heroView
                middle
            }

            Spacer(minLength: Spacing.sm)

            footer
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.top, ShareCardMetrics.borderInset + Spacing.md)
        .padding(.bottom, ShareCardMetrics.borderInset + Spacing.sm)
        .frame(width: ShareCardMetrics.pointSize.width, height: ShareCardMetrics.pointSize.height)
        .background { paper }
    }

    private var header: some View {
        VStack(spacing: Spacing.xxs) {
            if let sharerName {
                sharerBadge(sharerName)
            }
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
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The sharer's initial in a brand circle, then their name.
    private func sharerBadge(_ name: String) -> some View {
        HStack(spacing: Spacing.xs) {
            Text(String(name.prefix(1)).uppercased())
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(Palette.onBrand)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Palette.brandPrimary))
            Text(name)
                .font(Typography.sectionHeader)
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.bottom, Spacing.xxs)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var heroView: some View {
        switch hero {
        case let .mochi(look, level, mood, height):
            WidgetMochiView(look: look, level: level, mood: mood, isStill: true)
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

    /// The band that turns a card into an invitation: who made it, what it is, how to get it.
    /// No printed URL — on Moments and 小红书 nobody can tap or would type one; the QR code is
    /// what a reader acts on.
    private var footer: some View {
        HStack(alignment: .center, spacing: Spacing.sm) {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                HStack(spacing: Spacing.xs) {
                    Image("AppLogo")
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 30, height: 30)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .accessibilityHidden(true)
                    Text(ShareCopy.appName)
                        .font(Typography.sectionHeader)
                        .foregroundStyle(Palette.brandPrimary)
                        .lineLimit(1)
                }
                Text(ShareCopy.slogan)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(ShareCopy.qrHint)
                    .font(Typography.chip)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            ShareQRCodeView(side: ShareCardMetrics.qrSide)
        }
        .padding(Spacing.xs)
        .padding(.leading, Spacing.xxs)
        .drawnPanel(seed: WobbleShape.seed(for: "share-footer-" + kind.rawValue))
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

/// The name of the person sharing a poster. ``ShareCardRenderer`` sets it; ``ShareCardFrame``
/// prints it at the top when it is not `nil`.
private struct ShareSharerNameKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    var shareSharerName: String? {
        get { self[ShareSharerNameKey.self] }
        set { self[ShareSharerNameKey.self] = newValue }
    }
}
