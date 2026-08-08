import SwiftUI
import SwiftData

/// Resolves a stable ID to an entry, so navigation can push by value.
///
/// `navigationDestination(for: Entry.self)` would require the `@Model` object to survive the
/// navigation path's encoding, which it does not. A string ID is the durable handle.
struct EntryDetailScreen: View {
    let stableID: String

    @Environment(\.appDependencies) private var dependencies
    @State private var entry: Entry?

    var body: some View {
        Group {
            if let entry {
                EntryDetailView(entry: entry)
            } else {
                EmptyStateView(
                    systemImage: "questionmark.circle",
                    title: "Word not found",
                    message: "This word may have been removed, or its content pack is no longer installed."
                )
            }
        }
        .task {
            entry = try? dependencies.context.entry(stableID: stableID)
            if let entry {
                try? dependencies.search.markViewed(entry)
            }
        }
    }
}

/// Everything known about one word, including its scheduling state.
///
/// Exposing stability, difficulty and the full review history is a deliberate trust decision:
/// a user can always see *why* a card is due when it is. An SRS that will not show its
/// reasoning is asking to be believed on faith.
struct EntryDetailView: View {
    let entry: Entry

    @Environment(\.appDependencies) private var dependencies
    @State private var isShowingResetConfirmation = false
    @State private var actionError: String?

    private var language: LearningLanguage {
        entry.language ?? dependencies.preferences?.activeLanguage ?? .english
    }

