import SwiftUI

/// A review session, full-screen.
///
/// Chrome is one progress bar, a close button and an overflow menu. Nothing else may compete
/// for the moment where the user asks themselves "do I remember this?" — that is the single
/// decision the screen exists for.
struct StudySessionView: View {
    /// Where this session sits in the navigation stack, which decides what its leading button
    /// does and whether leaving is even a thing.
    enum Presentation {
        /// Pushed over something else — a deck, or Today. The X closes it.
        case sheet
        /// The root of the app. There is nothing behind it to go back to, so the leading
        /// control opens the library instead of dismissing.
        case root
    }

    let options: ReviewQueueBuilder.Options
    var presentation: Presentation = .sheet

    @Environment(\.appDependencies) private var dependencies
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    @State private var model = StudyViewModel()
    @State private var isConfirmingExit = false
    @State private var isShowingLibrary = false
    /// "Done for today" at the root: the goal screen stays up in its resting form.
    @State private var isRestingForToday = false

    var body: some View {
        VStack(spacing: 0) {
            topBar

            switch model.phase {
            case .loading:
                Spacer()
                ProgressView()
                Spacer()

            case .reviewing:
                if let card = model.currentCard {
                    FlashcardView(
                        card: card,
                        isAnswerRevealed: model.isAnswerRevealed,
                        reduceMotion: reduceMotion
                    )
                    // Mochi peeks over the card's top edge and reacts to the last answer.
                    // Trailing, because the direction badge and headword are centred and the
                    // leading corner is under the library button.
                    .overlay(alignment: .topTrailing) {
                        Mascot(mood: mascotMood)
                            .frame(width: 58, height: 48)
                            .offset(x: -18, y: -12)
                    }
                    // Identity keyed on the card so SwiftUI treats each card as a new view.
                    .id(card.cardID)
                    .transition(cardTransition)
                    Spacer(minLength: 0)
                    bottomControls
                } else {
                    Spacer()
                }

            case .goalReached:
                GoalCompleteView(
                    model: model,
                    onContinue: {
                        isRestingForToday = false
                        model.continueAfterGoal()
                    },
                    onDone: {
                        switch presentation {
                        case .sheet: dismiss()
                        case .root: isRestingForToday = true
                        }
                    },
                    isResting: isRestingForToday
                )

            case .finished:
                SessionSummaryView(model: model) {
                    switch presentation {
                    case .sheet:
                        dismiss()
                    case .root:
                        // Nothing behind the root to dismiss to. Re-run `start` first: a card
                        // may have come due, and it introduces new words if any are left. If
                        // there is still nothing, open the library — re-rendering the same
                        // summary made the button look broken, which is exactly how it was
                        // reported.
                        model.start(dependencies: dependencies, options: options)
                        if model.phase == .finished { isShowingLibrary = true }
                    }
                }
            }
        }
        // What makes `cardTransition` actually play.
        //
        // The transition has been declared since the first version of this screen and has never
        // once run: a transition only animates inside an animation transaction, and nothing
        // provided one — no `.animation(_:value:)` here, no `withAnimation` around `grade`. Every
        // card change has been a hard cut. Keyed on the card's identity, so revealing an answer
        // or updating a count does not trigger it.
        .animation(Motion.pop(reduceMotion), value: model.currentCard?.cardID)
        .screenBackground()
        // Resting is a property of *this* goal screen. Without the reset it would outlive it —
        // an app left open overnight would greet tomorrow's goal already asleep.
        .onChange(of: model.phase) { _, phase in
            if phase != .goalReached { isRestingForToday = false }
        }
        .task { model.start(dependencies: dependencies, options: options) }
        // "Hey Siri, start reviewing" used to be consumed by Today, which was the app's entry
        // point. It no longer is — at launch this screen is what exists — so the note would have
        // sat unread and the intent would have done nothing at all.
        //
        // Only the root session takes it. A deck-scoped session presented over the root must not
        // swallow an instruction meant for the app as a whole.
        .task { consumeIntentRequest() }
        .onChange(of: scenePhase) { _, phase in
            // A warm launch may have run the task above before the intent wrote its note.
            if phase == .active { consumeIntentRequest() }
        }
        .sheet(isPresented: $isShowingLibrary, onDismiss: {
            // Words may have been added, enrolled or suspended in there, so the queue is
            // rebuilt rather than resumed. Reviews already graded are in the store, not in
            // this queue, so nothing is lost by starting again.
            model.start(dependencies: dependencies, options: options)
        }) {
            MainTabView()
        }
        .alert("End this session?", isPresented: $isConfirmingExit) {
            Button("Keep studying", role: .cancel) {}
            Button("End session") { dismiss() }
        } message: {
            Text("Your answers so far are saved. The remaining \(model.queue.count) card\(model.queue.count == 1 ? "" : "s") stay due.")
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    /// Act on a one-shot instruction left by an App Intent.
    ///
    /// "Start reviewing" no longer has to *start* anything: the root of the app is already a
    /// session holding a card. So the whole job is to make that card visible — close the library
    /// if it is covering it, and re-run `start` if the session had finished.
    private func consumeIntentRequest() {
        guard presentation == .root else { return }
        guard let action = IntentLaunchRequest.shared.take() else { return }
        switch action {
        case .startReview:
            isShowingLibrary = false
            if model.phase == .finished {
                model.start(dependencies: dependencies, options: options)
            } else if model.phase == .goalReached {
                // Asking to review is an answer to "stop or keep going?".
                model.continueAfterGoal()
            }
        }
    }

    /// Spoken instead of the raw glyphs, which VoiceOver would read as "12 slash 30".
    private var countLabel: String {
        let stage = model.hasMovedPastDue ? ", now on new words" : ""
        if let goal = model.goalTarget {
            return model.isGoalMet
                ? "\(model.reviewsToday) reviewed today, daily goal of \(goal) complete\(stage)"
                : "\(model.reviewsToday) of \(goal) reviewed today\(stage)"
        }
        return "\(model.reviewedCount) reviewed this session\(stage)"
    }

    /// Slide when motion is allowed, cross-fade when it is not. Never a 3D flip — it obscures
    /// the text mid-rotation, which is the one thing the user is trying to read.
    private var cardTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .asymmetric(
                // The new card pops up from the table; the old one is flicked away. Scaled from
                // the bottom edge so it grows *up* into place rather than inflating from its
                // middle, which reads as a toy being set down rather than as a zoom.
                insertion: .scale(scale: 0.86, anchor: .bottom).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity)
            )
    }

