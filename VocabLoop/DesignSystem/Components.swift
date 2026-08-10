import SwiftUI

// MARK: - Card container

/// The app's standard surface: rounded, one shadow level, `Spacing.md` padding.
public struct CardContainer<Content: View>: View {
    /// How the card sits on the page.
    public enum Style {
        /// A soft blurred shadow. The original, and still the default.
        case flat
        /// A hard offset edge with no blur, plus a visible outline — cel-shaded rather than lit.
        ///
        /// This is where the "too dry" brief gets the most character per line: a blurred shadow
        /// says *photographic*, a hard one says *drawn*. It also fixes a real bug. `Elevation`'s
        /// shadow is `Color.black.opacity(0.08)` — one fixed value, not an adaptive colour — so on
        /// the `#0B1120` dark canvas it is entirely invisible and dark mode has had **no depth cue
        /// at all**. A token-based edge is visible in both appearances.
        case sticker
    }

    private let isRaised: Bool
    private let style: Style
    private let content: Content

    /// `style` defaults to `.flat` so every existing call site renders pixel-for-pixel as before,
    /// and the new look is opted into rather than inflicted.
    public init(
        isRaised: Bool = false,
        style: Style = .flat,
        @ViewBuilder content: () -> Content
    ) {
        self.isRaised = isRaised
        self.style = style
        self.content = content()
    }

    public var body: some View {
        content
            .padding(Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isRaised ? Palette.surfaceRaised : Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .overlay {
                if style == .sticker {
                    RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                        .strokeBorder(Palette.separator, lineWidth: 1.5)
                }
            }
            // The two shadows are exclusive, never stacked. Leaving the soft one underneath a hard
            // one turns the cel-shaded edge into mud, which is the usual way this look is got wrong.
            .shadow(
                color: shadowColor,
                radius: style == .sticker ? 0 : Elevation.shadowRadius,
                y: style == .sticker ? 3 : Elevation.shadowY
            )
    }

    private var shadowColor: Color {
        switch style {
        // An opacity on an existing token, not a new hex — `Palette` stays closed, and unlike
        // `Elevation.shadowColor` this one adapts, so the edge survives dark mode.
        case .sticker: Palette.textTertiary.opacity(0.28)
        case .flat: isRaised ? .clear : Elevation.shadowColor
        }
    }
}

// MARK: - Press feedback

/// Acknowledges a touch the moment it lands.
///
/// Every custom button in this app used `.buttonStyle(.plain)`, which does more than remove the
/// blue tint — it removes SwiftUI's press response entirely. Nothing replaced it, so there was no
/// `scaleEffect`, no opacity change and no style reading `isPressed` anywhere in the project. Taps
/// were acknowledged by haptics and by whatever the action changed, and by nothing on screen in
/// between. On the rating bar, which a user presses hundreds of times a day, that reads as the app
/// being slow rather than as the app being still.
///
/// Deliberately understated: a 3% scale and a small opacity drop. A control the user hits this
/// often should feel responsive, not springy — a bouncy animation is charming twice and tiring by
/// the fiftieth card.
public struct PressableButtonStyle: ButtonStyle {
    private let pressedScale: CGFloat
    private let pressedOpacity: Double

    /// - Parameters:
    ///   - pressedScale: Shrink while held. Values below about 0.94 start to read as a glitch on
    ///     a wide button, because the edges travel further than the eye expects.
    ///   - pressedOpacity: Dim while held. Carries the whole effect when Reduce Motion is on.
    public init(pressedScale: CGFloat = 0.97, pressedOpacity: Double = 0.9) {
        self.pressedScale = pressedScale
        self.pressedOpacity = pressedOpacity
    }

    public func makeBody(configuration: Configuration) -> some View {
        Body(
            configuration: configuration,
            pressedScale: pressedScale,
            pressedOpacity: pressedOpacity
        )
    }

    /// A nested `View` rather than reading the environment in `makeBody`.
    ///
    /// `makeBody` is not a `View` body, so `@Environment` declared on the style itself is not
    /// reliably populated — the accessibility setting would silently read as its default and
    /// Reduce Motion would do nothing.
    private struct Body: View {
        let configuration: ButtonStyleConfiguration
        let pressedScale: CGFloat
        let pressedOpacity: Double

        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                // Scale *is* motion, so Reduce Motion drops it and keeps the dimming. The
                // feedback survives; only the movement goes.
                .scaleEffect(shouldScale ? pressedScale : 1)
                .opacity(configuration.isPressed ? pressedOpacity : 1)
                .animation(Motion.press(reduceMotion), value: configuration.isPressed)
        }