    private var nativeCodes: [String] {
        dependencies.preferences?.nativeLanguageCodes ?? ["en"]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                header
                enrolmentControls
                ForEach(entry.orderedSenses) { sense in
                    senseCard(sense)
                }
                if !entry.grammarNotes.isEmpty {
                    grammarCard
                }
                if entry.isEnrolled {
                    schedulingCard
                    historyCard
                }
            }
            .padding(Spacing.md)
            .readableWidth()
        }
        .screenBackground()
        .navigationTitle(entry.headword)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Reset progress for “\(entry.headword)”?",
            isPresented: $isShowingResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset to new", role: .destructive) {
                perform { try $0.resetProgress(for: entry) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The card goes back to being unseen. Your past reviews are kept for statistics.")
        }
        .alert("That didn’t work", isPresented: Binding(
            get: { actionError != nil },
            set: { if !$0 { actionError = nil } }
        )) {
            Button("OK") { actionError = nil }
        } message: {
            Text(actionError ?? "")
        }
    }

    /// Run a mutating action, surfacing a failure instead of swallowing it.
    ///
    /// Every control on this screen writes to the store, and `try?` on a button action means a
    /// failed write looks exactly like a button that does nothing. A save can genuinely fail —
    /// a full disk is the ordinary case — and the user has to be told rather than left tapping.
    private func perform(_ action: (ReviewService) throws -> Void) {
        do {
            try action(dependencies.review)
            Haptics.tap()
        } catch {
            actionError = error.localizedDescription
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                Text(entry.headword)
                    .font(Typography.wordDisplay)
                    .foregroundStyle(Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                SpeakerButton(text: entry.headword, language: language, size: .title2)
            }

            if let phonetic = entry.phonetic {
                HStack(spacing: Spacing.xxs) {
                    Text(phonetic)
                        .font(Typography.phonetic)
                        .foregroundStyle(Palette.textSecondary)
                    if entry.phoneticNotation != .none {
                        Chip(entry.phoneticNotation.label)
                    }
                }
            }

            FlowLayout(spacing: Spacing.xxs) {
                if let cefr = entry.cefr {
                    Chip("\(cefr.rawValue) · \(cefr.description)", color: Palette.brandSecondary)
                }
                if let rank = entry.frequencyRank {
                    Chip("Rank #\(rank)", systemImage: "chart.bar")
                }
                ForEach(entry.partsOfSpeech) { pos in
                    Chip(pos.displayName)
                }
                ForEach(entry.tags, id: \.self) { tag in
                    Chip(tag, color: Palette.brandPrimary)
                }
            }
        }
    }

    // MARK: - Enrolment

    @ViewBuilder
    private var enrolmentControls: some View {
        if entry.isEnrolled {
            HStack(spacing: Spacing.sm) {
                Label("In your words", systemImage: "checkmark.circle.fill")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.success)
                Spacer()
                Menu {
                    Button("Reset progress", role: .destructive) {
                        isShowingResetConfirmation = true
                    }
                    Button(isSuspended ? "Resume studying" : "Pause studying") {
                        let shouldSuspend = !isSuspended
                        perform { try $0.setSuspended(shouldSuspend, for: entry) }
                    }
                    Button("Remove from my words", role: .destructive) {
                        perform { try $0.unenroll(entry: entry) }
                    }
                } label: {
                    Label("Manage", systemImage: "ellipsis.circle")
                        .font(Typography.caption)
                }
            }
        } else {
            PrimaryButton("Add to my words", systemImage: "plus") {
                guard let preferences = dependencies.preferences else { return }
                perform { _ = try $0.enroll(entry: entry, preferences: preferences) }
            }
        }
    }

    private var isSuspended: Bool {
        !entry.cards.isEmpty && entry.cards.allSatisfy(\.isSuspended)
    }

    // MARK: - Senses

    private func senseCard(_ sense: Sense) -> some View {
        CardContainer(isRaised: true) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack(spacing: Spacing.xxs) {
                    Chip(sense.partOfSpeech.displayName)
                    if let register = sense.register {
                        Chip(register, color: Palette.warning)
                    }
                }
                Text(sense.definition)
                    .font(Typography.body)
                    .foregroundStyle(Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                if let translation = sense.translation(preferring: nativeCodes) {
                    Text(translation)
                        .font(Typography.body)
                        .foregroundStyle(Palette.textSecondary)
                }

                ForEach(sense.examples) { example in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: Spacing.xxs) {
                            Text(example.text)
                                .font(Typography.example)
                                .italic()
                                .foregroundStyle(Palette.textPrimary)
                            SpeakerButton(text: example.text, language: language, size: .caption)
                        }
                        if let translation = example.translation(preferring: nativeCodes) {
                            Text(translation)
                                .font(Typography.caption)
                                .foregroundStyle(Palette.textSecondary)
                        }
                    }
                    .padding(.top, Spacing.xxs)
                }

                if !sense.synonyms.isEmpty {
                    wordList("Similar", sense.synonyms, color: Palette.brandSecondary)
                }
                if !sense.antonyms.isEmpty {
                    wordList("Opposite", sense.antonyms, color: Palette.warning)
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
        }
    }

    private func wordList(_ label: String, _ values: [String], color: Color) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text(label)
                .font(Typography.chip)
                .foregroundStyle(Palette.textTertiary)
            FlowLayout(spacing: Spacing.xxs) {
                ForEach(values, id: \.self) { value in
                    Chip(value, color: color)
                }
            }
        }
        .padding(.top, Spacing.xxs)
    }

    private var grammarCard: some View {
        CardContainer(isRaised: true) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Grammar")
                    .font(Typography.sectionHeader)
                ForEach(entry.grammarNotes.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                    HStack(alignment: .firstTextBaseline) {
                        Text(GrammarField(rawValue: key)?.label ?? key.capitalized)
                            .font(Typography.caption)
                            .foregroundStyle(Palette.textSecondary)
                        Spacer()
                        Text(value)
                            .font(Typography.caption)
                            .foregroundStyle(Palette.textPrimary)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
        }
    }

    // MARK: - Scheduling

    private var schedulingCard: some View {
        CardContainer(isRaised: true) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("Scheduling")
                    .font(Typography.sectionHeader)
                ForEach(entry.cards.sorted(by: { $0.directionRaw < $1.directionRaw })) { card in
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        HStack(spacing: Spacing.xxs) {
                            Image(systemName: card.direction.symbolName)
                                .font(.caption)
                            Text(card.direction.displayName)
                                .font(Typography.caption)
                            Spacer()
                            MaturityDot(card.maturity)
                            if card.isSuspended {
                                Chip("Paused", color: Palette.warning)
                            }
                        }
                        .foregroundStyle(Palette.textSecondary)

                        HStack(spacing: Spacing.md) {
                            schedulingValue(IntervalFormatter.dueDescription(due: card.due), label: "Next")
                            schedulingValue(IntervalFormatter.short(days: card.intervalDays), label: "Interval")
                        }
                        HStack(spacing: Spacing.md) {
                            // The model's own numbers, shown plainly. "Stability" is FSRS's S:
                            // days until recall drops to 90%.
                            schedulingValue(String(format: "%.1fd", card.stability), label: "Stability")
                            schedulingValue(String(format: "%.1f", card.difficulty), label: "Difficulty")
                            schedulingValue("\(card.reps)", label: "Reviews")
                            schedulingValue("\(card.lapses)", label: "Lapses")
                        }
                    }
                    .padding(.vertical, Spacing.xxs)
                    if card.cardID != entry.cards.last?.cardID {
                        Divider().background(Palette.separator)
                    }
                }
                Text("Scheduled by \(entry.cards.first?.scheduler.displayName ?? SchedulerKind.fsrs5.displayName).")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textTertiary)
            }
        }
    }

    private func schedulingValue(_ value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value)
                .font(Typography.caption)
                .foregroundStyle(Palette.textPrimary)
            Text(label)
                .font(Typography.chip)
                .foregroundStyle(Palette.textTertiary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }

    private var historyCard: some View {
        CardContainer(isRaised: true) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Review history")
                    .font(Typography.sectionHeader)
                let logs = entry.cards
                    .flatMap(\.reviews)
                    .sorted { $0.reviewedAt > $1.reviewedAt }
                    .prefix(20)

                if logs.isEmpty {
                    Text("No reviews yet.")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                } else {
                    ForEach(Array(logs)) { log in
                        HStack(spacing: Spacing.xs) {
                            Circle()
                                .fill(Palette.rating(log.rating))
                                .frame(width: 8, height: 8)
                            Text(log.rating.shortLabel)
                                .font(Typography.caption)
                                .foregroundStyle(Palette.textPrimary)
                                .frame(width: 48, alignment: .leading)
                            Text(log.reviewedAt.formatted(.dateTime.day().month().hour().minute()))
                                .font(Typography.caption)
                                .foregroundStyle(Palette.textSecondary)
                            Spacer()
                            // The model's prediction at the time. Comparing it to what the user
                            // actually did is how you judge whether the scheduler is working.
                            Text("R \(Int(log.retrievabilityBefore * 100))%")
                                .font(Typography.buttonInterval)
                                .foregroundStyle(Palette.textTertiary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }
}
