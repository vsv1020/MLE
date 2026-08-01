import SwiftUI

/// A review session, full-screen.
///
/// Chrome is one progress bar, a close button and an overflow menu. Nothing else may compete
/// for the moment where the user asks themselves "do I remember this?" — that is the single
/// decision the screen exists for.
struct StudySessionView: View {
    let options: ReviewQueueBuilder.Options

    @Environment(\.appDependencies) private var dependencies
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var model = StudyViewModel()
    @State private var isConfirmingExit = false

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
                SessionSummaryView(model: model) { dismiss() }
            }
        }
        .screenBackground()
        .task { model.start(dependencies: dependencies, options: options) }
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
                    // Only confirm when there is something to lose.
                    if model.phase == .reviewing && !model.queue.isEmpty {
                        isConfirmingExit = true
                    } else {
                        dismiss()
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .frame(width: Layout.minimumTapTarget, height: Layout.minimumTapTarget)
                }
                .foregroundStyle(Palette.textSecondary)
                .accessibilityLabel("Close session")

                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Palette.surfaceRaised)
                        Capsule()
                            .fill(Palette.brandPrimary)
                            .frame(width: proxy.size.width * model.progress)
                            .animation(.easeOut(duration: 0.25), value: model.progress)
                    }
                }
                .frame(height: 5)

                Text("\(model.reviewedCount)/\(model.plannedCount)")
                    .font(Typography.buttonInterval)
                    .foregroundStyle(Palette.textSecondary)

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
                        .frame(width: Layout.minimumTapTarget, height: Layout.minimumTapTarget)
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
                    VStack(spacing: 2) {
                        Text(rating.shortLabel)
                            .font(Typography.buttonLabel)
                        if showsIntervals {
                            Text(intervalLabel(rating))
                                .font(Typography.buttonInterval)
                                .opacity(0.85)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: Layout.minimumTapTarget + 12)
                    // Not `.white` — see `Palette.onRating`. The dark-mode rating fills are
                    // light by design, and white on them is unreadable.
                    .foregroundStyle(Palette.onRating)
                    .background(Palette.rating(rating))
                    .clipShape(RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(rating.accessibilityDescription)
                .accessibilityValue(showsIntervals ? "Next review \(intervalLabel(rating))" : "")
                // Hardware keyboard shortcuts, for iPad and Mac. Free to add, and the way
                // anyone reviewing hundreds of cards a day will actually work.
                .keyboardShortcut(KeyEquivalent(Character("\(rating.rawValue)")), modifiers: [])
            }
        }
    }
}

#Preview {
    StudySessionView(options: ReviewQueueBuilder.Options())
}
