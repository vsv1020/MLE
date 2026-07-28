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
                        title: "No decks yet",
                        message: "The \(language.displayName) content packs have not been imported. Try re-importing from Settings ▸ Data."
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
                        Text("Content packs")
                    } footer: {
                        Text("Turning a pack off stops new words being offered from it. Words you are already studying are unaffected.")
                    }
                }

                let custom = visibleDecks.filter { !$0.isBuiltIn }
                if !custom.isEmpty {
                    Section("Your decks") {
                        ForEach(custom) { deck in
                            NavigationLink(value: deck.slug) {
                                DeckRow(deck: deck)
                            }
                        }
                        .onDelete(perform: deleteCustomDecks)
                    }
                }
            }
            .navigationTitle("Decks")
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
                    .accessibilityLabel("New deck")
                }
            }
            .alert("New deck", isPresented: $isShowingNewDeck) {
                TextField("Deck name", text: $newDeckName)
                Button("Create") { createDeck() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("A place to group words you want to study together.")
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
                Text("\(deck.enrolledCount) of \(deck.entryCount) words started")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
                ProgressView(value: deck.progress)
                    .tint(Color(hexString: deck.colorHex) ?? Palette.brandPrimary)
            }

            if !deck.isActiveForNewWords {
                Chip("Paused", color: Palette.warning)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(deck.name). \(deck.enrolledCount) of \(deck.entryCount) words started."
                + (deck.isActiveForNewWords ? "" : " Paused.")
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
                    title: "Deck not found",
                    message: "This deck may have been deleted."
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
                        StatTile(value: "\(deck.entryCount)", label: "Words")
                        StatTile(
                            value: "\(deck.enrolledCount)",
                            label: "Started",
                            tint: Palette.brandSecondary
                        )
                        StatTile(value: "\(dueCount)", label: "Due now", tint: Palette.brandPrimary)
                    }
                    PrimaryButton("Study this deck", isEnabled: deck.enrolledCount > 0) {
                        isStudying = true
                    }
                    Toggle("Offer new words from this deck", isOn: Binding(
                        get: { deck.isActiveForNewWords },
                        set: { newValue in
                            deck.isActiveForNewWords = newValue
                            deck.updatedAt = Date()
                            try? dependencies.context.save()
                        }
                    ))
                    .font(Typography.body)
                }
                .padding(.vertical, Spacing.xxs)
            }

            Section("Words") {
                ForEach(sortedEntries) { entry in
                    NavigationLink {
                        EntryDetailView(entry: entry)
                    } label: {
                        EntryRow(entry: entry, matchedInDefinition: false)
                    }
                }
            }
        }
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