        private var shouldScale: Bool {
            configuration.isPressed && !reduceMotion && isEnabled
        }
    }
}

public extension View {
    /// Standard press feedback. Replaces `.buttonStyle(.plain)` on custom button labels.
    func pressable(scale: CGFloat = 0.97, opacity: Double = 0.9) -> some View {
        buttonStyle(PressableButtonStyle(pressedScale: scale, pressedOpacity: opacity))
    }

    /// Extend the tappable area to at least `side`, without changing what is drawn.
    ///
    /// For a control whose visual size is deliberately small — a filter capsule should read as a
    /// chip, not a button — this buys the 44pt target the Human Interface Guidelines ask for while
    /// the drawn shape keeps its own size. Applied *after* the background and clip shape, so the
    /// frame grows around the artwork rather than stretching it.
    ///
    /// One honest cost: the row containing the control gets taller. A 32pt chip in a 44pt frame
    /// adds 12pt of height wherever it sits. That is the trade for a compliant target, and in a
    /// horizontally scrolling filter row a missed tap silently changes the results — which is worse
    /// than 12pt.
    func tappableArea(_ side: CGFloat = LayoutMetrics.minimumTapTarget) -> some View {
        frame(minHeight: side)
            .contentShape(Rectangle())
    }
}

// MARK: - Buttons

/// Filled primary action.
///
/// Enforces the 44pt minimum height itself, so no call site can accidentally ship a
/// 30pt-tall button.
public struct PrimaryButton: View {
    private let title: String
    private let systemImage: String?
    private let isLoading: Bool
    private let isEnabled: Bool
    private let role: Role
    private let action: () -> Void

    public enum Role {
        case primary
        case secondary
        case destructive
    }

    public init(
        _ title: String,
        systemImage: String? = nil,
        isLoading: Bool = false,
        isEnabled: Bool = true,
        role: Role = .primary,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.isLoading = isLoading
        self.isEnabled = isEnabled
        self.role = role
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.xs) {
                if isLoading {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(foreground)
                } else if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(title)
                    .font(Typography.buttonLabel)
            }
            .frame(maxWidth: .infinity, minHeight: LayoutMetrics.minimumTapTarget)
            .padding(.horizontal, Spacing.md)
            .foregroundStyle(foreground)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
        }
        .pressable()
        .disabled(!isEnabled || isLoading)
        .opacity(isEnabled ? 1 : 0.45)
        // Announce the loading state rather than leaving VoiceOver reading a button that
        // silently does nothing.
        .accessibilityLabel(isLoading ? "\(title). Working." : title)
    }

    private var foreground: Color {
        switch role {
        case .primary: Palette.onBrand
        case .secondary: Palette.brandPrimary
        case .destructive: .white
        }
    }

    private var background: Color {
        switch role {
        case .primary: Palette.brandPrimary
        case .secondary: Palette.brandPrimary.opacity(0.12)
        case .destructive: Palette.danger
        }
    }
}

// MARK: - Chips

/// Small metadata pill: CEFR level, part of speech, tag.
public struct Chip: View {
    /// Strength of the tint behind the label.
    ///
    /// `internal`, not private, so `PaletteContrastTests` measures the value the component
    /// actually draws. A duplicated literal in the test would keep passing after this changed,
    /// which is precisely how the 2.52:1 chip survived.
    static let fillOpacity: Double = 0.22

    /// Strength of the edge. Redundant reinforcement of the label, so it is allowed below 3:1.
    static let borderOpacity: Double = 0.55

    private let text: String
    private let color: Color
    private let systemImage: String?

    public init(_ text: String, color: Color = Palette.textSecondary, systemImage: String? = nil) {
        self.text = text
        self.color = color
        self.systemImage = systemImage
    }

    public var body: some View {
        HStack(spacing: Spacing.xxs) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.caption2)
            }
            Text(text)
                .font(Typography.chip)
        }
        .padding(.horizontal, Spacing.xs)
        .padding(.vertical, Spacing.xxs)
        // `textPrimary`, not `color`.
        //
        // Drawing `color` on `color.opacity(0.14)` was a real WCAG failure that shipped, and the
        // contrast suite could not see it: the suite measures a tone against `surface`,
        // `canvas` and `surfaceRaised`, and this chip's actual background is none of those — it is
        // a tint of the foreground itself, composited over one of them. Eight of the twelve
        // token/appearance combinations came in under 4.5:1, the worst being light `warning` at
        // **2.52:1** — and these chips render on the flashcard, carrying part of speech, register
        // and synonyms. A reading surface.
        //
        // Dark ink on a stronger tint clears 8.49:1 at worst. The hue survives as the fill and as
        // the border, so nothing is lost but the illegibility.
        .foregroundStyle(Palette.textPrimary)
        .background(color.opacity(Self.fillOpacity))
        .clipShape(RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
        // Redundant reinforcement, never a sole signal: the text already carries the meaning, so
        // this edge is allowed to sit below 1.4.11's 3:1 for the palest tokens.
        .overlay(
            RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                .strokeBorder(color.opacity(Self.borderOpacity), lineWidth: 1)
        )
    }
}

