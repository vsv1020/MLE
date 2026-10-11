import SwiftUI

/// The language being studied, on the root study screen: "🇬🇧 英语".
///
/// It exists because a switch used to be invisible. The queue follows the active language, and
/// nothing on the card screen said which one that was — so a mis-tap in Settings, or a child
/// exploring, turned an English learner's next card into Thai with no clue why. Now the answer is
/// on screen, and one tap away from being undone.
///
/// Drawn like the candy pill beside it: a quiet capsule, not a button shouting for attention. The
/// tap target reaches past the drawing so the row it sits in does not grow.
struct LanguageChip: View {
    let language: LearningLanguage
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.xxs) {
                Text(language.flagEmoji)
                Text(language.displayName)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Palette.textTertiary)
            }
            .font(Typography.buttonInterval)
            .foregroundStyle(Palette.textSecondary)
            .padding(.horizontal, Spacing.xs)
            .padding(.vertical, 2)
            .background(Palette.surfaceRaised, in: Capsule(style: .continuous))
            // About 44pt tall to a finger, without making the combo row 44pt tall to the eye.
            .contentShape(Rectangle().inset(by: -10))
        }
        .pressable(scale: 0.94)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("正在学\(language.displayName)，点按切换")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("study.language")
    }
}

/// The compact picker behind ``LanguageChip``. Switching goes through
/// ``AppDependencies/switchLanguage(to:)`` — exactly what Settings ▸ 语言 does.
struct LanguageSwitcherSheet: View {
    /// Called once the new language is active, so the session can rebuild its queue for it.
    let onSwitched: () -> Void

    @Environment(\.appDependencies) private var dependencies
    @Environment(\.dismiss) private var dismiss
    @State private var installing: LearningLanguage?

    var body: some View {
        NavigationStack {
            List {
                if let preferences = dependencies.preferences {
                    Section {
                        ForEach(LearningLanguage.allCases) { language in
                            let isActive = preferences.activeLanguage == language
                            Button {
                                choose(language, preferences: preferences)
                            } label: {
                                LanguageOptionRow(
                                    language: language,
                                    isActive: isActive,
                                    isInstalling: installing == language
                                )
                            }
                            // One switch at a time: a second tap mid-import would race the first.
                            .disabled(installing != nil)
                            .accessibilityAddTraits(isActive ? [.isSelected, .isButton] : .isButton)
                        }
                    } footer: {
                        Text("每种语言的进度都会保留。")
                    }
                }
            }
            .navigationTitle("切换学习语言")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                        .disabled(installing != nil)
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(installing != nil)
    }

    private func choose(_ language: LearningLanguage, preferences: StudyPreferences) {
        // Picking the language already active is "never mind", not a rebuild of the queue.
        guard preferences.activeLanguage != language else {
            dismiss()
            return
        }
        installing = language
        Task {
            await dependencies.switchLanguage(to: language)
            installing = nil
            onSwitched()
            dismiss()
        }
    }
}

/// One language in a picker: flag, Chinese name, endonym, and a tick or a spinner. Shared by
/// Settings ▸ 语言 and ``LanguageSwitcherSheet`` so the two lists cannot drift apart.
struct LanguageOptionRow: View {
    let language: LearningLanguage
    let isActive: Bool
    let isInstalling: Bool

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Text(language.flagEmoji)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(language.displayName)
                    .foregroundStyle(Palette.textPrimary)
                Text(language.isFullyStocked
                    ? language.endonym
                    : "\(language.endonym) · 入门词库")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
            }
            Spacer()
            if isInstalling {
                ProgressView()
            } else if isActive {
                Image(systemName: "checkmark")
                    .foregroundStyle(Palette.brandPrimary)
            }
        }
    }
}

#Preview {
    VStack(spacing: Spacing.md) {
        ForEach(LearningLanguage.allCases) { language in
            LanguageChip(language: language) {}
        }
    }
    .sheet(isPresented: .constant(true)) {
        LanguageSwitcherSheet {}
    }
}
