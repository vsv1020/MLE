import Foundation

/// How a language forms inflections, for the purpose of finding a headword inside a
/// sentence where it appears in a different form.
///
/// Declared per language rather than branched on, for the same reason as everything else
/// in ``LearningLanguage``: guessing that `apprendre` becomes `apprendres` would be worse
/// than not guessing at all.
public enum InflectionStrategy: String, Codable, Hashable, Sendable {
    /// Append and substitute common English suffixes — `-s`, `-ed`, `-ing`, `y → ies`,
    /// consonant doubling. Wrong for most other languages.
    case englishSuffixes
    /// Match the headword exactly. Anything irregular needs an authored blank.
    case exactOnly
}

/// A sentence with one word removed, plus the pieces needed to render it.
public struct ClozePrompt: Hashable, Sendable {
    /// Text before the blank.
    public var before: String
    /// The surface form that was removed — `"lent"`, not the headword `"lend"`. This is
    /// what the learner is asked to produce, and showing the lemma instead would be a
    /// different (easier, less useful) question.
    public var answer: String
    /// Text after the blank.
    public var after: String

    /// Fixed-width blank.
    ///
    /// Deliberately not scaled to the answer's length: a blank that grows with the word
    /// silently leaks how many letters to produce, which turns a recall test into a
    /// crossword clue. If a hint is wanted later it should be explicit and opt-in.
    public static let blank = "_____"

    public var masked: String { before + Self.blank + after }
    public var revealed: String { before + answer + after }

    /// Spoken to VoiceOver, which cannot convey a run of underscores usefully.
    public var accessibleMasked: String {
        before + " blank " + after
    }
}

/// Removes a headword from one of its own example sentences.
///
/// Pure and dependency-free, so the awkward cases — irregular verbs, elision, scripts with
/// no spaces — are all pinned by tests rather than discovered on a device.
///
/// Three strategies, tried in order:
///
/// 1. **An authored blank.** A seed pack can mark the span itself with `{{…}}`:
///    `"She {{lent}} me her bicycle."` Always wins, because content authors know things the
///    heuristics cannot.
/// 2. **Token match**, for languages written with spaces between words. Scans word tokens
///    and compares against the headword plus, for English, its regular inflections.
/// 3. **Substring match**, for languages that are not word-separated. Thai writes
///    `หนังสือสองเล่ม` with no spaces, so there are no tokens to scan and a substring is
///    the only handle available — which is exactly why ``LearningLanguage/isWordSeparated``
///    exists.
///
/// Returns `nil` when the headword genuinely cannot be located. Callers must treat that as
/// "this entry has no cloze card" rather than substituting something approximate; a cloze
/// card whose blank is the wrong word teaches the wrong thing.
public enum ClozeMasker {
    /// Marker a seed pack uses to author a blank explicitly.
    static let openMarker = "{{"
    static let closeMarker = "}}"

    public static func makePrompt(
        headword: String,
        sentence: String,
        language: LearningLanguage,
        authored: String? = nil
    ) -> ClozePrompt? {
        if let authored, let prompt = fromAuthoredMarkup(authored) {
            return prompt
        }
        guard !headword.isEmpty, !sentence.isEmpty else { return nil }

        let range = language.isWordSeparated
            ? tokenRange(of: headword, in: sentence, strategy: language.inflectionStrategy)
            : substringRange(of: headword, in: sentence)

        guard let range else { return nil }
        return ClozePrompt(
            before: String(sentence[sentence.startIndex..<range.lowerBound]),
            answer: String(sentence[range]),
            after: String(sentence[range.upperBound...])
        )
    }

    // MARK: - Authored

    /// Parse `"She {{lent}} me her bicycle."`
    static func fromAuthoredMarkup(_ markup: String) -> ClozePrompt? {
        guard let open = markup.range(of: openMarker),
              let close = markup.range(of: closeMarker, range: open.upperBound..<markup.endIndex)
        else { return nil }

        let answer = String(markup[open.upperBound..<close.lowerBound])
        guard !answer.isEmpty else { return nil }

        return ClozePrompt(
            before: String(markup[markup.startIndex..<open.lowerBound]),
            answer: answer,
            after: String(markup[close.upperBound...])
        )
    }

    /// Strip the markers, for showing the sentence normally elsewhere.
    public static func stripMarkup(_ markup: String) -> String {
        markup
            .replacingOccurrences(of: openMarker, with: "")
            .replacingOccurrences(of: closeMarker, with: "")
    }

    public static func hasAuthoredBlank(_ text: String?) -> Bool {
        guard let text else { return false }
        return text.contains(openMarker) && text.contains(closeMarker)
    }

    // MARK: - Word-separated languages

    private static func tokenRange(
        of headword: String, in sentence: String, strategy: InflectionStrategy
    ) -> Range<String.Index>? {
        let candidates = surfaceForms(of: headword, strategy: strategy)

        // Walk word tokens rather than searching for a substring, so `art` does not match
        // inside `start`.
        var index = sentence.startIndex
        while index < sentence.endIndex {
            guard isWordCharacter(sentence[index]) else {
                index = sentence.index(after: index)
                continue
            }
            var end = index
            while end < sentence.endIndex, isWordCharacter(sentence[end]) {
                end = sentence.index(after: end)
            }
            let token = sentence[index..<end]
            if candidates.contains(fold(String(token))) {
                return index..<end
            }
            index = end
        }
        return nil
    }

    /// A word character for tokenising: letters, digits, and the apostrophes that sit
    /// inside words (`don't`, `l'eau`).
    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "'" || character == "\u{2019}"
    }

    /// The headword plus the forms it might appear as.
    static func surfaceForms(of headword: String, strategy: InflectionStrategy) -> Set<String> {
        let base = fold(headword)
        var forms: Set<String> = [base]
        guard strategy == .englishSuffixes, base.count > 2 else { return forms }

        forms.formUnion([base + "s", base + "es", base + "ed", base + "d",
                         base + "ing", base + "er", base + "est"])

        if base.hasSuffix("e") {
            let stem = String(base.dropLast())
            forms.formUnion([stem + "ing", stem + "ed", stem + "er", stem + "est"])
        }
        if base.hasSuffix("y") {
            let stem = String(base.dropLast())
            forms.formUnion([stem + "ies", stem + "ied", stem + "ier", stem + "iest"])
        }
        // stop → stopped, big → bigger: a final consonant after a single vowel doubles.
        // `w`, `x` and `y` never do, which is why they are excluded — these forms are only
        // ever compared against, never shown, so a spurious one is harmless but pointless.
        if let last = base.last, let middle = base.dropLast().last, let first = base.dropLast(2).last,
           !"aeiouwxy".contains(last), "aeiou".contains(middle), !"aeiou".contains(first) {
            forms.formUnion([base + String(last) + "ed", base + String(last) + "ing",
                             base + String(last) + "er", base + String(last) + "est"])
        }
        return forms
    }

    // MARK: - Languages without word separation

    private static func substringRange(of headword: String, in sentence: String) -> Range<String.Index>? {
        // Case- and diacritic-insensitive, matching how the dictionary compares headwords.
        sentence.range(
            of: headword,
            options: [.caseInsensitive, .diacriticInsensitive],
            range: sentence.startIndex..<sentence.endIndex,
            locale: nil
        )
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                     locale: Locale(identifier: "en_US_POSIX"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
