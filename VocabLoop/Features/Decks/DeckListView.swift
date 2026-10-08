import SwiftUI
import SwiftData

/// Content packs and the user's own lists.
///
/// Decks scope *what may be introduced*, not what is due. Reviews always draw from everything
/// the user has enrolled, because splitting reviews by deck is how people end up with a
/// backlog hidden in the deck they stopped opening.
struct DeckListView: View {
    @Environment(\.appDependencies) private var dependencies
    @Query(sort: \Deck.sortOrder) private var decks: [Deck]

    @State private var isShowingNewDeck = false
    @State private var newDeckName = ""

    private var language: LearningLanguage {
        dependencies.preferences?.activeLanguage ?? .english
    }

    private var visibleDecks: [Deck] {
        decks.filter { $0.languageCode == language.rawValue }
    }

    var body: some View {
        NavigationStack {
            List {
                if visibleDecks.isEmpty {
                    EmptyStateView(
                        systemImage: "square.stack.3d.up",
                        title: "还没有词库",
                        message: "\(language.displayName)词库还没有导入。可以到“设置 ▸ 数据”里重新导入。"
                    )
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }

                let builtIn = visibleDecks.filter(\.isBuiltIn)
                if !builtIn.isEmpty {
                    Section {
                        ForEach(builtIn) { deck in
                            NavigationLink(value: deck.slug) {
                                DeckRow(deck: deck)
                            }
                        }
                    } header: {
                        Text("内置词库")
                    } footer: {
                        Text("关掉一个词库后，就不会再从里面推荐新词。正在学的单词不受影响。")
                    }
                }

                let custom = visibleDecks.filter { !$0.isBuiltIn }
                if !custom.isEmpty {
                    Section("你的词库") {
                        ForEach(custom) { deck in
                            NavigationLink(value: deck.slug) {
                                DeckRow(deck: deck)
                            }
                        }
                        .onDelete(perform: deleteCustomDecks)
                    }
                }
            }
            .navigationTitle("词库")
            .navigationDestination(for: String.self) { slug in
                DeckDetailScreen(slug: slug)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        newDeckName = ""
                        isShowingNewDeck = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("新建词库")
                }
            }
            .alert("新建词库", isPresented: $isShowingNewDeck) {
                TextField("词库名称", text: $newDeckName)
                Button("创建") { createDeck() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("把想一起学的单词放在一起。")
            }
        }
    }

    private func createDeck() {
        let name = newDeckName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let deck = Deck(
            slug: Deck.userDeckSlug(),
            name: name,
            languageCode: language.rawValue,
            isBuiltIn: false,
            // After the built-ins, so packs stay at the top where users expect them.
            sortOrder: 100 + visibleDecks.count,
            symbolName: "star"
        )
        dependencies.context.insert(deck)
        try? dependencies.context.save()
    }

    /// Only user decks are deletable. Built-ins are recreated by seed import anyway, so
    /// offering to delete one would be a button that does not work.
    private func deleteCustomDecks(at offsets: IndexSet) {
        let custom = visibleDecks.filter { !$0.isBuiltIn }
        for index in offsets where custom.indices.contains(index) {
            dependencies.context.delete(custom[index])
        }
        try? dependencies.context.save()
    }
}

struct DeckRow: View {
    let deck: Deck

    @Environment(\.appDependencies) private var dependencies
    private var isLocked: Bool { deck.requiresPlus && !dependencies.entitlements.isPlus }

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: deck.symbolName)
                .font(.title3)
                .foregroundStyle(Color(hexString: deck.colorHex) ?? Palette.brandPrimary)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(deck.name)
                    .font(Typography.bodyEmphasis)
                    .foregroundStyle(Palette.textPrimary)
                Text("已开始学 \(deck.enrolledCount)/\(deck.entryCount) 个单词")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
                ProgressView(value: deck.progress)
                    .tint(Color(hexString: deck.colorHex) ?? Palette.brandPrimary)
            }

            if isLocked {
                PlusBadge()
            } else if !deck.isActiveForNewWords {
                Chip("已暂停", color: Palette.warning)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(deck.name)。\(deck.entryCount) 个单词中已开始学 \(deck.enrolledCount) 个。"
                + (isLocked ? "需要麻薯 Plus。" : deck.isActiveForNewWords ? "" : "已暂停。")
        )
    }
}

