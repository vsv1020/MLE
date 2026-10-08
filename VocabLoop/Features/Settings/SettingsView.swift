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
                            Text(dependencies.entitlements.isPlus ? "麻薯 Plus · 已解锁" : "麻薯 Plus")
                        } icon: {
                            Image(systemName: "sparkles").foregroundStyle(Palette.brandSecondary)
                        }
                    }
                    .accessibilityIdentifier("settings.plus")
                }

                Section {
                    DailyGoalStepper()
                } header: {
                    Text("每日目标")
                } footer: {
                    Text("达成目标会有小庆祝，然后你可以选择停下或继续背。设为 0 就是不设目标。")
                }

                Section("学习") {
                    NavigationLink("每日计划") { DailyTargetsView() }
                    NavigationLink("复习算法") { SchedulerSettingsView() }
                    NavigationLink("卡片类型") { CardTypeSettingsView() }
                }

                Section("内容") {
                    NavigationLink("语言") { LanguageSettingsView() }
                    NavigationLink("显示与声音") { PresentationSettingsView() }
                }

                Section("提醒") {
                    NavigationLink("通知") { NotificationSettingsView() }
                }

                Section {
                    NavigationLink {
                        ParentGateView()
                    } label: {
                        Label {
                            Text("家长报告")
                        } icon: {
                            Image(systemName: "person.2.fill").foregroundStyle(Palette.brandPrimary)
                        }
                    }
                } header: {
                    Text("给家长")
                } footer: {
                    Text("给大人看的每周总结，先做一道简单的算术题才能打开。全部在这台设备上计算，不会发送到任何地方。")
                }

                Section("数据") {
                    NavigationLink("存储与同步") { DataSettingsView() }
                }

                Section {
                    NavigationLink("关于麻薯背单词") { AboutView() }
                } footer: {
                    Text("麻薯背单词完全可以离线使用。复习、统计、发音和整部词典都不需要网络。")
                }
            }
            .navigationTitle("设置")
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
                Text(dependencies.auth.current?.displayName ?? "游客")
                    .font(Typography.bodyEmphasis)
                    .foregroundStyle(Palette.textPrimary)
                Text(dependencies.auth.isGuest
                    ? "正在以游客身份学习"
                    : dependencies.auth.current?.email ?? "已登录")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Daily targets

/// The daily goal, in cards. Shared by Settings and Daily targets so the two never disagree.
///
/// Reaches 0 on purpose — that is how a goal is *removed*.
struct DailyGoalStepper: View {
    @Environment(\.appDependencies) private var dependencies

    var body: some View {
        let goal = dependencies.preferences?.dailyGoal ?? 0
        Stepper(value: Binding(
            get: { dependencies.preferences?.dailyGoal ?? 0 },
            set: { newValue in
                dependencies.preferences?.dailyGoal = newValue
                dependencies.savePreferences()
            }
        ), in: 0...500, step: 5) {
            Text(goal > 0 ? "每天 \(goal) 张卡片" : "不设每日目标")
        }
    }
}

struct DailyTargetsView: View {
    @Environment(\.appDependencies) private var dependencies

    var body: some View {
        Form {
            if let preferences = dependencies.preferences {
                Section {
                    DailyGoalStepper()
                } footer: {
                    Text("可选。设了目标，“今天”页的圆环会朝它慢慢填满；不设目标就没有倒计时，想学多久就学多久。修改目标不会影响已经完成的日子。")
                }

                Section {
                    Stepper(
                        "每天新词：\(preferences.newWordsPerDay)",
                        value: binding(\.newWordsPerDay), in: 0...50
                    )
                } footer: {
                    Text("每个新词在第一个月里大约要复习四次。设为 0 可以暂停学新词，连续打卡不会中断。")
                }

                Section {
                    Stepper(
                        "每轮卡片：\(preferences.maxReviewsPerSession)",
                        value: binding(\.maxReviewsPerSession), in: 10...500, step: 10
                    )
                } footer: {
                    Text("限制一轮学习的数量，积压的卡片会分成一轮一轮来，不会一下子全压过来。超出上限的卡片仍然待复习。")
                }

                Section {
                    Picker("每天开始于", selection: binding(\.dayStartHour)) {
                        ForEach(0..<12) { hour in
                            Text(hour == 0 ? "午夜 0:00" : "\(hour):00").tag(hour)
                        }
                    }
                } footer: {
                    Text("学习日从什么时候算起。默认凌晨 4 点，所以深夜学习仍然算在开始的那一天。")
                }
            }
        }
        .navigationTitle("每日计划")
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
                    Text("算法")
                } footer: {
                    Text("切换算法会保留你的复习记录，已有的卡片会接着当前进度继续。")
                }

