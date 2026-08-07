import SwiftUI

/// One card, front or revealed.
///
/// The prompt stays exactly where it is when the answer appears. A layout that jumps on
/// reveal forces the user to re-find what they were reading, and it is the fastest way to make
/// a review session feel unpleasant.
struct FlashcardView: View {
    let card: Card
    let isAnswerRevealed: Bool
    let reduceMotion: Bool

    @Environment(\.appDependencies) private var dependencies

    private var entry: Entry? { card.entry }

    private var language: LearningLanguage {
        entry?.language ?? dependencies.preferences?.activeLanguage ?? .english
    }

    private var nativeCodes: [String] {
        dependencies.preferences?.nativeLanguageCodes ?? ["en"]
    }

    private var showPhonetics: Bool {
        dependencies.preferences?.showPhonetics ?? true
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.md) {
                prompt
                if isAnswerRevealed {
                    answer
                        .transition(
                            reduceMotion
                                ? .opacity
                                : .opacity.combined(with: .offset(y: 4))
                        )
                }
            }
            .padding(Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .readableWidth()
        }
        .animation(
            reduceMotion ? .easeInOut(duration: 0.2) : .easeOut(duration: 0.3),
            value: isAnswerRevealed
        )
        .scrollBounceBehavior(.basedOnSize)
    }

    // MARK: - Front

    @ViewBuilder
    private var prompt: some View {
        switch card.direction {
        case .recognition:
            VStack(alignment: .leading, spacing: Spacing.xs) {
                directionBadge
                HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                    Text(entry?.headword ?? "—")
                        .font(Typography.wordDisplay)
                        .foregroundStyle(Palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    SpeakerButton(text: entry?.headword ?? "", language: language, size: .title2)
                }
                if showPhonetics, let phonetic = entry?.phonetic {
                    Text(phonetic)
                        .font(Typography.phonetic)
                        .foregroundStyle(Palette.textSecondary)
                }
                if let pos = entry?.primarySense?.partOfSpeech {
                    Chip(pos.displayName)
                }
            }

        case .production:
            VStack(alignment: .leading, spacing: Spacing.xs) {
                directionBadge
                Text(entry?.primaryDefinition ?? "—")
                    .font(Typography.wordTitle)
                    .foregroundStyle(Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let translation = entry?.primarySense?.translation(preferring: nativeCodes) {
                    Text(translation)
                        .font(Typography.body)
                        .foregroundStyle(Palette.textSecondary)
                }
                if let pos = entry?.primarySense?.partOfSpeech {
                    Chip(pos.displayName)
                }
            }

        case .cloze:
            VStack(alignment: .leading, spacing: Spacing.sm) {
                directionBadge
                if let prompt = clozePrompt {
                    // The sentence is the prompt, so it gets display size rather than the
                    // small serif used for supporting examples elsewhere.
                    clozeSentence(prompt, revealed: false)
                    if let translation = clozeTranslation {
                        Text(translation)
                            .font(Typography.body)
                            .foregroundStyle(Palette.textSecondary)
                    }
                    // The definition, without the headword in it, is the only help offered.
                    // It is what makes the card answerable rather than a guessing game.
                    Text(entry?.primaryDefinition ?? "")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    // Enrolment refuses to create a cloze card without a maskable sentence,
                    // so this only appears if content changed under an existing card.
                    Text(entry?.headword ?? "—")
                        .font(Typography.wordDisplay)
                        .foregroundStyle(Palette.textPrimary)
                    Text("This sentence is no longer available.")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textTertiary)
                }
            }
        }
    }

    private var clozePrompt: ClozePrompt? { entry?.clozePrompt() }

    /// Translation of whichever example the cloze came from, matched by its text.
    private var clozeTranslation: String? {
        guard let prompt = clozePrompt, let entry else { return nil }
        let sentence = prompt.revealed
        for sense in entry.orderedSenses {
            for example in sense.examples where example.text == sentence {
                return example.translation(preferring: nativeCodes)
            }
        }
        return nil
    }

    /// The sentence with the blank, or with the answer filled in and emphasised.
    private func clozeSentence(_ prompt: ClozePrompt, revealed: Bool) -> some View {
        Group {
            if revealed {
                (
                    Text(prompt.before)
                        + Text(prompt.answer).foregroundColor(Palette.brandPrimary).bold()
                        + Text(prompt.after)
                )
            } else {
                Text(prompt.masked)
            }
        }
        .font(Typography.wordTitle)
        .foregroundStyle(Palette.textPrimary)
        .fixedSize(horizontal: false, vertical: true)
        // A run of underscores is read out character by character; this says "blank".
        .accessibilityLabel(revealed ? prompt.revealed : prompt.accessibleMasked)
    }

    /// Which way round the card is being tested. Without this, a production card looks like a
    /// recognition card whose word failed to load.
    private var directionBadge: some View {
        Label(card.direction.explanation, systemImage: card.direction.symbolName)
            .font(Typography.chip)
            .foregroundStyle(Palette.textTertiary)
    }

    // MARK: - Back

    @ViewBuilder
    private var answer: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Divider().background(Palette.separator)

            if card.direction == .production, let entry {
                // The answer to a production card is the word itself, so it leads.
                HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                    Text(entry.headword)
                        .font(Typography.wordDisplay)
                        .foregroundStyle(Palette.brandPrimary)
                    SpeakerButton(text: entry.headword, language: language, size: .title2)
                }
                if showPhonetics, let phonetic = entry.phonetic {
                    Text(phonetic)
                        .font(Typography.phonetic)
                        .foregroundStyle(Palette.textSecondary)
                }
            }

            if card.direction == .cloze, let entry, let prompt = clozePrompt {
                // Fill the blank in place rather than restating the sentence below it, so the
                // eye lands on the word it just tried to produce.
                clozeSentence(prompt, revealed: true)
                HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                    // The surface form is what went in the blank; the headword is what the
                    // dictionary calls it. When they differ — lend / lent — say both, because
                    // that difference is most of what the card is teaching.
                    if prompt.answer.lowercased() != entry.headword.lowercased() {
                        Text(entry.headword)
                            .font(Typography.bodyEmphasis)
                            .foregroundStyle(Palette.textSecondary)
                    }
                    if showPhonetics, let phonetic = entry.phonetic {
                        Text(phonetic)
                            .font(Typography.phonetic)
                            .foregroundStyle(Palette.textSecondary)
                    }
                    SpeakerButton(text: prompt.revealed, language: language, size: .callout)
                }
            }

            ForEach(Array((entry?.orderedSenses ?? []).enumerated()), id: \.element.id) { index, sense in
                senseBlock(sense, index: index)
            }

            if let notes = entry?.grammarNotes, !notes.isEmpty {
                grammarBlock(notes)
            }
        }
    }

    private func senseBlock(_ sense: Sense, index: Int) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.xxs) {
                Chip(sense.partOfSpeech.abbreviation)
                if let register = sense.register {
                    Chip(register, color: Palette.warning)
                }
            }

            // A production card already asked with the definition, so repeating it as the
            // answer would be circular. Recognition and cloze both benefit from seeing it.
            if card.direction != .production || index > 0 {
                Text(sense.definition)
                    .font(Typography.body)
                    .foregroundStyle(Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let translation = sense.translation(preferring: nativeCodes) {
                Text(translation)
                    .font(Typography.body)
                    .foregroundStyle(Palette.textSecondary)
            }

            ForEach(sense.examples) { example in
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
            }

            if !sense.synonyms.isEmpty {
                labelledList("Similar", values: sense.synonyms, color: Palette.brandSecondary)
            }
            if !sense.antonyms.isEmpty {
                labelledList("Opposite", values: sense.antonyms, color: Palette.warning)
            }
            if let note = sense.usageNote {
                Text(note)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .padding(Spacing.sm)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.brandSecondary.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: Radius.nested, style: .continuous))
            }
        }
        .padding(Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: Radius.nested, style: .continuous))
    }

    private func labelledList(_ label: String, values: [String], color: Color) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text(label)
                .font(Typography.chip)
                .foregroundStyle(Palette.textTertiary)
            // Wraps rather than scrolling: a horizontal scroll view inside a vertical one is
            // a gesture conflict, and synonym lists are short.
            FlowLayout(spacing: Spacing.xxs) {
                ForEach(values, id: \.self) { value in
                    Chip(value, color: color)
                }
            }
        }
    }

    private func grammarBlock(_ notes: [String: String]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text("Grammar")
                .font(Typography.chip)
                .foregroundStyle(Palette.textTertiary)
            // Sorted so the order does not shuffle between cards — dictionary iteration order
            // is not stable, and jittering rows look like a bug.
            ForEach(notes.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                    Text(GrammarField(rawValue: key)?.label ?? key.capitalized)
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                    Text(value)
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textPrimary)
                }
            }
        }
        .padding(Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: Radius.nested, style: .continuous))
    }
}

/// Wrapping horizontal stack, for chip lists.
///
/// Hand-written because SwiftUI has no wrapping stack before iOS 16's `Layout` protocol and no
/// built-in one at all — and a `LazyVGrid` with fixed columns would leave ragged gaps between
/// chips of very different widths.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth + size.width > maxWidth, rowWidth > 0 {
                totalHeight += rowHeight + spacing
                totalWidth = max(totalWidth, rowWidth - spacing)
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        totalHeight += rowHeight
        totalWidth = max(totalWidth, rowWidth - spacing)
        return CGSize(width: min(totalWidth, maxWidth), height: totalHeight)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