/// Resolves a slug so navigation can push by value.
struct DeckDetailScreen: View {
    let slug: String

    @Environment(\.appDependencies) private var dependencies
    @State private var deck: Deck?

    var body: some View {
        Group {
            if let deck {
                DeckDetailView(deck: deck)
            } else {
                EmptyStateView(
                    systemImage: "questionmark.folder",
                    title: "找不到这个词库",
                    message: "这个词库可能已被删除。"
                )
            }
        }
        .task { deck = try? dependencies.context.deck(slug: slug) }
    }
}

struct DeckDetailView: View {
    let deck: Deck

    @Environment(\.appDependencies) private var dependencies
    @State private var isStudying = false
    @State private var isShowingPlus = false

    private var isLocked: Bool { deck.requiresPlus && !dependencies.entitlements.isPlus }

    private var sortedEntries: [Entry] {
        deck.entries.sorted {
            let a = $0.frequencyRank ?? Int.max
            let b = $1.frequencyRank ?? Int.max
            return a == b ? $0.normalizedHeadword < $1.normalizedHeadword : a < b
        }
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    if !deck.summary.isEmpty {
                        Text(deck.summary)
                            .font(Typography.body)
                            .foregroundStyle(Palette.textSecondary)
                    }
                    HStack(spacing: Spacing.xs) {
                        StatTile(value: "\(deck.entryCount)", label: "单词")
                        StatTile(
                            value: "\(deck.enrolledCount)",
                            label: "已开始",
                            tint: Palette.brandSecondary
                        )
                        StatTile(value: "\(dueCount)", label: "待复习", tint: Palette.brandPrimary)
                    }
                    PrimaryButton("学习这个词库", isEnabled: deck.enrolledCount > 0) {
                        isStudying = true
                    }
                    if isLocked {
                        // Browsing the words stays open — it is how anyone decides the pack is
                        // worth it. Only *introducing* them waits for Plus.
                        PrimaryButton("解锁麻薯 Plus，学习这个词库", systemImage: "sparkles", role: .secondary) {
                            isShowingPlus = true
                        }
                    } else {
                        Toggle("从这个词库推荐新词", isOn: Binding(
                            get: { deck.isActiveForNewWords },
                            set: { newValue in
                                deck.isActiveForNewWords = newValue
                                deck.updatedAt = Date()
                                try? dependencies.context.save()
                            }
                        ))
                        .font(Typography.body)
                    }
                }
                .padding(.vertical, Spacing.xxs)
            }

            Section("单词") {
                ForEach(sortedEntries) { entry in
                    NavigationLink {
                        EntryDetailView(entry: entry)
                    } label: {
                        EntryRow(entry: entry, matchedInDefinition: false)
                    }
                }
            }
        }
        .sheet(isPresented: $isShowingPlus) { NavigationStack { PlusView() } }
        .navigationTitle(deck.name)
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $isStudying) {
            StudySessionView(
                options: ReviewQueueBuilder.Options(
                    maxCards: dependencies.preferences?.maxReviewsPerSession ?? 60,
                    maxNewCards: dependencies.preferences?.newWordsPerDay ?? 8,
                    languageCode: deck.languageCode,
                    deckSlug: deck.slug,
                    // Studying one deck on purpose is exactly when studying ahead makes
                    // sense, so it is allowed here but not on Today.
                    includeAhead: true
                )
            )
        }
    }

    private var dueCount: Int {
        let now = Date()
        return deck.entries.reduce(0) { total, entry in
            total + entry.cards.filter { $0.isDue(at: now) }.count
        }
    }
}

#Preview {
    DeckListView()
}
