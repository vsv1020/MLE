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
                    title: "找不到这个单词",
                    message: "这个单词可能已被删除，或者它所在的词库已经不在了。"
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
    /// Mochi on the word's share card.
    @State private var shareLook: MochiLook = .default

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
        .toolbar {
            // Bundled dictionary words only: `WordCard.make` refuses a user-created entry, which
            // can contain anything a child typed.
            ToolbarItem(placement: .primaryAction) {
                if let wordCard = WordCard.make(from: entry, look: shareLook) {
                    ShareCardButton(card: .word(wordCard), label: "分享这个单词", style: .toolbar)
                }
            }
        }
        .task { shareLook = dependencies.engagement.currentLook() }
        .confirmationDialog(
            "重置“\(entry.headword)”的学习进度？",
            isPresented: $isShowingResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("重置为新词", role: .destructive) {
                perform { try $0.resetProgress(for: entry) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("卡片会变回没学过的状态。以前的复习记录会保留，用于统计。")
        }
        .alert("没有成功", isPresented: Binding(
            get: { actionError != nil },
            set: { if !$0 { actionError = nil } }
        )) {
            Button("好") { actionError = nil }
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
                    Chip("词频第 \(rank) 位", systemImage: "chart.bar")
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
                Label("已在你的单词里", systemImage: "checkmark.circle.fill")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.success)
                Spacer()
                Menu {
                    Button("重置学习进度", role: .destructive) {
                        isShowingResetConfirmation = true
                    }
                    Button(isSuspended ? "继续学习" : "暂停学习") {
                        let shouldSuspend = !isSuspended
                        perform { try $0.setSuspended(shouldSuspend, for: entry) }
                    }
                    Button("从我的单词中移除", role: .destructive) {
                        perform { try $0.unenroll(entry: entry) }
                    }
                } label: {
                    Label("管理", systemImage: "ellipsis.circle")
                        .font(Typography.caption)
                }
            }
        } else {
            PrimaryButton("加入我的单词", systemImage: "plus") {
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
        // Seeded per sense, not per screen. This one is called inside a `ForEach`, so a fixed
        // seed would draw the identical outline on every sense card — the "one stamp repeated"
        // failure that `WobbleShape.seed` exists to avoid.
        CardContainer(
            isRaised: true,
            style: .crayon,
            wobbleSeed: WobbleShape.seed(for: "\(entry.stableID)#sense\(sense.order)")
        ) {
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
                    wordList("近义词", sense.synonyms, color: Palette.brandSecondary)
                }
                if !sense.antonyms.isEmpty {
                    wordList("反义词", sense.antonyms, color: Palette.warning)
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
        CardContainer(isRaised: true, style: .crayon, wobbleSeed: 0xE47D_0002) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("语法")
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
        CardContainer(isRaised: true, style: .crayon, wobbleSeed: 0xE47D_0003) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("复习安排")
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
                                Chip("已暂停", color: Palette.warning)
                            }
                        }
                        .foregroundStyle(Palette.textSecondary)

                        HStack(spacing: Spacing.md) {
                            schedulingValue(IntervalFormatter.dueDescription(due: card.due), label: "下次")
                            schedulingValue(IntervalFormatter.short(days: card.intervalDays), label: "间隔")
                        }
                        HStack(spacing: Spacing.md) {
                            // The model's own numbers, shown plainly. "Stability" is FSRS's S:
                            // days until recall drops to 90%.
                            schedulingValue(String(format: "%.1f 天", card.stability), label: "稳定度")
                            schedulingValue(String(format: "%.1f", card.difficulty), label: "难度")
                            schedulingValue("\(card.reps)", label: "复习次数")
                            schedulingValue("\(card.lapses)", label: "遗忘次数")
                        }
                    }
                    .padding(.vertical, Spacing.xxs)
                    if card.cardID != entry.cards.last?.cardID {
                        Divider().background(Palette.separator)
                    }
                }
                Text("复习安排由 \(entry.cards.first?.scheduler.displayName ?? SchedulerKind.fsrs5.displayName) 计算。")
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
        .accessibilityLabel("\(label)：\(value)")
    }

    private var historyCard: some View {
        CardContainer(isRaised: true, style: .crayon, wobbleSeed: 0xE47D_0004) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("复习记录")
                    .font(Typography.sectionHeader)
                let logs = entry.cards
                    .flatMap(\.reviews)
                    .sorted { $0.reviewedAt > $1.reviewedAt }
                    .prefix(20)

                if logs.isEmpty {
                    Text("还没有复习记录。")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                } else {
                    ForEach(Array(logs)) { log in
                        HStack(spacing: Spacing.xs) {
                            // The dot is 8pt and the fill is a 400 weight, so on a light surface it
                            // is 1.46:1 at worst — invisible. The edge is what makes it a dot.
                            // Bumped to 9pt so a 1pt stroke does not eat most of the fill.
                            Circle()
                                .fill(Palette.rating(log.rating))
                                .overlay(Circle().strokeBorder(Palette.ratingEdge(log.rating), lineWidth: 1))
                                .frame(width: 9, height: 9)
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
                            Text("记住概率 \(Int(log.retrievabilityBefore * 100))%")
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