                if preferences.scheduler == .fsrs5 {
                    Section {
                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            HStack {
                                Text("目标记住率")
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
                            .accessibilityValue("百分之 \(Int(preferences.desiredRetention * 100))")
                        }
                    } header: {
                        Text("记住率")
                    } footer: {
                        // A raw percentage with no explanation is how users end up setting 97%
                        // and then wondering why they have 400 reviews a day.
                        Text(retentionFooter(preferences.desiredRetention))
                    }
                }

                Section {
                    Picker("最长间隔", selection: Binding(
                        get: { preferences.maximumIntervalDays },
                        set: {
                            preferences.maximumIntervalDays = $0
                            dependencies.savePreferences()
                        }
                    )) {
                        Text("1 年").tag(365.0)
                        Text("2 年").tag(730.0)
                        Text("5 年").tag(1825.0)
                        Text("10 年").tag(3650.0)
                    }

                    Toggle("分散复习量", isOn: Binding(
                        get: { preferences.fuzzEnabled },
                        set: {
                            preferences.fuzzEnabled = $0
                            dependencies.savePreferences()
                        }
                    ))
                } header: {
                    Text("间隔")
                } footer: {
                    Text("把每个间隔随机调整几个百分点，同一天学的单词就不会全挤在同一天回来复习。")
                }

                Section {
                    Text(preferences.learningStepsMinutes.map { IntervalFormatter.short(days: $0 / 1440) }.joined(separator: " → "))
                        .font(Typography.body)
                        .foregroundStyle(Palette.textSecondary)
                } header: {
                    Text("学习步骤")
                } footer: {
                    Text("全新的单词在交给算法之前是怎样引入的。以后的版本会支持修改。")
                }

                if preferences.scheduler == .fsrs5 {
                    if dependencies.entitlements.isPlus {
                        NavigationLink("按我的记忆调节") { OptimizerSettingsView() }
                    } else {
                        NavigationLink {
                            PlusView()
                        } label: {
                            HStack {
                                Text("按我的记忆调节")
                                Spacer()
                                PlusBadge()
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("复习算法")
    }

    private func retentionFooter(_ retention: Double) -> String {
        switch retention {
        case ..<0.80:
            "复习更少，忘得也更多。适合词量很大、只想混个眼熟的情况。"
        case ..<0.88:
            "轻松的设置。复习量明显比 90% 少，也会多忘一点。"
        case ..<0.93:
            "推荐范围。十个单词大约能记住九个，每记住一个词花的功夫最少。"
        default:
            "非常高。复习量会多出很多，收获却不大，每多 1% 都比上一个 1% 更费劲。"
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
                    Text("每个新词生成的卡片")
                } footer: {
                    // Each extra direction is another card per word, so the honest framing is
                    // what it costs as well as what it buys.
                    Text("每多选一种类型，每个单词就多一张卡片。只练认词就够阅读；练拼写和语境卡片，才能在说和写的时候用得出来。语境卡片只会为有合适例句的单词生成。此设置只影响之后添加的单词。")
                }
            }
        }
        .navigationTitle("卡片类型")
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
                                        : "\(language.endonym) · 入门词库")
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
                    Text("正在学")
                } footer: {
                    Text("切换语言会改变你浏览和学习的内容。另一种语言的进度会保留，不会清零。")
                }