/// Toggleable filter chip for the Browse screen.
public struct FilterChip: View {
    private let title: String
    private let isSelected: Bool
    private let action: () -> Void

    public init(_ title: String, isSelected: Bool, action: @escaping () -> Void) {
        self.title = title
        self.isSelected = isSelected
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Text(title)
                .font(Typography.caption)
                .padding(.horizontal, Spacing.sm)
                .frame(minHeight: LayoutMetrics.minimumTapTarget - 12)
                .foregroundStyle(isSelected ? Palette.onBrand : Palette.textSecondary)
                .background(isSelected ? Palette.brandPrimary : Palette.surfaceRaised)
                .clipShape(Capsule())
                // A ring, not just a fill. Selection carried by colour alone disappears for a
                // colour-blind user and washes out in sunlight; the border survives both.
                .overlay(
                    Capsule().strokeBorder(
                        isSelected ? Palette.brandPrimary : Palette.separator,
                        lineWidth: isSelected ? 0 : 1
                    )
                )
                // The capsule stays 32pt because it should read as a chip. The *target* is 44pt,
                // which is what the guidelines actually ask for — filters sit in a scrolling row
                // and a 32pt target there is a missed tap that silently changes the results.
                .tappableArea()
        }
        .pressable(scale: 0.94)
        // A coloured background is not a state VoiceOver can see; the trait is what makes
        // the filter usable without sight.
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}

// MARK: - Progress ring

/// Circular progress with a value in the middle. The primary call to action on Today.
public struct ProgressRing: View {
    private let progress: Double
    private let lineWidth: CGFloat
    private let tint: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(progress: Double, lineWidth: CGFloat = 12, tint: Color = Palette.brandPrimary) {
        self.progress = min(max(progress, 0), 1)
        self.lineWidth = lineWidth
        self.tint = tint
    }

    public var body: some View {
        // `GeometryReader` only because the head dot needs the radius, and the ring does not own
        // its size — every caller sets its own `.frame`.
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let radius = (side - lineWidth) / 2

            ZStack {
                Circle()
                    .stroke(Palette.surfaceRaised, lineWidth: lineWidth)

                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(sweep, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))

                // The bead at the leading edge. Rotating a bare `Circle()` would spin it about its
                // own centre and leave it stacked on the count in the middle of the ring, so it is
                // offset to the rim *inside* the rotated container.
                if progress > 0.02 {
                    Circle()
                        .fill(Palette.brandSecondary)
                        .frame(width: lineWidth * 0.62, height: lineWidth * 0.62)
                        .offset(y: -radius)
                        .rotationEffect(.degrees(360 * progress))
                }
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(Motion.progress(reduceMotion), value: progress)
        }
        .accessibilityHidden(true)
    }

    /// Indigo → teal → indigo around the full circle.
    ///
    /// Spans 0…360 rather than −90…270. The trimmed circle already carries
    /// `.rotationEffect(.degrees(-90))` to start the arc at twelve o'clock, and an angular gradient
    /// rotates with it — so a −90 start would drag the gradient's origin round to nine o'clock and
    /// render the ring's *beginning* in teal instead of the brand colour.
    ///
    /// Both endpoints already clear 4.5:1 as text on every surface, so every colour between them
    /// clears 1.4.11's 3:1 requirement for a non-text fill. No new hex, so `Palette` stays closed.
    private var sweep: AngularGradient {
        AngularGradient(
            colors: [tint, Palette.brandSecondary, tint],
            center: .center,
            startAngle: .degrees(0),
            endAngle: .degrees(360)
        )
    }
}

// MARK: - Stat tile

/// One number with a label. Used in a row of three on Today and Progress.
public struct StatTile: View {
    private let value: String
    private let label: String
    private let tint: Color
    private let systemImage: String?

