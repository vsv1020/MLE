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

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    header
                    reviewCard
                    if !visibleDailyEntries.isEmpty {
                        dailyWordsSection
                    }
                    statsRow
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
            .task {
                reload()
                consumeIntentRequest()
            }
            // "Hey Siri, start reviewing" brings the app forward without saying why, so the
            // note the intent left is checked again once the scene is actually active — on a
            // warm launch the task above may already have run.
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { consumeIntentRequest() }
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

    // MARK: - Review CTA

    private var reviewCard: some View {
        Button {
            startSession(includeAhead: !model.hasWorkToDo)
        } label: {
            CardContainer(style: .crayon, wobbleSeed: 0x_60E0_0001) {
                HStack(spacing: Spacing.md) {
                    ZStack {
                        ProgressRing(progress: model.goalProgress)
                            .frame(width: 92, height: 92)
                        VStack(spacing: 0) {
                            Text("\(model.reviewsDue)")
                                .font(Typography.statValue)
                                .foregroundStyle(Palette.textPrimary)
                            Text("due")
                                .font(Typography.caption)
                                .foregroundStyle(Palette.textSecondary)
                        }
                    }

                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        Text(model.primaryActionTitle)
                            .font(Typography.sectionHeader)
                            .foregroundStyle(Palette.textPrimary)
                        if let goal = model.goalTarget {
                            Text("\(model.statistics.reviewsToday) of \(goal) reviews today")
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
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundStyle(Palette.textTertiary)
                }
            }
        }
        // Gentler than the default: this is a full-width card, and the same 3% on something this
        // wide moves the edges far enough to read as a jolt rather than a press.
        .pressable(scale: 0.99)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(model.primaryActionTitle). \(model.statistics.reviewsToday) reviews done today."
        )
        .accessibilityAddTraits(.isButton)
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

    /// Act on a one-shot instruction left by an App Intent, if there is one.
    ///
    /// Taken rather than read, so a session starts exactly once per invocation. Guarded on
    /// `isStudying` so arriving while already mid-session does nothing rather than restarting.
    private func consumeIntentRequest() {
        guard !isStudying, let action = IntentLaunchRequest.shared.take() else { return }
        switch action {
        case .startReview:
            startSession(includeAhead: !model.hasWorkToDo)
        }
    }

    private func startSession(includeAhead: Bool) {
        guard let preferences = dependencies.preferences else { return }
        studyOptions = ReviewQueueBuilder.Options(
            maxCards: preferences.maxReviewsPerSession,
            maxNewCards: preferences.newWordsPerDay,
            languageCode: preferences.activeLanguageCode,
            includeAhead: includeAhead
        )
        isStudying = true
    }
}

#Preview {
    HomeView()
}
