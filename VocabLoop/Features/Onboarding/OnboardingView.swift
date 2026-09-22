import SwiftUI

/// Four questions, asked once, each of which changes what the app does.
///
/// Nothing is asked here that could be inferred or defaulted well — an onboarding flow
/// that collects information it does not use is pure friction. Every answer writes to
/// ``StudyPreferences`` and takes effect on the first Today screen.
///
/// Notification permission is *not* requested here. Asking before the user has any reason
/// to want reminders is how apps get permanently denied; the Settings toggle asks instead.
struct OnboardingView: View {
    let onFinish: () -> Void

    @Environment(\.appDependencies) private var dependencies
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step = 0

    @State private var language: LearningLanguage = .english
    @State private var level: CEFRLevel = .a1
    @State private var newWordsPerDay = 8

    /// Three, not four. The step this replaced asked the user to commit to a number of reviews
    /// per day *before they had seen a single card* — a decision nobody can make well at that
    /// point, and one the app then held them to. The goal now starts unset and lives in
    /// Settings, where it can be chosen by someone who knows what a review feels like.
    private let stepCount = 3

    var body: some View {
        VStack(spacing: Spacing.lg) {
            progressBar

            TabView(selection: $step) {
                languageStep.tag(0)
                levelStep.tag(1)
                summaryStep.tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .animation(Motion.phase(reduceMotion), value: step)

            controls
        }
        .padding(Spacing.md)
        .readableWidth()
        .screenBackground()
    }

    private var progressBar: some View {
        HStack(spacing: Spacing.xxs) {
            ForEach(0..<stepCount, id: \.self) { index in
                Capsule()
                    .fill(index <= step ? Palette.brandPrimary : Palette.surfaceRaised)
                    .frame(height: 4)
            }
        }
        .padding(.top, Spacing.md)
        .accessibilityLabel("Step \(step + 1) of \(stepCount)")
    }

    // MARK: - Steps

    private var languageStep: some View {
        OnboardingStep(
            title: "What are you learning?",
            subtitle: "English is fully stocked. French and Thai ship as starter packs for now."
        ) {
            VStack(spacing: Spacing.sm) {
                ForEach(LearningLanguage.allCases) { candidate in
                    SelectableRow(
                        isSelected: language == candidate,
                        title: "\(candidate.flagEmoji)  \(candidate.displayName)",
                        subtitle: candidate.isFullyStocked
                            ? candidate.endonym
                            : "\(candidate.endonym) · starter pack"
                    ) {
                        language = candidate
                    }
                }
            }
        }
    }

    private var levelStep: some View {
        OnboardingStep(
            title: "Where are you starting?",
            subtitle: "This sets which words you are offered. You can widen the range any time."
        ) {
            VStack(spacing: Spacing.sm) {
                ForEach([CEFRLevel.a1, .a2, .b1, .b2, .c1], id: \.self) { candidate in
                    SelectableRow(
                        isSelected: level == candidate,
                        title: "\(candidate.rawValue) · \(candidate.description)",
                        subtitle: nil
                    ) {
                        level = candidate
                    }
                }
            }
        }
    }

    private var summaryStep: some View {
        OnboardingStep(
            title: "Ready",
            subtitle: "Everything below can be changed in Settings."
        ) {
            VStack(spacing: Spacing.sm) {
                SummaryRow(label: "Learning", value: "\(language.flagEmoji) \(language.displayName)")
                SummaryRow(label: "Starting level", value: level.rawValue)
                SummaryRow(label: "New words per day", value: "\(newWordsPerDay)")
                SummaryRow(label: "Memory algorithm", value: SchedulerKind.fsrs5.displayName)
                SummaryRow(label: "Works offline", value: "Always")
            }
        }
    }

    /// Rough count so the "new words per day" dial has a visible consequence.
    ///
    /// Four reviews in the first month is what FSRS produces for a card answered `Good`
    /// each time — a real number rather than a scare figure.
    private var estimatedReviewsPerNewWord: Int { 4 }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: Spacing.sm) {
            if step > 0 {
                PrimaryButton("Back", role: .secondary) {
                    step -= 1
                }
                .frame(maxWidth: 120)
            }
            PrimaryButton(step == stepCount - 1 ? "Start learning" : "Continue") {
                if step == stepCount - 1 {
                    applyAndFinish()
                } else {
                    step += 1
                }
            }
        }
    }

    private func applyAndFinish() {
        if let preferences = dependencies.preferences {
            preferences.activeLanguage = language
            if !preferences.installedLanguageCodes.contains(language.rawValue) {
                preferences.installedLanguageCodes.append(language.rawValue)
            }
            preferences.cefrFloor = level
            // Offer a band rather than a single level: a learner at B1 still benefits from
            // A2 words they have not met, and being shown only C1 words at B1 is
            // demoralising.
            preferences.cefrCeiling = Self.ceiling(for: level)
            preferences.newWordsPerDay = newWordsPerDay
            dependencies.savePreferences()
        }
        Task {
            // The chosen language may not be the one imported at bootstrap.
            await dependencies.installLanguage(language)
            onFinish()
        }
    }

    /// One band above the declared level, capped at C2.
    static func ceiling(for level: CEFRLevel) -> CEFRLevel {
        let all = CEFRLevel.allCases
        guard let index = all.firstIndex(of: level) else { return .b2 }
        return all[min(index + 1, all.count - 1)]
    }
}

// MARK: - Building blocks

private struct OnboardingStep<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text(title)
                    .font(Typography.screenTitle)
                    .foregroundStyle(Palette.textPrimary)
                Text(subtitle)
                    .font(Typography.body)
                    .foregroundStyle(Palette.textSecondary)
                content
                    .padding(.top, Spacing.xs)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, Spacing.md)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

private struct SelectableRow: View {
    let isSelected: Bool
    let title: String
    let subtitle: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(Typography.bodyEmphasis)
                        .foregroundStyle(Palette.textPrimary)
                    if let subtitle {
                        Text(subtitle)
                            .font(Typography.caption)
                            .foregroundStyle(Palette.textSecondary)
                    }
                }
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Palette.brandPrimary : Palette.textTertiary)
                    .font(.title3)
            }
            .padding(Spacing.md)
            .frame(minHeight: LayoutMetrics.minimumTapTarget)
            .background(Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: Radius.nested, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.nested, style: .continuous)
                    .stroke(isSelected ? Palette.brandPrimary : Palette.separator, lineWidth: isSelected ? 2 : 1)
            )
        }
        .pressable(scale: 0.985)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}

private struct SummaryRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(Typography.body)
                .foregroundStyle(Palette.textSecondary)
            Spacer()
            Text(value)
                .font(Typography.bodyEmphasis)
                .foregroundStyle(Palette.textPrimary)
        }
        .padding(.vertical, Spacing.xs)
        .padding(.horizontal, Spacing.sm)
        .background(Palette.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: Radius.nested, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    OnboardingView(onFinish: {})
}