    /// Mochi's reaction to the most recent answer.
    ///
    /// "Forgot" maps to `.encourage`, never to anything sad. A companion that looks disappointed
    /// at an honest answer teaches people to stop answering honestly, and inflated grades are the
    /// one input that quietly ruins every interval FSRS computes afterwards.
    private var mascotMood: Mascot.Mood {
        switch model.lastRating {
        case .none: model.isAnswerRevealed ? .happy : .curious
        case .again?: .encourage
        case .hard?: .curious
        case .good?: .happy
        case .easy?: .cheer
        }
    }

    // MARK: - Chrome

    private var topBar: some View {
        VStack(spacing: Spacing.xs) {
            HStack(spacing: Spacing.sm) {
                Button {
                    switch presentation {
                    case .root:
                        // No confirmation and no warning about "ending" anything. At the root
                        // the session never ends — you are opening the library and coming back,
                        // and every answer is already written to the store.
                        isShowingLibrary = true
                    case .sheet:
                        // Only confirm when there is something to lose.
                        if model.phase == .reviewing && !model.queue.isEmpty {
                            isConfirmingExit = true
                        } else {
                            dismiss()
                        }
                    }
                } label: {
                    Image(systemName: presentation == .root ? "books.vertical" : "xmark")
                        .font(.body.weight(.semibold))
                        .frame(width: LayoutMetrics.minimumTapTarget, height: LayoutMetrics.minimumTapTarget)
                }
                .foregroundStyle(Palette.textSecondary)
                .accessibilityLabel(presentation == .root ? "Open library" : "Close session")

                // Both hidden once the session is over, so the summary is not read through a
                // 100%-full bar and a redundant count.
                //
                // The overflow `Menu` and the X deliberately stay: `lastGraded` is only cleared
                // inside `undo()`, so `canUndo` survives into `.finished`, and `undo()` sets the
                // phase back to `.reviewing`. This screen is the one place a mis-tapped final
                // grade can be taken back before it reaches FSRS.
                if model.phase == .reviewing || model.phase == .loading {
                    // The bar exists only when there is a goal to fill.
                    //
                    // With an endless queue there is no denominator to invent. The old bar
                    // measured progress through one batch, and batches now refill silently —
                    // so it would have filled up and reset several times a session, which is
                    // worse than showing nothing.
                    if let goalProgress = model.goalProgress {
                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Palette.surfaceRaised)
                                Capsule()
                                    .fill(Palette.brandPrimary)
                                    .frame(width: proxy.size.width * goalProgress)
                                    .animation(Motion.value(reduceMotion), value: goalProgress)
                            }
                        }
                        .frame(height: 5)
                    } else {
                        Spacer()
                    }

                    // A count, never a fraction. Studying as much as you like means the number
                    // has nothing to be out of — and a counter that ticks upward with no ceiling
                    // is the honest readout for it.
                    // With a goal it counts *today*, the same number the bar fills with — it used
                    // to count this session, so a second session read "4 / 30" over a full bar.
                    // Past the goal the fraction gives way to a tick: "34 / 30" looked like the
                    // app had not noticed.
                    HStack(spacing: 2) {
                        if let goal = model.goalTarget {
                            CountingNumber(model.reviewsToday)
                            if model.isGoalMet {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Palette.success)
                            } else {
                                Text("/ \(goal)")
                            }
                        } else {
                            CountingNumber(model.reviewedCount)
                        }
                    }
                    .font(Typography.buttonInterval)
                    // Quietly recoloured once the due pile is done and the session has moved on
                    // to words you have never seen. Colour alone would be a poor signal, which
                    // is why the accessibility label says it in words too.
                    .foregroundStyle(model.hasMovedPastDue ? Palette.brandSecondary : Palette.textSecondary)
                    .animation(Motion.value(reduceMotion), value: model.hasMovedPastDue)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(countLabel)
                } else {
                    Spacer()
                }

                Menu {
                    if model.canUndo {
                        Button {
                            model.undo(dependencies: dependencies)
                        } label: {
                            Label("Undo last answer", systemImage: "arrow.uturn.backward")
                        }
                    }
                    if let card = model.currentCard {
                        Button {
                            model.toggleFlag(dependencies: dependencies)
                        } label: {
                            Label(
                                card.isFlagged ? "Remove flag" : "Flag for later",
                                systemImage: card.isFlagged ? "flag.slash" : "flag"
                            )
                        }
                        Button {
                            model.bury(dependencies: dependencies)
                        } label: {
                            Label("Not today", systemImage: "moon.zzz")
                        }
                        Button(role: .destructive) {
                            model.suspend(dependencies: dependencies)
                        } label: {
                            Label("Stop studying this word", systemImage: "pause.circle")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.body)
                        .frame(width: LayoutMetrics.minimumTapTarget, height: LayoutMetrics.minimumTapTarget)
                }
                .foregroundStyle(Palette.textSecondary)
                .accessibilityLabel("Session options")
            }

            if model.deferredCount > 0 {
                // Say so explicitly. Capping the session and then implying the backlog is
                // gone would be dishonest.
                Text("\(model.deferredCount) more due after this session")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textTertiary)
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.bottom, Spacing.xs)
    }

    // MARK: - Bottom controls

    private var bottomControls: some View {
        VStack(spacing: Spacing.sm) {
            if model.isAnswerRevealed {
                RatingBar(
                    showsIntervals: dependencies.preferences?.showIntervalPreview ?? true,
                    intervalLabel: model.intervalLabel(for:)
                ) { rating in
                    model.grade(rating, dependencies: dependencies)
                }
            } else {
                PrimaryButton("Show answer") {
                    model.revealAnswer()
                }
            }
        }
        .padding(Spacing.md)
        .readableWidth()
        .background(Palette.canvas)
    }
}

