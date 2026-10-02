import SwiftUI

/// A choice question: a prompt and four drawn option buttons.
///
/// Shared by `multipleChoice`, `listenChoose` and `clozeChoose`, which differ only in the prompt.
/// After a tap the picked option turns green or red and the right one is *always* green, so a
/// wrong pick still ends on the correct answer — the thing worth remembering. Nothing advances on
/// its own; Continue is in the study screen's bottom bar (engagement plan §1.5).
struct MultipleChoiceView: View {
    let card: Card
    let question: Question
    let isAnswered: Bool
    let selectedOption: Int?
    let onPick: (Int) -> Void

    @Environment(\.appDependencies) private var dependencies
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var entry: Entry? { card.entry }

    private var language: LearningLanguage {
        entry?.language ?? dependencies.preferences?.activeLanguage ?? .english
    }

    var body: some View {
        VStack(alignment: .center, spacing: Spacing.md) {
            // The prompt steps aside once answered: the revealed card below repeats it with the
            // full answer, and keeping both would push that answer off a small screen.
            if !isAnswered {
                prompt
                    .frame(maxWidth: .infinity, alignment: .center)
                    .multilineTextAlignment(.center)
                    .transition(.opacity)
            }

            VStack(spacing: Spacing.xs) {
                ForEach(Array(question.options.enumerated()), id: \.element.id) { index, option in
                    optionButton(option, index: index)
                }
            }
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs)
        .readableWidth()
        .animation(Motion.reveal(reduceMotion), value: isAnswered)
    }

    // MARK: - Prompt

    @ViewBuilder
    private var prompt: some View {
        switch question.kind {
        case .listenChoose:
            VStack(spacing: Spacing.sm) {
                instruction("Listen and pick the word", systemImage: "ear")
                // A big target, because it is the whole question. The word is spoken once when
                // the card appears and again on every tap.
                Button {
                    speakAnswer()
                } label: {
                    Image(systemName: "speaker.wave.3.fill")
                        .font(.system(size: 40, weight: .semibold))
                        .foregroundStyle(Palette.brandPrimary)
                        .frame(width: 96, height: 96)
                        .background(Palette.brandPrimary.opacity(0.12), in: Circle())
                        .contentShape(Circle())
                }
                .pressable(scale: 0.92)
                .accessibilityLabel("Play the word again")
            }
            .task(id: question.cardID) { speakAnswer() }

        case .clozeChoose:
            VStack(spacing: Spacing.sm) {
                instruction("Pick the missing word", systemImage: "text.badge.checkmark")
                if let cloze = question.clozePrompt {
                    Text(cloze.masked)
                        .font(Typography.wordTitle)
                        .foregroundStyle(Palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        // A run of underscores is read out character by character; this says "blank".
                        .accessibilityLabel(cloze.accessibleMasked)
                }
            }

        case .multipleChoice, .flip, .typed:
            // `flip` and `typed` never reach this view; they get the headword prompt so the switch
            // stays exhaustive without a `default` that would hide a new kind.
            VStack(spacing: Spacing.xs) {
                instruction("What does it mean?", systemImage: "questionmark.bubble")
                HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                    Text(entry?.headword ?? "—")
                        .font(Typography.wordDisplay)
                        .foregroundStyle(Palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    SpeakerButton(text: entry?.headword ?? "", language: language, size: .title2)
                }
                if let pos = entry?.primarySense?.partOfSpeech {
                    Chip(pos.displayName)
                }
            }
        }
    }

    private func instruction(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(Typography.chip)
            .foregroundStyle(Palette.textTertiary)
    }

    private func speakAnswer() {
        guard !question.answerText.isEmpty else { return }
        dependencies.speech.speak(question.answerText, language: language)
    }

    // MARK: - Options

    private enum OptionState {
        case idle
        case correct
        case wrongPick
        case other
    }

    private func state(of index: Int) -> OptionState {
        guard isAnswered else { return .idle }
        if index == question.correctIndex { return .correct }
        if index == selectedOption { return .wrongPick }
        return .other
    }

    private func optionButton(_ option: QuestionOption, index: Int) -> some View {
        let state = self.state(of: index)
        let traits: AccessibilityTraits = (state == .correct || state == .wrongPick) ? .isSelected : []
        // Each option its own wobble, stable for this option on this card.
        let shape = WobbleShape(
            cornerRadius: Radius.button, amplitude: 0.8,
            seed: WobbleShape.seed(for: question.cardID + "|" + option.id)
        )
        return Button {
            onPick(index)
        } label: {
            HStack(spacing: Spacing.xs) {
                Text(option.text)
                    .font(Typography.buttonLabel)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let symbol = symbol(for: state) {
                    Image(systemName: symbol)
                        .font(.body.weight(.bold))
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
            .frame(maxWidth: .infinity, minHeight: LayoutMetrics.minimumTapTarget + 8)
            .foregroundStyle(foreground(for: state))
            .background(fill(for: state))
            .clipShape(shape)
            .overlay(shape.stroke(edge(for: state), lineWidth: state == .correct ? 3 : 2))
            .opacity(state == .other ? 0.55 : 1)
        }
        .buttonStyle(SquishButtonStyle(base: shape, baseColor: baseColor(for: state)))
        // Answered options stay readable but stop responding: one answer per question.
        .allowsHitTesting(!isAnswered)
        .accessibilityLabel("Option \(index + 1): \(option.text)")
        .accessibilityIdentifier(optionIdentifier(index))
        .accessibilityValue(accessibilityValue(for: state))
        .accessibilityAddTraits(traits)
        // 1–4 on a hardware keyboard, matching the rating bar's shortcuts.
        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [])
    }

    /// `quiz.option.<index>`. A debug build names the right answer `quiz.option.correct`, so the
    /// App Store screenshot test can tap it; VoiceOver never reads identifiers.
    private func optionIdentifier(_ index: Int) -> String {
        #if DEBUG
        if index == question.correctIndex { return "quiz.option.correct" }
        #endif
        return "quiz.option.\(index)"
    }

    private func symbol(for state: OptionState) -> String? {
        switch state {
        case .correct: return "checkmark.circle.fill"
        case .wrongPick: return "xmark.circle.fill"
        case .idle, .other: return nil
        }
    }

    private func accessibilityValue(for state: OptionState) -> String {
        switch state {
        case .correct: "Correct answer"
        case .wrongPick: "Your answer, not quite"
        case .idle, .other: ""
        }
    }

    /// Green is `Palette.success` with light ink; red is the Forgot button's own fill with its dark
    /// ink, so "wrong" looks exactly like the honest *Forgot* it will be graded as — no new,
    /// harsher red.
    private func fill(for state: OptionState) -> Color {
        switch state {
        case .idle, .other: Palette.surface
        case .correct: Palette.success
        case .wrongPick: Palette.rating(.again)
        }
    }

    private func foreground(for state: OptionState) -> Color {
        switch state {
        case .idle, .other: Palette.textPrimary
        case .correct: Palette.onBrand
        case .wrongPick: Palette.onRating
        }
    }

    private func edge(for state: OptionState) -> Color {
        switch state {
        case .idle, .other: Palette.separator
        case .correct: Palette.success
        case .wrongPick: Palette.ratingEdge(.again)
        }
    }

    private func baseColor(for state: OptionState) -> Color {
        switch state {
        case .idle, .other: Chunky.baseColor
        case .correct: Palette.success.opacity(0.6)
        case .wrongPick: Palette.ratingEdge(.again)
        }
    }
}
