import SwiftUI

/// One of today's new words.
///
/// Shows enough to make a genuine decision — word, pronunciation, part of speech, definition,
/// translation and one example — because "add this to your studies?" is unanswerable from a
/// headword alone.
struct DailyWordCard: View {
    let entry: Entry
    let isAccepted: Bool
    let onAccept: () -> Void
    let onDismiss: () -> Void

    @Environment(\.appDependencies) private var dependencies

    private var language: LearningLanguage {
        entry.language ?? dependencies.preferences?.activeLanguage ?? .english
    }

    private var nativeCodes: [String] {
        dependencies.preferences?.nativeLanguageCodes ?? ["en"]
    }

    var body: some View {
        CardContainer(style: .crayon, wobbleSeed: 0x_DA11_0001) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                headerRow

                if let sense = entry.primarySense {
                    Text(sense.definition)
                        .font(Typography.body)
                        .foregroundStyle(Palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let translation = sense.translation(preferring: nativeCodes) {
                        Text(translation)
                            .font(Typography.body)
                            .foregroundStyle(Palette.textSecondary)
                    }

                    if let example = sense.examples.first {
                        exampleView(example)
                    }
                }

                Spacer(minLength: 0)
                actions
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private var headerRow: some View {
        HStack(alignment: .top, spacing: Spacing.xs) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.headword)
                    .font(Typography.wordTitle)
                    .foregroundStyle(Palette.textPrimary)
                HStack(spacing: Spacing.xxs) {
                    if let phonetic = entry.phonetic, dependencies.preferences?.showPhonetics != false {
                        Text(phonetic)
                            .font(Typography.phonetic)
                            .foregroundStyle(Palette.textSecondary)
                    }
                    if let pos = entry.primarySense?.partOfSpeech {
                        Chip(pos.abbreviation)
                    }
                    if let cefr = entry.cefr {
                        Chip(cefr.rawValue, color: Palette.brandSecondary)
                    }
                }
            }
            Spacer()
            SpeakerButton(text: entry.headword, language: language)
        }
    }

    private func exampleView(_ example: ExampleSentence) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(example.text)
                .font(Typography.example)
                .italic()
                .foregroundStyle(Palette.textPrimary)
            if let translation = example.translation(preferring: nativeCodes) {
                Text(translation)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
            }
        }
        .padding(Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: Radius.nested, style: .continuous))
    }

    private var actions: some View {
        HStack(spacing: Spacing.sm) {
            if isAccepted {
                Label("Added to your words", systemImage: "checkmark.circle.fill")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.success)
                    .frame(maxWidth: .infinity, minHeight: LayoutMetrics.minimumTapTarget)
            } else {
                PrimaryButton("Add", systemImage: "plus", action: onAccept)
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: LayoutMetrics.minimumTapTarget, height: LayoutMetrics.minimumTapTarget)
                        .foregroundStyle(Palette.textSecondary)
                        .background(Palette.surfaceRaised)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
                }
                .pressable(scale: 0.9)
                .accessibilityLabel("Skip \(entry.headword). It will not be offered again.")
            }
        }
    }
}
