import SwiftUI

// MARK: - Card container

/// The app's standard surface: rounded, one shadow level, `Spacing.md` padding.
public struct CardContainer<Content: View>: View {
    private let isRaised: Bool
    private let content: Content

    public init(isRaised: Bool = false, @ViewBuilder content: () -> Content) {
        self.isRaised = isRaised
        self.content = content()
    }

    public var body: some View {
        content
            .padding(Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isRaised ? Palette.surfaceRaised : Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .shadow(
                color: isRaised ? .clear : Elevation.shadowColor,
                radius: Elevation.shadowRadius,
                y: Elevation.shadowY
            )
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
            .frame(maxWidth: .infinity, minHeight: Layout.minimumTapTarget)
            .padding(.horizontal, Spacing.md)
            .foregroundStyle(foreground)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
        }
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
        .foregroundStyle(color)
        .background(color.opacity(0.14))
        .clipShape(RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
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
                .frame(minHeight: Layout.minimumTapTarget - 12)
                .foregroundStyle(isSelected ? Palette.onBrand : Palette.textSecondary)
                .background(isSelected ? Palette.brandPrimary : Palette.surfaceRaised)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
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

    public init(progress: Double, lineWidth: CGFloat = 12, tint: Color = Palette.brandPrimary) {
        self.progress = min(max(progress, 0), 1)
        self.lineWidth = lineWidth
        self.tint = tint
    }

    public var body: some View {
        ZStack {
            Circle()
                .stroke(Palette.surfaceRaised, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    tint,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.spring(duration: 0.6), value: progress)
        }
        .accessibilityHidden(true)
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
            Image(systemName: systemImage)
                .font(.system(size: 40))
                .foregroundStyle(Palette.textTertiary)
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
                    .frame(width: Layout.minimumTapTarget, height: Layout.minimumTapTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Pronounce \(text)")
        }
    }
}

// MARK: - Layout helper

extension View {
    /// Cap content width and centre it, so screens stay readable on iPad.
    public func readableWidth() -> some View {
        frame(maxWidth: Layout.maximumContentWidth)
            .frame(maxWidth: .infinity)
    }

    /// Standard screen background.
    public func screenBackground() -> some View {
        background(Palette.canvas.ignoresSafeArea())
    }
}
