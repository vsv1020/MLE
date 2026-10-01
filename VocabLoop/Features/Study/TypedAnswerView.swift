import SwiftUI

/// A typed question: the meaning (or a sentence with a blank) is shown, the word is typed.
///
/// Only production and cloze cards are asked this way — they already ask for the word, so typing
/// it is the same question with stronger evidence. Matching ignores case, spacing and accents
/// (``TypedAnswerMatcher``): the keyboard is not the test. "I don't know" is always offered, so a
/// child who cannot recall the word is never left guessing at letters to move on.
struct TypedAnswerView: View {
    let card: Card
    let question: Question
    let isAnswered: Bool
    /// What was submitted, once answered.
    let typedAnswer: String?
    let onSubmit: (String) -> Void
    let onGiveUp: () -> Void

    @Environment(\.appDependencies) private var dependencies
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var text = ""
    @FocusState private var isFieldFocused: Bool

    private var entry: Entry? { card.entry }

    private var nativeCodes: [String] {
        dependencies.preferences?.nativeLanguageCodes ?? ["en"]
    }

    private var trimmed: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .center, spacing: Spacing.md) {
            if isAnswered {
                result
                    .transition(.opacity)
            } else {
                prompt
                    .frame(maxWidth: .infinity, alignment: .center)
                    .multilineTextAlignment(.center)
                field
                HStack(spacing: Spacing.xs) {
                    PrimaryButton("I don't know", role: .secondary) {
                        onGiveUp()
                    }
                    PrimaryButton("Check", isEnabled: !trimmed.isEmpty) {
                        submit()
                    }
                }
            }
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs)
        .readableWidth()
        .animation(Motion.reveal(reduceMotion), value: isAnswered)
        // The same card can come back (undo), and must not come back holding the old attempt.
        .onChange(of: isAnswered) { _, answered in
            if !answered { text = "" }
        }
        .task(id: question.cardID) {
            // A beat after the card lands, so the keyboard does not race the card's transition.
            try? await Task.sleep(for: .milliseconds(350))
            if !isAnswered { isFieldFocused = true }
        }
    }

    // MARK: - Prompt

    @ViewBuilder
    private var prompt: some View {
        VStack(spacing: Spacing.xs) {
            Label("Type the word", systemImage: "keyboard")
                .font(Typography.chip)
                .foregroundStyle(Palette.textTertiary)
            if let cloze = question.clozePrompt {
                Text(cloze.masked)
                    .font(Typography.wordTitle)
                    .foregroundStyle(Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(cloze.accessibleMasked)
                Text(entry?.primaryDefinition ?? "")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(entry?.primaryDefinition ?? "—")
                    .font(Typography.wordTitle)
                    .foregroundStyle(Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let translation = entry?.primarySense?.translation(preferring: nativeCodes) {
                    Text(translation)
                        .font(Typography.body)
                        .foregroundStyle(Palette.textSecondary)
                }
            }
            if let pos = entry?.primarySense?.partOfSpeech {
                Chip(pos.displayName)
            }
        }
    }

    private var field: some View {
        TextField("Type the word", text: $text)
            .font(Typography.wordTitle)
            .multilineTextAlignment(.center)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.done)
            .focused($isFieldFocused)
            .onSubmit {
                if !trimmed.isEmpty { submit() }
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
            .frame(minHeight: LayoutMetrics.minimumTapTarget + 8)
            .background {
                let shape = WobbleShape(
                    cornerRadius: Radius.button, amplitude: 0.8,
                    seed: WobbleShape.seed(for: card.cardID) &+ 0x7E7E
                )
                shape.fill(Palette.surface)
                    .overlay(shape.stroke(Palette.separator, lineWidth: 2))
            }
            .accessibilityLabel("Your answer")
    }

    private func submit() {
        isFieldFocused = false
        onSubmit(trimmed)
    }

    // MARK: - Result

    /// What was typed against the word, in words as well as colour.
    private var result: some View {
        let quality = TypedAnswerMatcher.match(typed: typedAnswer ?? "", answer: question.answerText)
        let headline: String
        let tint: Color
        let symbol: String
        switch quality {
        case .exact:
            headline = "You got it!"
            tint = Palette.success
            symbol = "checkmark.circle.fill"
        case .nearMiss:
            headline = "So close! It's spelled \(question.answerText)."
            tint = Palette.success
            symbol = "checkmark.circle"
        case .wrong:
            // Kind, never "wrong": the next line is the word itself, which is the useful part.
            headline = (typedAnswer ?? "").isEmpty ? "Here's the word:" : "Not quite — the word is:"
            tint = Palette.brandSecondary
            symbol = "lightbulb.fill"
        }
        return VStack(spacing: Spacing.xxs) {
            HStack(spacing: Spacing.xs) {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
                Text(headline)
                    .font(Typography.bodyEmphasis)
                    .foregroundStyle(Palette.textPrimary)
                    .multilineTextAlignment(.center)
            }
            if quality == .wrong {
                Text(question.answerText)
                    .font(Typography.wordTitle)
                    .foregroundStyle(Palette.brandPrimary)
            }
            if let typedAnswer, !typedAnswer.isEmpty, quality != .exact {
                Text("You typed: \(typedAnswer)")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}