    public init(value: String, label: String, tint: Color = Palette.textPrimary, systemImage: String? = nil) {
        self.value = value
        self.label = label
        self.tint = tint
        self.systemImage = systemImage
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            HStack(spacing: Spacing.xxs) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.caption)
                        .foregroundStyle(tint)
                }
                Text(value)
                    .font(Typography.statValueSmall)
                    .foregroundStyle(tint)
            }
            Text(label)
                .font(Typography.caption)
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(2, reservesSpace: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.sm)
        .background(Palette.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: Radius.nested, style: .continuous))
        // Read as one phrase; the number and label separately are meaningless.
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }
}

// MARK: - Empty state

/// Every empty state names the action that resolves it. Never a bare "No data".
public struct EmptyStateView: View {
    private let systemImage: String
    private let title: String
    private let message: String
    private let actionTitle: String?
    private let action: (() -> Void)?

    public init(
        systemImage: String,
        title: String,
        message: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.systemImage = systemImage
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        VStack(spacing: Spacing.sm) {
            // A plate, not a bare 40pt glyph.
            //
            // The size was one of seven hard-coded `.system(size:)` values, all now
            // ``Typography/heroGlyph``. The colour was the worse half: `textTertiary` on `canvas`
            // is the palest pairing in the whole system, so an empty state — the one screen with
            // nothing else to look at — was drawn in the faintest ink available. A tinted disc
            // gives it presence without a new token.
            Image(systemName: systemImage)
                .font(Typography.heroGlyph)
                .foregroundStyle(Palette.brandPrimary)
                .frame(width: 84, height: 84)
                .background(Palette.brandPrimary.opacity(0.12), in: Circle())
                .overlay(Circle().strokeBorder(Palette.brandPrimary.opacity(0.28), lineWidth: 1.5))
            Text(title)
                .font(Typography.sectionHeader)
                .foregroundStyle(Palette.textPrimary)
            Text(message)
                .font(Typography.body)
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
            if let actionTitle, let action {
                PrimaryButton(actionTitle, role: .secondary, action: action)
                    .frame(maxWidth: 260)
                    .padding(.top, Spacing.xs)
            }
        }
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Section header

public struct SectionHeader: View {
    private let title: String
    private let subtitle: String?
    private let actionTitle: String?
    private let action: (() -> Void)?

    public init(
        _ title: String,
        subtitle: String? = nil,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Typography.sectionHeader)
                    .foregroundStyle(Palette.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                }
            }
            Spacer()
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.brandPrimary)
            }
        }
    }
}

// MARK: - Maturity dot

/// Learning-status indicator for Browse rows.
public struct MaturityDot: View {
    private let maturity: CardMaturity

    public init(_ maturity: CardMaturity) {
        self.maturity = maturity
    }

    public var body: some View {
        Circle()
            .fill(Palette.maturity(maturity))
            .frame(width: 8, height: 8)
            // Colour alone conveys nothing to VoiceOver, and "young" vs "mature" is not
            // obvious from a dot even with sight.
            .accessibilityLabel(label)
    }

    private var label: String {
        switch maturity {
        case .new: "Not started"
        case .learning: "Learning"
        case .young: "Known, still consolidating"
        case .mature: "Well known"
        }
    }
}

// MARK: - Speaker button

/// Pronunciation button. Hides itself when no voice for the language is installed rather
/// than offering a control that silently does nothing.
public struct SpeakerButton: View {
    private let text: String
    private let language: LearningLanguage
    private let size: Font

    @Environment(\.appDependencies) private var dependencies

    public init(text: String, language: LearningLanguage, size: Font = .title3) {
        self.text = text
        self.language = language
        self.size = size
    }

    public var body: some View {
        if dependencies.speech.isSupported(language) {
            Button {
                dependencies.speech.speak(text, language: language)
            } label: {
                Image(systemName: "speaker.wave.2.fill")
                    .font(size)
                    .foregroundStyle(Palette.brandPrimary)
                    .frame(width: LayoutMetrics.minimumTapTarget, height: LayoutMetrics.minimumTapTarget)
                    .contentShape(Rectangle())
            }
            .pressable(scale: 0.9)
            .accessibilityLabel("Pronounce \(text)")
        }
    }
}

// MARK: - Layout helper

extension View {
    /// Cap content width and centre it, so screens stay readable on iPad.
    public func readableWidth() -> some View {
        frame(maxWidth: LayoutMetrics.maximumContentWidth)
            .frame(maxWidth: .infinity)
    }

    /// Standard screen background.
    public func screenBackground() -> some View {
        background(Palette.canvas.ignoresSafeArea())
    }
}