/// The four rating buttons.
///
/// Fixed order, always labelled, each showing the interval it would produce. Showing the
/// consequence of every choice is what makes a scheduler feel trustworthy rather than
/// arbitrary — it is the difference between "why is this due again already?" and "because I
/// pressed Hard".
struct RatingBar: View {
    let showsIntervals: Bool
    let intervalLabel: (Rating) -> String
    let onRate: (Rating) -> Void

    var body: some View {
        HStack(spacing: Spacing.xs) {
            ForEach(Rating.allCases) { rating in
                Button {
                    onRate(rating)
                } label: {
                    VStack(spacing: 1) {
                        // The face carries the meaning at a glance; the word underneath is what
                        // makes it unambiguous. Neither is ever alone — an emoji on its own is a
                        // guess, and the words on their own were the metacognition problem.
                        Text(rating.face)
                            // A text style, not `size: 25`. This is the control a user presses
                            // hundreds of times a day; if the labels grow with Dynamic Type and
                            // the faces do not, the faces stop being the thing you aim at.
                            .font(.system(.title2, design: .rounded))
                        Text(rating.shortLabel)
                            .font(Typography.buttonLabel)
                        if showsIntervals {
                            Text(intervalLabel(rating))
                                .font(Typography.buttonInterval)
                                .opacity(0.8)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: LayoutMetrics.minimumTapTarget + 22)
                    // Dark ink on a bright fill — see `Palette.onRating`. 5.28:1 at worst.
                    .foregroundStyle(Palette.onRating)
                    .background(Palette.rating(rating))
                    // Each button gets its own wobble seed, so the four read as four separate
                    // drawn shapes rather than one stamp repeated. Derived from `rawValue`, so it
                    // is stable across launches — a border that re-rolls on every appearance
                    // looks like a glitch, not like pencil.
                    //
                    // Amplitude 0.8 against the card's 1.5. The wobble is an absolute distance,
                    // so the same value is a much larger *proportion* of a 66pt button than of a
                    // full-width card: at 1.2 these read as melted rather than drawn.
                    .clipShape(WobbleShape(cornerRadius: Radius.button, amplitude: 0.8, seed: seed(for: rating)))
                    // One stroke doing two jobs.
                    //
                    // It is mandatory, not decorative: a 400-weight fill is only 1.46:1 against
                    // paper, so `Palette.ratingEdge` is what gives the button a boundary at all.
                    //
                    // Its *weight* then carries the emphasis on `Got it`, which in a well-scheduled
                    // deck is the answer four times out of five and which nothing said so.
                    //
                    // Deliberately *only* visual. Making it easier to physically hit needs the row
                    // to reflow, which is a decision worth feeling on a device first.
                    .overlay(
                        WobbleShape(cornerRadius: Radius.button, amplitude: 0.8, seed: seed(for: rating))
                            .stroke(
                                Palette.ratingEdge(rating),
                                lineWidth: rating == .good ? 3.5 : 2
                            )
                    )
                }
                // A candy button: it sits on a base in its own darker edge colour and squashes
                // down into it. The base is the same wobble as the button, or it would peek out
                // as a mismatched second outline.
                .buttonStyle(SquishButtonStyle(
                    base: WobbleShape(cornerRadius: Radius.button, amplitude: 0.8, seed: seed(for: rating)),
                    baseColor: Palette.ratingEdge(rating)
                ))
                .accessibilityLabel(rating.accessibilityDescription)
                .accessibilityValue(showsIntervals ? "Next review \(intervalLabel(rating))" : "")
                // Hardware keyboard shortcuts, for iPad and Mac. Free to add, and the way
                // anyone reviewing hundreds of cards a day will actually work.
                .keyboardShortcut(KeyEquivalent(Character("\(rating.rawValue)")), modifiers: [])
            }
        }
    }

    /// A distinct, stable wobble per button.
    ///
    /// Multiplied by a large odd constant rather than used raw: `SeededGenerator` is SplitMix64,
    /// and seeds 1…4 are close enough in its state space that the first few outputs come out
    /// visibly similar — which would defeat the whole point of seeding them separately.
    private func seed(for rating: Rating) -> UInt64 {
        UInt64(rating.rawValue) &* 0x9E37_79B9_7F4A_7C15
    }
}

#Preview {
    StudySessionView(options: ReviewQueueBuilder.Options())
}
