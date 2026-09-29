import SwiftUI

struct SettingsView: View {
    @Environment(\.appDependencies) private var dependencies

    private var preferences: StudyPreferences? { dependencies.preferences }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        AccountView()
                    } label: {
                        accountRow
                    }
                }

                Section {
                    NavigationLink {
                        PlusView()
                    } label: {
                        Label {
                            Text(dependencies.entitlements.isPlus ? "VocabLoop Plus — unlocked" : "VocabLoop Plus")
                        } icon: {
                            Image(systemName: "sparkles").foregroundStyle(Palette.brandSecondary)
                        }
                    }
                }

                Section("Studying") {
                    NavigationLink("Daily targets") { DailyTargetsView() }
                    NavigationLink("Memory algorithm") { SchedulerSettingsView() }
                    NavigationLink("Card types") { CardTypeSettingsView() }
                }

                Section("Content") {
                    NavigationLink("Languages") { LanguageSettingsView() }
                    NavigationLink("Presentation") { PresentationSettingsView() }
                }

                Section("Reminders") {
                    NavigationLink("Notifications") { NotificationSettingsView() }
                }

                Section("Data") {
                    NavigationLink("Storage and sync") { DataSettingsView() }
                }

                Section {
                    NavigationLink("About VocabLoop") { AboutView() }
                } footer: {
                    Text("VocabLoop works entirely offline. Reviews, statistics, audio and the whole dictionary need no network.")
                }
            }
            .navigationTitle("Settings")
        }
    }

    private var accountRow: some View {
        HStack(spacing: Spacing.sm) {
            Text(dependencies.account?.initials ?? "?")
                .font(Typography.caption)
                .foregroundStyle(Palette.onBrand)
                .frame(width: 36, height: 36)
                .background(Palette.brandPrimary)
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(dependencies.auth.current?.displayName ?? "Guest")
                    .font(Typography.bodyEmphasis)
                    .foregroundStyle(Palette.textPrimary)
                Text(dependencies.auth.isGuest
                    ? "Studying as a guest"
                    : dependencies.auth.current?.email ?? "Signed in")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Daily targets

struct DailyTargetsView: View {
    @Environment(\.appDependencies) private var dependencies

    var body: some View {
        Form {
            if let preferences = dependencies.preferences {
                Section {
                    Stepper(
                        preferences.dailyGoalTarget.map { "Reviews per day: \($0)" }
                            ?? "Daily goal: none",
                        // Reaches 0 on purpose — that is how a goal is *removed*. The old floor
                        // of 5 meant the only way out of having a target was never to set one.
                        value: binding(\.dailyGoal), in: 0...500, step: 5
                    )
                } footer: {
                    Text("Optional. With a goal, the ring on Today fills toward it; without one, nothing counts down and you simply study for as long as you like. Changing it does not affect days you have already completed.")
                }

                Section {
                    Stepper(
                        "New words per day: \(preferences.newWordsPerDay)",
                        value: binding(\.newWordsPerDay), in: 0...50
                    )
                } footer: {
                    Text("Each new word becomes roughly four reviews over its first month. Set this to 0 to pause new words without losing your streak.")
                }

                Section {
                    Stepper(
                        "Cards per session: \(preferences.maxReviewsPerSession)",
                        value: binding(\.maxReviewsPerSession), in: 10...500, step: 10
                    )
                } footer: {
                    Text("A cap on one sitting, so a backlog arrives as a session rather than a wall. Cards beyond the cap stay due.")
                }

                Section {
                    Picker("Day starts at", selection: binding(\.dayStartHour)) {
                        ForEach(0..<12) { hour in
                            Text(hour == 0 ? "Midnight" : "\(hour):00").tag(hour)
                        }
                    }
                } footer: {
                    Text("When your study day rolls over. The default of 4am means a late-night session still counts toward the day you started.")
                }
            }
        }
        .navigationTitle("Daily targets")
    }

    /// Binding onto an `Int` preference, saving on every change.
    ///
    /// Typed to `Int` rather than made generic: a generic version needs a fallback value for
    /// the case where preferences are missing, and there is no sensible universal one.
    private func binding(_ keyPath: ReferenceWritableKeyPath<StudyPreferences, Int>) -> Binding<Int> {
        Binding(
            get: { dependencies.preferences?[keyPath: keyPath] ?? 0 },
            set: { newValue in
                dependencies.preferences?[keyPath: keyPath] = newValue
                dependencies.savePreferences()
            }
        )
    }
}

// MARK: - Scheduler

struct SchedulerSettingsView: View {
    @Environment(\.appDependencies) private var dependencies

    var body: some View {
        Form {
            if let preferences = dependencies.preferences {
                Section {
                    ForEach(SchedulerKind.allCases) { kind in
                        Button {
                            preferences.scheduler = kind
                            dependencies.savePreferences()
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(kind.displayName)
                                        .font(Typography.bodyEmphasis)
                                        .foregroundStyle(Palette.textPrimary)
                                    Spacer()
                                    if preferences.scheduler == kind {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(Palette.brandPrimary)
                                    }
                                }
                                Text(kind.summary)
                                    .font(Typography.caption)
                                    .foregroundStyle(Palette.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .accessibilityAddTraits(preferences.scheduler == kind ? [.isSelected, .isButton] : .isButton)
                    }
                } header: {
                    Text("Algorithm")
                } footer: {
                    Text("Switching keeps your review history. Existing cards carry on from where they are.")
                }

                if preferences.scheduler == .fsrs5 {
                    Section {
                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            HStack {
                                Text("Target retention")
                                Spacer()
                                Text("\(Int(preferences.desiredRetention * 100))%")
                                    .font(Typography.bodyEmphasis)
                                    .monospacedDigit()
                                    .foregroundStyle(Palette.brandPrimary)
                            }
                            Slider(
                                value: Binding(
                                    get: { preferences.desiredRetention },
                                    set: {
                                        // Snap to whole percent so the label does not read 89%
                                        // while the stored value is 0.8947.
                                        preferences.desiredRetention = (($0 * 100).rounded()) / 100
                                        dependencies.savePreferences()
                                    }
                                ),
                                in: SchedulerConfig.retentionRange,
                                step: 0.01
                            )
                            .accessibilityValue("\(Int(preferences.desiredRetention * 100)) percent")
                        }
                    } header: {
                        Text("Retention")
                    } footer: {
                        // A raw percentage with no explanation is how users end up setting 97%
                        // and then wondering why they have 400 reviews a day.
                        Text(retentionFooter(preferences.desiredRetention))
                    }
                }

                Section {
                    Picker("Maximum interval", selection: Binding(
                        get: { preferences.maximumIntervalDays },
                        set: {
                            preferences.maximumIntervalDays = $0
                            dependencies.savePreferences()
                        }
                    )) {
                        Text("1 year").tag(365.0)
                        Text("2 years").tag(730.0)
                        Text("5 years").tag(1825.0)
                        Text("10 years").tag(3650.0)
                    }

                    Toggle("Spread review load", isOn: Binding(
                        get: { preferences.fuzzEnabled },
                        set: {
                            preferences.fuzzEnabled = $0
                            dependencies.savePreferences()
                        }
                    ))
                } header: {
                    Text("Intervals")
                } footer: {
                    Text("Spreading nudges each interval by a few percent so words learned on the same day do not all come back on the same day.")
                }

                Section {
                    Text(preferences.learningStepsMinutes.map { IntervalFormatter.short(days: $0 / 1440) }.joined(separator: " → "))
                        .font(Typography.body)
                        .foregroundStyle(Palette.textSecondary)
                } header: {
                    Text("Learning steps")
                } footer: {
                    Text("How a brand-new word is introduced before the algorithm takes over. Editing these is planned for a later release.")
                }

                if preferences.scheduler == .fsrs5 {
                    if dependencies.entitlements.isPlus {
                        NavigationLink("Tune to my memory") { OptimizerSettingsView() }
                    } else {
                        NavigationLink {
                            PlusView()
                        } label: {
                            HStack {
                                Text("Tune to my memory")
                                Spacer()
                                PlusBadge()
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Memory algorithm")
    }

    private func retentionFooter(_ retention: Double) -> String {
        switch retention {
        case ..<0.80:
            "Fewer reviews, more forgetting. Good for a large collection you mainly want passive familiarity with."
        case ..<0.88:
            "A relaxed setting. Noticeably fewer reviews than 90%, and you will forget a little more."
        case ..<0.93:
            "The recommended range. Roughly nine words in ten recalled, for the least work per word retained."
        default:
            "Very high. Expect substantially more reviews for a small gain — each extra percent costs more than the last."
        }
    }
}

// MARK: - Card types

struct CardTypeSettingsView: View {
    @Environment(\.appDependencies) private var dependencies

    var body: some View {
        Form {
            if let preferences = dependencies.preferences {
                Section {
                    ForEach(CardDirection.allCases) { direction in
                        Toggle(isOn: Binding(
                            get: { preferences.enabledDirections.contains(direction) },
                            set: { isOn in
                                var directions = Set(preferences.enabledDirections)
                                if isOn {
                                    directions.insert(direction)
                                } else {
                                    directions.remove(direction)
                                }
                                // The setter sanitises an empty selection back to recognition —
                                // a word with no cards cannot be studied at all.
                                preferences.enabledDirections = CardDirection.allCases.filter {
                                    directions.contains($0)
                                }
                                dependencies.savePreferences()
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(direction.displayName)
                                Text(direction.explanation)
                                    .font(Typography.caption)
                                    .foregroundStyle(Palette.textSecondary)
                            }
                        }
                    }
                } header: {
                    Text("Cards created for each new word")
                } footer: {
                    // Each extra direction is another card per word, so the honest framing is
                    // what it costs as well as what it buys.
                    Text("Each type you add is another card per word. Recognition alone is enough to read; production and in-context cards are what make a word usable when you speak or write. In context is only created for words that have a suitable example sentence. This affects words you add from now on.")
                }
            }
        }
        .navigationTitle("Card types")
    }
}

// MARK: - Languages

struct LanguageSettingsView: View {
    @Environment(\.appDependencies) private var dependencies
    @State private var installing: LearningLanguage?

    var body: some View {
        Form {
            if let preferences = dependencies.preferences {
                Section {
                    ForEach(LearningLanguage.allCases) { language in
                        Button {
                            switchTo(language, preferences: preferences)
                        } label: {
                            HStack(spacing: Spacing.sm) {
                                Text(language.flagEmoji)
                                    .font(.title3)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(language.displayName)
                                        .foregroundStyle(Palette.textPrimary)
                                    Text(language.isFullyStocked
                                        ? language.endonym
                                        : "\(language.endonym) · starter pack")
                                        .font(Typography.caption)
                                        .foregroundStyle(Palette.textSecondary)
                                }
                                Spacer()
                                if installing == language {
                                    ProgressView()
                                } else if preferences.activeLanguage == language {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Palette.brandPrimary)
                                }
                            }
                        }
                        .accessibilityAddTraits(
                            preferences.activeLanguage == language ? [.isSelected, .isButton] : .isButton
                        )
                    }
                } header: {
                    Text("Learning")
                } footer: {
                    Text("Switching language changes what you browse and study. Progress in the other language is kept, not reset.")
                }

                Section {
                    ForEach(preferences.nativeLanguageCodes, id: \.self) { code in
                        Text(Locale.current.localizedString(forLanguageCode: code) ?? code)
                            .foregroundStyle(Palette.textSecondary)
                    }
                } header: {
                    Text("Your languages")
                } footer: {
                    Text("Taken from your device settings, and used to pick which translation to show. Content packs carry English and Chinese translations.")
                }
            }
        }
        .navigationTitle("Languages")
    }

    private func switchTo(_ language: LearningLanguage, preferences: StudyPreferences) {
        guard preferences.activeLanguage != language else { return }
        installing = language
        Task {
            // Import before switching, so the user never lands on an empty dictionary.
            await dependencies.installLanguage(language)
            preferences.activeLanguage = language
            dependencies.savePreferences()
            installing = nil
        }
    }
}

// MARK: - Presentation

struct PresentationSettingsView: View {
    @Environment(\.appDependencies) private var dependencies

    var body: some View {
        Form {
            // Existence check only — every row here binds through `toggle`, which reads
            // `dependencies.preferences` itself so a change is written to the live object
            // rather than to a copy captured when the body ran.
            if dependencies.preferences != nil {
                Section {
                    Toggle("Show pronunciation", isOn: toggle(\.showPhonetics))
                    Toggle("Play audio automatically", isOn: toggle(\.autoPlayAudio))
                } footer: {
                    Text("Audio is generated on device, so it works offline in every language.")
                }

                Section {
                    Toggle("Show next interval on rating buttons", isOn: toggle(\.showIntervalPreview))
                } footer: {
                    Text("Shows what each button would do — “4d”, “9d” — so the schedule never feels arbitrary. Recommended.")
                }

                Section {
                    Toggle("Haptic feedback", isOn: toggle(\.hapticsEnabled))
                }
            }
        }
        .navigationTitle("Presentation")
    }

    private func toggle(_ keyPath: ReferenceWritableKeyPath<StudyPreferences, Bool>) -> Binding<Bool> {
        Binding(
            get: { dependencies.preferences?[keyPath: keyPath] ?? false },
            set: {
                dependencies.preferences?[keyPath: keyPath] = $0
                dependencies.savePreferences()
            }
        )
    }
}

// MARK: - Notifications

struct NotificationSettingsView: View {
    @Environment(\.appDependencies) private var dependencies
    @State private var authorizationDenied = false

    var body: some View {
        Form {
            if let preferences = dependencies.preferences {
                Section {
                    Toggle("Daily review reminder", isOn: Binding(
                        get: { preferences.remindersEnabled },
                        set: { enable(reminders: $0, preferences: preferences) }
                    ))

                    if preferences.remindersEnabled {
                        DatePicker(
                            "Remind me at",
                            selection: Binding(
                                get: {
                                    Calendar.current.date(
                                        from: DateComponents(
                                            hour: preferences.reminderHour,
                                            minute: preferences.reminderMinute
                                        )
                                    ) ?? Date()
                                },
                                set: { newValue in
                                    let parts = Calendar.current.dateComponents([.hour, .minute], from: newValue)
                                    preferences.reminderHour = parts.hour ?? 20
                                    preferences.reminderMinute = parts.minute ?? 0
                                    dependencies.savePreferences()
                                    refreshSchedule(preferences)
                                }
                            ),
                            displayedComponents: .hourAndMinute
                        )

                        Toggle("Morning nudge for new words", isOn: Binding(
                            get: { preferences.dailyWordNotificationEnabled },
                            set: {
                                preferences.dailyWordNotificationEnabled = $0
                                dependencies.savePreferences()
                                refreshSchedule(preferences)
                            }
                        ))
                    }
                } footer: {
                    if authorizationDenied {
                        Text("Notifications are turned off for VocabLoop in iOS Settings. Enable them there first.")
                            .foregroundStyle(Palette.danger)
                    } else {
                        Text("Reminders are scheduled on device — they arrive whether or not you have a signal.")
                    }
                }
            }
        }
        .navigationTitle("Notifications")
    }

    /// Permission is requested here, at the moment the user asks for reminders — never at
    /// launch, which is how apps get permanently denied.
    private func enable(reminders: Bool, preferences: StudyPreferences) {
        guard reminders else {
            preferences.remindersEnabled = false
            dependencies.savePreferences()
            dependencies.notifications.cancelAll()
            return
        }
        Task {
            let granted = await dependencies.notifications.requestAuthorization()
            authorizationDenied = !granted
            preferences.remindersEnabled = granted
            dependencies.savePreferences()
            if granted { refreshSchedule(preferences) }
        }
    }

    private func refreshSchedule(_ preferences: StudyPreferences) {
        Task {
            // The count only decorates the notification body, so a missing account means
            // "schedule it without a count" rather than "do not schedule".
            var dueToday = 0
            if let account = dependencies.account {
                dueToday = (try? dependencies.stats.statistics(
                    for: account, preferences: preferences
                ).dueToday) ?? 0
            }
            await dependencies.notifications.refreshSchedule(
                preferences: preferences, dueCount: dueToday
            )
        }
    }
}

// MARK: - Data

struct DataSettingsView: View {
    @Environment(\.appDependencies) private var dependencies
    @State private var isReimporting = false
    @State private var isConfirmingDiscard = false

    var body: some View {
        Form {
            Section("Storage") {
                LabeledContent("On this device", value: formattedSize)
            }

            Section {
                LabeledContent("Status", value: syncStatusText)
                if dependencies.sync.pendingCount() > 0 {
                    LabeledContent("Waiting to sync", value: "\(dependencies.sync.pendingCount()) changes")
                }
                if case .failed = dependencies.sync.status {
                    Button("Discard pending changes", role: .destructive) {
                        isConfirmingDiscard = true
                    }
                }
            } header: {
                Text("Sync")
            } footer: {
                // Be straight about it. A "Sync" section that silently does nothing is worse
                // than one that says why.
                Text(dependencies.sync.status.isDisabled
                    ? "There is no VocabLoop server in this build, so nothing leaves your device. Your changes are still recorded and would upload if an account server were configured."
                    : "Changes upload in the background whenever you have a connection. Nothing in the app ever waits for it.")
            }

            Section {
                Button {
                    isReimporting = true
                    Task {
                        await dependencies.reimportContent()
                        isReimporting = false
                    }
                } label: {
                    HStack {
                        Text("Re-import dictionary")
                        if isReimporting {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(isReimporting)
            } header: {
                Text("Content")
            } footer: {
                Text("Rebuilds the bundled dictionary. Your progress, your own words and your review history are untouched.")
            }

            if let error = dependencies.contentImportError {
                Section {
                    Text(error)
                        .font(Typography.caption)
                        .foregroundStyle(Palette.danger)
                } header: {
                    Text("Last import problem")
                }
            }
        }
        .navigationTitle("Storage and sync")
        .alert("Discard pending changes?", isPresented: $isConfirmingDiscard) {
            Button("Discard", role: .destructive) { dependencies.sync.discardPending() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Changes that have not reached the server will be lost. Your local data stays as it is.")
        }
    }

    private var formattedSize: String {
        ByteCountFormatter.string(
            fromByteCount: PersistenceController.storeSizeInBytes(),
            countStyle: .file
        )
    }

    private var syncStatusText: String {
        switch dependencies.sync.status {
        case .disabled: "Local only"
        case .idle(let date):
            date.map { "Synced \($0.formatted(.relative(presentation: .named)))" } ?? "Up to date"
        case .pending(let count): "\(count) changes pending"
        case .syncing(let progress): "Syncing… \(Int(progress * 100))%"
        case .failed(_, let reason): "Stalled — \(reason)"
        }
    }
}

// MARK: - About

struct AboutView: View {
    @Environment(\.openURL) private var openURL

    private var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Version", value: version)
            }

            Section {
                Button("Contact support") { openURL(AppLinks.supportMail) }
                if let support = AppLinks.support {
                    Button("Help and FAQ") { openURL(support) }
                }
                if let privacy = AppLinks.privacyPolicy {
                    Button("Privacy Policy") { openURL(privacy) }
                }
                if let terms = AppLinks.termsOfUse {
                    Button("Terms of Use") { openURL(terms) }
                }
            } footer: {
                Text(AppLinks.supportEmail)
            }

            Section {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("How scheduling works")
                        .font(Typography.sectionHeader)
                    Text("VocabLoop schedules reviews with FSRS — the Free Spaced Repetition Scheduler. It models three things about every word: how hard the word is for you, how stable your memory of it is, and how much of it you have forgotten right now.")
                        .font(Typography.body)
                        .foregroundStyle(Palette.textSecondary)
                    Text("Because it models forgetting directly, it can aim at a retention rate you choose rather than at a fixed ladder of intervals. Every review you do is recorded, which is what would let a future version fit the model to you personally.")
                        .font(Typography.body)
                        .foregroundStyle(Palette.textSecondary)
                }
                .padding(.vertical, Spacing.xxs)
            }

            Section {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("Offline by design")
                        .font(Typography.sectionHeader)
                    Text("The dictionary, the scheduler, your statistics and the pronunciation audio all live on your device. There is nothing to load and nothing to wait for.")
                        .font(Typography.body)
                        .foregroundStyle(Palette.textSecondary)
                }
                .padding(.vertical, Spacing.xxs)
            }
        }
        .navigationTitle("About")
    }
}

#Preview {
    SettingsView()
}
