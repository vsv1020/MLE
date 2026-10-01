import SwiftUI

/// The current card, asked however ``QuestionGenerator`` decided.
///
/// `flip` is the existing ``FlashcardView``, untouched — most cards, every new and learning card,
/// and every card when quizzes are off or the UI tests pass `-uiTestingFlipOnly`. The quiz kinds
/// put their question on top; once answered, the full answer side (the same ``FlashcardView``,
/// revealed) appears beneath it, so a quiz teaches exactly what a flip card would have.
struct QuestionCardView: View {
    let card: Card
    let question: Question?
    let isAnswerRevealed: Bool
    let isQuestionAnswered: Bool
    let selectedOption: Int?
    let typedAnswer: String?
    let reduceMotion: Bool
    let onPick: (Int) -> Void
    let onSubmitTyped: (String) -> Void
    let onGiveUp: () -> Void

    var body: some View {
        if let question, question.kind.isAutoGraded, question.cardID == card.cardID {
            quiz(question)
        } else {
            FlashcardView(card: card, isAnswerRevealed: isAnswerRevealed, reduceMotion: reduceMotion)
        }
    }

    /// Before the answer the question scrolls on its own, for large Dynamic Type. After it, the
    /// question keeps its natural height and the revealed card takes the rest of the space and
    /// scrolls — one scroll view at a time, never one inside another.
    @ViewBuilder
    private func quiz(_ question: Question) -> some View {
        if isQuestionAnswered {
            VStack(spacing: Spacing.xs) {
                quizBody(question)
                FlashcardView(card: card, isAnswerRevealed: true, reduceMotion: reduceMotion)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 8)))
            }
            .animation(Motion.reveal(reduceMotion), value: isQuestionAnswered)
        } else {
            ScrollView {
                quizBody(question)
                    // Leaves room for Mochi, who peeks over the top edge of the card.
                    .padding(.top, Spacing.md)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    @ViewBuilder
    private func quizBody(_ question: Question) -> some View {
        switch question.kind {
        case .multipleChoice, .listenChoose, .clozeChoose:
            MultipleChoiceView(
                card: card,
                question: question,
                isAnswered: isQuestionAnswered,
                selectedOption: selectedOption,
                onPick: onPick
            )
        case .typed:
            TypedAnswerView(
                card: card,
                question: question,
                isAnswered: isQuestionAnswered,
                typedAnswer: typedAnswer,
                onSubmit: onSubmitTyped,
                onGiveUp: onGiveUp
            )
        case .flip:
            // Never reached — `body` only routes auto-graded kinds here — but spelled out rather
            // than `default`, so a new kind is a compile error instead of a blank card.
            FlashcardView(card: card, isAnswerRevealed: isAnswerRevealed, reduceMotion: reduceMotion)
        }
    }
}
