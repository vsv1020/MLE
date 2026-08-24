import SwiftUI
import SwiftData

/// Today — the only screen most users see on most days.
///
/// Layout priority is deliberate: the review CTA is above the daily words, because skipping
/// reviews is what actually loses progress, whereas a new word can wait a day with no cost.
struct HomeView: View {
    @Environment(\.appDependencies) private var dependencies
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = HomeViewModel()
    @State private var isStudying = false
    @State private var studyOptions = ReviewQueueBuilder.Options()
    @State private var isConfirmingStudyAhead = false

    /// Today lives inside the library sheet presented by the root session, so dismissing it is
    /// how you get back to a card.
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    header
                    statusCard
                    if !visibleDailyEntries.isEmpty {
                        dailyWordsSection
                    }
                    statsRow
                    studyAheadFooter
                }
                .padding(Spacing.md)
                .readableWidth()
            }
            .screenBackground()
            .navigationTitle("Today")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    streakChip
                }
            }
            .refreshable { reload() }
            .task { reload() }
            // Reload when the app comes forward — the badge and the due count go stale while
            // it is in the background.
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { reload() }
            }
            .fullScreenCover(isPresented: $isStudying, onDismiss: reload) {
                StudySessionView(options: studyOptions)
            }
            .overlay {
                if model.isLoading && !dependencies.isContentReady {
                    loadingOverlay
                }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(model.greeting)
                .font(Typography.screenTitle)
                .foregroundStyle(Palette.textPrimary)
            Text(model.todayDescription)
                .font(Typography.caption)
                .foregroundStyle(Palette.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var streakChip: some View {
        HStack(spacing: Spacing.xxs) {
            Image(systemName: "flame.fill")
            Text("\(model.statistics.currentStreak)")
                .monospacedDigit()
        }
        .font(Typography.caption)
        // Grey when the streak is alive but today has no reviews yet — a nudge, not a threat.
        .foregroundStyle(
            model.statistics.currentStreak > 0 && model.statistics.reviewsToday == 0
                ? Palette.textSecondary
                : Palette.brandSecondary
        )
        .accessibilityLabel(streakAccessibilityLabel)
    }

    private var streakAccessibilityLabel: String {
        let days = model.statistics.currentStreak
        guard days > 0 else { return "No streak yet" }
        let suffix = model.statistics.reviewsToday == 0 ? ". Not studied today yet." : ""
        return "\(days) day streak\(suffix)"
    }

    // MARK: - Status

    /// What is waiting, and the way back to it.
    ///
    /// This was one big `Button` covering the whole card, because Today was the app's entry
    /// point and its entire job was to launch a session. The session is the root now, so the
    /// card reports state and the *button inside it* takes you back. Tapping a status readout
    /// and being thrown into a review is the kind of surprise a dashboard should not contain.
    private var statusCard: some View {
        CardContainer(style: .crayon, wobbleSeed: 0x_60E0_0001) {
            VStack(alignment: .leading, spacing: Spacing.md) {
                HStack(spacing: Spacing.md) {
                    ZStack {
                        // Only drawn when there is a goal. An empty ring around the due count
                        // would imply the user is failing at a target they never set.
                        if let progress = model.goalProgress {
                            ProgressRing(progress: progress)
                                .frame(width: 92, height: 92)
                        }
                        VStack(spacing: 0) {
                            Text("\(model.reviewsDue)")
                                .font(Typography.statValue)
                                .foregroundStyle(Palette.textPrimary)
                            Text("due")
                                .font(Typography.caption)
                                .foregroundStyle(Palette.textSecondary)
                        }
                        .frame(width: 92, height: 92)
                    }

                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        Text(model.statusTitle)
                            .font(Typography.sectionHeader)
                            .foregroundStyle(Palette.textPrimary)
                        if let goal = model.goalTarget {
                            Text("\(model.statistics.reviewsToday) of \(goal) reviews today")
                                .font(Typography.caption)
                                .foregroundStyle(Palette.textSecondary)
                        } else {
                            Text("\(model.statistics.reviewsToday) reviewed today")
                                .font(Typography.caption)
                                .foregroundStyle(Palette.textSecondary)
                        }
                        if let nextDue = model.nextDueDescription(dependencies: dependencies) {
                            Text(nextDue)
                                .font(Typography.caption)
                                .foregroundStyle(Palette.textTertiary)
                        }
                        if model.statistics.goalMetToday {
                            Chip("Goal met", color: Palette.success, systemImage: "checkmark")
                                .padding(.top, 2)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)

                // Dismisses rather than presenting. The session behind this sheet never ended —
                // it is still holding a card — so "back" is literally what happens, and
                // `StudySessionView` rebuilds its queue on dismiss to pick up anything changed
                // in here. Presenting a second session on top would stack a session over a
                // sheet over a session.
                PrimaryButton("Back to studying", systemImage: "arrow.uturn.backward") {
                    dismiss()
                }
            }
        }
    }

    /// Study-ahead, offered only when there is genuinely nothing else, and never silently.
    ///
    /// This used to be the *default*: `startSession(includeAhead: !model.hasWorkToDo)` meant
    /// that the moment you were caught up, tapping the card reviewed cards that were not due
    /// yet. That made the most damaging action in the app its own fallback.
    ///
    /// It is damaging because FSRS derives intervals from reviews that happen near the due
    /// date. Answering a card twelve days early and reporting "I remembered it" tells the model
    /// you retained it for twelve days when you retained it for minutes; stability is
    /// over-estimated and the schedule eventually collapses.
    ///
    /// It stays available because the need is real — a flight tomorrow, no signal — but it is
    /// now an explicit choice with the cost written next to it.
    @ViewBuilder
    private var studyAheadFooter: some View {
        if !model.hasWorkToDo {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Nothing is due and there are no new words left to start.")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
                Button("Study ahead anyway") { isConfirmingStudyAhead = true }
                    .font(Typography.caption)
                    .foregroundStyle(Palette.brandPrimary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .confirmationDialog(
                "Study cards before they are due?",
                isPresented: $isConfirmingStudyAhead,
                titleVisibility: .visible
            ) {
                Button("Study ahead") { startStudyAhead() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Answering a card early tells the scheduler you remembered it for longer than you did, so its intervals get less accurate. Useful before a trip; not something to do every day.")
            }
        }
    }

    // MARK: - Daily words

    /// Dismissed words disappear; accepted ones stay put with a check mark for the rest of
    /// the day. Content vanishing the moment you tap it reads as a bug.
    private var visibleDailyEntries: [Entry] {
        model.dailyEntries.filter { !model.dismissedStableIDs.contains($0.stableID) }
    }

    private var dailyWordsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            SectionHeader(
                "Today's words",
                subtitle: "\(model.acceptedStableIDs.count) of \(visibleDailyEntries.count) added"
            )

            TabView {
                ForEach(visibleDailyEntries) { entry in
                    DailyWordCard(
                        entry: entry,
                        isAccepted: model.acceptedStableIDs.contains(entry.stableID),
                        onAccept: { model.accept(entry, dependencies: dependencies) },
                        onDismiss: { model.dismiss(entry, dependencies: dependencies) }
                    )
                    .padding(.horizontal, 2)
                    .padding(.bottom, Spacing.lg)
                }
            }
            .tabViewStyle(.page)
            // Fixed height because a paging TabView cannot size to its tallest page, and a
            // varying height would make the whole screen jump between cards.
            .frame(height: 340)
        }
    }

    // MARK: - Stats row

    private var statsRow: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            SectionHeader("Your collection")
            HStack(spacing: Spacing.xs) {
                StatTile(
                    value: "\(model.statistics.countsByMaturity[.learning] ?? 0)",
                    label: "Learning",
                    tint: Palette.maturity(.learning)
                )
                StatTile(
                    value: "\(model.statistics.countsByMaturity[.young] ?? 0)",
                    label: "Known",
                    tint: Palette.maturity(.young)
                )
                StatTile(
                    value: "\(model.statistics.countsByMaturity[.mature] ?? 0)",
                    label: "Well known",
                    tint: Palette.maturity(.mature)
                )
            }
        }
    }

    private var loadingOverlay: some View {
        VStack(spacing: Spacing.sm) {
            ProgressView()
            Text("Loading your dictionary…")
                .font(Typography.caption)
                .foregroundStyle(Palette.textSecondary)
        }
        .padding(Spacing.lg)
        .background(Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }

    // MARK: - Actions

    private func reload() {
        model.goalTarget = dependencies.preferences.flatMap(\.dailyGoalTarget)
        model.load(dependencies: dependencies)
        Task {
            await dependencies.notifications.updateBadge(to: model.statistics.dueNow)
        }
    }

    /// The one path that still presents its own session, because it is genuinely a different
    /// one: `includeAhead` pulls cards the root session deliberately refuses to show.
    private func startStudyAhead() {
        guard let preferences = dependencies.preferences else { return }
        studyOptions = ReviewQueueBuilder.Options(
            maxCards: preferences.maxReviewsPerSession,
            maxNewCards: preferences.newWordsPerDay,
            languageCode: preferences.activeLanguageCode,
            includeAhead: true
        )
        isStudying = true
    }
}

#Preview {
    HomeView()
}