                Section {
                    ForEach(preferences.nativeLanguageCodes, id: \.self) { code in
                        Text(Locale.current.localizedString(forLanguageCode: code) ?? code)
                            .foregroundStyle(Palette.textSecondary)
                    }
                } header: {
                    Text("你的语言")
                } footer: {
                    Text("取自设备设置，用来决定显示哪种翻译。词库带有英文和中文翻译。")
                }
            }
        }
        .navigationTitle("语言")
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
    /// A device setting rather than a preference: whether this phone shows the session on its
    /// Lock Screen is nobody else's business, and it is not worth a schema change.
    @AppStorage(StudyActivityController.enabledKey) private var liveActivityEnabled = true

    var body: some View {
        Form {
            // Existence check only — every row here binds through `toggle`, which reads
            // `dependencies.preferences` itself so a change is written to the live object
            // rather than to a copy captured when the body ran.
            if dependencies.preferences != nil {
                Section {
                    Toggle("显示音标", isOn: toggle(\.showPhonetics))
                    Toggle("自动播放发音", isOn: toggle(\.autoPlayAudio))
                } footer: {
                    Text("发音在设备上生成，所以每种语言都能离线使用。")
                }

                Section {
                    Toggle("在评分按钮上显示下次间隔", isOn: toggle(\.showIntervalPreview))
                } footer: {
                    Text("显示每个按钮会把下次复习安排在多久之后，比如“4 天”“9 天”，复习安排就不会显得莫名其妙。推荐打开。")
                }

                Section {
                    Toggle("触感反馈", isOn: toggle(\.hapticsEnabled))
                    Toggle("音效", isOn: toggle(\.soundEffectsEnabled))
                } footer: {
                    Text("答对、连击和得到奖励时会有小小的提示音。忘了单词时从不出声，静音开关打开时一律静音。")
                }

                Section {
                    Toggle("在锁定屏幕上显示进度", isOn: $liveActivityEnabled)
                        .onChange(of: liveActivityEnabled) { _, isOn in
                            // Off means gone now, not at the end of the session.
                            if !isOn { dependencies.liveActivity.endAllImmediately() }
                        }
                } footer: {
                    Text("学习时在灵动岛和锁定屏幕上显示今天的目标。")
                }

                Section {
                    Toggle("小测验题目", isOn: toggle(\.quizModesEnabled))
                } footer: {
                    Text("在复习已认识的单词时，穿插选释义、听力和拼写题。新词总是先以普通卡片出现。关闭后每张卡片都由你自己评分。")
                }
            }
        }
        .navigationTitle("显示与声音")
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
                    Toggle("每日复习提醒", isOn: Binding(
                        get: { preferences.remindersEnabled },
                        set: { enable(reminders: $0, preferences: preferences) }
                    ))

                    if preferences.remindersEnabled {
                        DatePicker(
                            "提醒时间",
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

                        Toggle("早上提醒学新词", isOn: Binding(
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
                        Text("iOS 设置里关闭了麻薯背单词的通知，请先去那里打开。")
                            .foregroundStyle(Palette.danger)
                    } else {
                        Text("提醒是在设备上安排的，有没有信号都能收到。")
                    }
                }

                // Only offered while reminders are on: the scheduler requires `remindersEnabled`,
                // so with the daily reminder off this toggle would do nothing at all.
                if preferences.remindersEnabled {
                    Section {
                        Toggle("连续打卡提醒", isOn: Binding(
                            get: { preferences.streakReminderEnabled },
                            set: { setStreakReminder($0, preferences: preferences) }
                        ))
                    } footer: {
                        Text("傍晚一条温柔的提醒：只在当天还没学习、而且已经连续打卡 2 天以上时才会发。每天最多一次。")
                    }
                }
            }
        }
        .navigationTitle("通知")
    }

    /// Saved first, so the choice sticks even if the permission prompt is declined. Permission
    /// is asked only when turning it on — the same rule as the daily reminder.
    private func setStreakReminder(_ isOn: Bool, preferences: StudyPreferences) {
        preferences.streakReminderEnabled = isOn
        dependencies.savePreferences()
        Task {
            if isOn {
                let granted = await dependencies.notifications.requestAuthorization()
                authorizationDenied = !granted
            }
            await dependencies.engagement.refreshStreakReminder(preferences: preferences, now: Date())
        }
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
            // `refreshSchedule` clears the streak nudge along with everything else; put it back
            // with the real streak rather than leaving it off until the next trip to background.
            await dependencies.engagement.refreshStreakReminder(preferences: preferences, now: Date())
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
            Section("存储") {
                LabeledContent("本机占用", value: formattedSize)
            }

            Section {
                LabeledContent("状态", value: syncStatusText)
                if dependencies.sync.pendingCount() > 0 {
                    LabeledContent("等待同步", value: "\(dependencies.sync.pendingCount()) 项更改")
                }
                if case .failed = dependencies.sync.status {
                    Button("放弃待同步的更改", role: .destructive) {
                        isConfirmingDiscard = true
                    }
                }
            } header: {
                Text("同步")
            } footer: {
                // Be straight about it. A "Sync" section that silently does nothing is worse
                // than one that says why.
                Text(dependencies.sync.status.isDisabled
                    ? "这个版本没有麻薯背单词服务器，所以任何数据都不会离开你的设备。你的更改仍会被记录，配置好账号服务器后就会上传。"
                    : "有网络时，更改会在后台上传。App 里的任何操作都不用等它。")
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
                        Text("重新导入词典")
                        if isReimporting {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(isReimporting)
            } header: {
                Text("内容")
            } footer: {
                Text("重建内置词典。你的进度、你自己添加的单词和复习记录都不会受影响。")
            }

            if let error = dependencies.contentImportError {
                Section {
                    Text(error)
                        .font(Typography.caption)
                        .foregroundStyle(Palette.danger)
                } header: {
                    Text("上次导入的问题")
                }
            }
        }
        .navigationTitle("存储与同步")
        .alert("放弃待同步的更改？", isPresented: $isConfirmingDiscard) {
            Button("放弃", role: .destructive) { dependencies.sync.discardPending() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("还没上传到服务器的更改会丢失，本机数据保持不变。")
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
        case .disabled: "仅存本机"
        case .idle(let date):
            date.map { "已同步（\($0.formatted(.relative(presentation: .named)))）" } ?? "已是最新"
        case .pending(let count): "\(count) 项更改待同步"
        case .syncing(let progress): "正在同步… \(Int(progress * 100))%"
        case .failed(_, let reason): "同步卡住了：\(reason)"
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
                LabeledContent("版本", value: version)
            }

            Section {
                Button("联系我们") { openURL(AppLinks.supportMail) }
                if let support = AppLinks.support {
                    Button("帮助与常见问题") { openURL(support) }
                }
                if let privacy = AppLinks.privacyPolicy {
                    Button("隐私政策") { openURL(privacy) }
                }
                if let terms = AppLinks.termsOfUse {
                    Button("使用条款") { openURL(terms) }
                }
            } footer: {
                Text(AppLinks.supportEmail)
            }

            Section {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("复习是怎样安排的")
                        .font(Typography.sectionHeader)
                    Text("麻薯背单词用 FSRS（自由间隔重复算法）来安排复习。它为每个单词估算三件事：这个词对你有多难、你对它的记忆有多牢，以及你现在已经忘了多少。")
                        .font(Typography.body)
                        .foregroundStyle(Palette.textSecondary)
                    Text("因为它直接估算遗忘，所以能瞄准你选的记住率，而不是套用固定的间隔阶梯。你的每次复习都会被记录下来，以后的版本就能据此为你个人调整模型。")
                        .font(Typography.body)
                        .foregroundStyle(Palette.textSecondary)
                }
                .padding(.vertical, Spacing.xxs)
            }

            Section {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("天生离线")
                        .font(Typography.sectionHeader)
                    Text("词典、复习安排、统计数据和发音全都在你的设备上。不用加载，也不用等待。")
                        .font(Typography.body)
                        .foregroundStyle(Palette.textSecondary)
                }
                .padding(.vertical, Spacing.xxs)
            }
        }
        .navigationTitle("关于")
    }
}

#Preview {
    SettingsView()
}
