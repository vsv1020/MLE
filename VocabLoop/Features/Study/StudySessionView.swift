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

    @State private var model = StudyViewModel()
    @State private var isConfirmingExit = false
    @State private var isShowingLibrary = false

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
                    // Identity keyed on the card so SwiftUI treats each card as a new view
                    // and the transition actually animates.
                    .id(card.cardID)
                    .transition(cardTransition)
                    Spacer(minLength: 0)
                    bottomControls
                } else {
                    Spacer()
                }

            case .finished:
                SessionSummaryView(model: model) {
                    switch presentation {
                    case .sheet:
                        dismiss()
                    case .root:
                        // Nothing behind the root to dismiss to. Re-running `start` is the
                        // honest action: if a card has since come due it appears, and if the
                        // library is still empty the summary simply comes straight back.
                        model.start(dependencies: dependencies, options: options)
                    }
                }
            }
        }
        .screenBackground()
        .task { model.start(dependencies: dependencies, options: options) }
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

    /// Spoken instead of the raw glyphs, which VoiceOver would read as "12 slash 30".
    private var countLabel: String {
        let stage = model.hasMovedPastDue ? ", now on new words" : ""
        if let goal = model.goalTarget {
            return "\(model.reviewedCount) reviewed this session, daily goal \(goal)\(stage)"
        }
        return "\(model.reviewedCount) reviewed this session\(stage)"
    }

    /// Slide when motion is allowed, cross-fade when it is not. Never a 3D flip — it obscures
    /// the text mid-rotation, which is the one thing the user is trying to read.
    private var cardTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity)
            )
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
                if model.phase != .finished {
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
                    HStack(spacing: 2) {
                        CountingNumber(model.reviewedCount)
                        if let goal = model.goalTarget {
                            Text("/ \(goal)")
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
                    .clipShape(WobbleShape(cornerRadius: Radius.button, amplitude: 1.2, seed: seed(for: rating)))
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
                        WobbleShape(cornerRadius: Radius.button, amplitude: 1.2, seed: seed(for: rating))
                            .stroke(
                                Palette.ratingEdge(rating),
                                lineWidth: rating == .good ? 3.5 : 2
                            )
                    )
                }
                .pressable(scale: 0.95)
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
        UInt64(rating.rawValue) &* 0x_9E37_79B9_7F4A_7C15
    }
}

#Preview {
    StudySessionView(options: ReviewQueueBuilder.Options())
}
