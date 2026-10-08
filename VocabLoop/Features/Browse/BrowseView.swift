import SwiftUI
import SwiftData

/// The dictionary.
///
/// Browsing does **not** enrol a word. That is the rule that keeps the review queue under the
/// user's control — a dictionary you can read without committing to studying everything you
/// look at.
struct BrowseView: View {
    @Environment(\.appDependencies) private var dependencies

    @State private var filter = BrowseFilter()
    @State private var results: [SearchService.Result] = []
    @State private var recentlyViewed: [Entry] = []
    @State private var isShowingFilters = false
    @State private var isShowingAddWord = false
    @State private var errorMessage: String?

    private var language: LearningLanguage {
        dependencies.preferences?.activeLanguage ?? .english
    }

    var body: some View {
        NavigationStack {
            List {
                if filter.isEmpty && !recentlyViewed.isEmpty {
                    Section("最近看过") {
                        ForEach(recentlyViewed) { entry in
                            NavigationLink(value: entry.stableID) {
                                EntryRow(entry: entry, matchedInDefinition: false)
                            }
                        }
                    }
                }

                Section {
                    if results.isEmpty {
                        emptyState
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    } else {
                        ForEach(results) { result in
                            NavigationLink(value: result.entry.stableID) {
                                EntryRow(entry: result.entry, matchedInDefinition: result.matchedInDefinition)
                            }
                        }
                    }
                } header: {
                    if !results.isEmpty {
                        Text(resultsHeader)
                    }
                }
            }
            .listStyle(.plain)
            .searchable(
                text: $filter.query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "搜索\(language.displayName)单词或释义"
            )
            .navigationTitle("浏览")
            .navigationDestination(for: String.self) { stableID in
                EntryDetailScreen(stableID: stableID)
            }
            .safeAreaInset(edge: .top) { filterChips }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isShowingAddWord = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("添加自己的单词")
                }
            }
            .sheet(isPresented: $isShowingAddWord, onDismiss: reload) {
                NavigationStack { AddWordView(language: language) }
            }
            .task { reload() }
            .onChange(of: filter) { _, _ in reload() }
            .onChange(of: language) { _, _ in reload() }
            .alert("搜索失败", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("好") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private var resultsHeader: String {
        let count = results.count
        // Say "200+" rather than "200": the search limit is a cap, and reporting it as an exact
        // count would be a lie.
        let suffix = count >= 200 ? "+" : ""
        return "\(count)\(suffix) 个单词"
    }

    // MARK: - Filters

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.xs) {
                FilterChip(
                    filter.activeFilterCount > 0 ? "筛选 · \(filter.activeFilterCount)" : "筛选",
                    isSelected: filter.activeFilterCount > 0
                ) {
                    isShowingFilters = true
                }

                ForEach(CEFRLevel.allCases) { level in
                    FilterChip(level.rawValue, isSelected: filter.cefrLevels.contains(level)) {
                        toggle(level)
                    }
                }

                ForEach(CardMaturity.allCases, id: \.self) { maturity in
                    FilterChip(maturityLabel(maturity), isSelected: filter.maturities.contains(maturity)) {
                        toggle(maturity)
                    }
                }
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.xs)
        }
        .background(Palette.canvas)
        .sheet(isPresented: $isShowingFilters) {
            NavigationStack { BrowseFilterSheet(filter: $filter, language: language) }
        }
    }

    private func maturityLabel(_ maturity: CardMaturity) -> String {
        switch maturity {
        case .new: "未开始"
        case .learning: "在学"
        case .young: "认识"
        case .mature: "很熟"
        }
    }

    private func toggle(_ level: CEFRLevel) {
        if filter.cefrLevels.contains(level) {
            filter.cefrLevels.remove(level)
        } else {
            filter.cefrLevels.insert(level)
        }
    }

    private func toggle(_ maturity: CardMaturity) {
        if filter.maturities.contains(maturity) {
            filter.maturities.remove(maturity)
        } else {
            filter.maturities.insert(maturity)
        }
    }

    // MARK: - Empty state

    @ViewBuilder
    private var emptyState: some View {
        if !filter.query.isEmpty {
            EmptyStateView(
                systemImage: "magnifyingglass",
                title: "没有找到“\(filter.query)”",
                message: "检查一下拼写，或者把它添加为自己的单词。",
                actionTitle: "添加“\(filter.query)”"
            ) {
                isShowingAddWord = true
            }
        } else if filter.activeFilterCount > 0 {
            EmptyStateView(
                systemImage: "line.3.horizontal.decrease.circle",
                title: "没有符合筛选条件的单词",
                message: "试试放宽等级或状态筛选。",
                actionTitle: "清除筛选"
            ) {
                filter = BrowseFilter(query: filter.query)
            }
        } else {
            EmptyStateView(
                systemImage: "books.vertical",
                title: "还没有单词",
                message: "\(language.displayName)词典还在导入，或者缺少词库内容。"
            )
        }
    }

    private func reload() {
        do {
            results = try dependencies.search.search(filter, language: language)
            recentlyViewed = try dependencies.search.recentlyViewed(language: language)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// One row in the dictionary list.
struct EntryRow: View {
    let entry: Entry
    let matchedInDefinition: Bool

    var body: some View {
        HStack(spacing: Spacing.sm) {
            MaturityDot(entry.maturity)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Spacing.xxs) {
                    Text(entry.headword)
                        .font(Typography.bodyEmphasis)
                        .foregroundStyle(Palette.textPrimary)
                    if let cefr = entry.cefr {
                        Chip(cefr.rawValue, color: Palette.brandSecondary)
                    }
                    if entry.isUserCreated {
                        Chip("自己添加", color: Palette.brandPrimary)
                    }
                }
                Text(entry.primaryDefinition)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(matchedInDefinition ? 2 : 1)
            }
            Spacer()
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// Full filter sheet — the chips cover the common cases, this covers the rest.
struct BrowseFilterSheet: View {
    @Binding var filter: BrowseFilter
    let language: LearningLanguage

    @Environment(\.appDependencies) private var dependencies
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Deck.sortOrder) private var decks: [Deck]

    var body: some View {
        Form {
            Section("等级") {
                ForEach(CEFRLevel.allCases) { level in
                    toggleRow(
                        "\(level.rawValue) · \(level.description)",
                        isOn: filter.cefrLevels.contains(level)
                    ) {
                        if filter.cefrLevels.contains(level) {
                            filter.cefrLevels.remove(level)
                        } else {
                            filter.cefrLevels.insert(level)
                        }
                    }
                }
            }

            Section("词性") {
                ForEach(PartOfSpeech.allCases.filter { $0 != .other }) { pos in
                    toggleRow(pos.displayName, isOn: filter.partsOfSpeech.contains(pos)) {
                        if filter.partsOfSpeech.contains(pos) {
                            filter.partsOfSpeech.remove(pos)
                        } else {
                            filter.partsOfSpeech.insert(pos)
                        }
                    }
                }
            }

            Section("词库") {
                Picker("词库", selection: $filter.deckSlug) {
                    Text("全部词库").tag(String?.none)
                    ForEach(decks.filter { $0.languageCode == language.rawValue }) { deck in
                        Text(deck.name).tag(String?.some(deck.slug))
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }

            Section {
                Toggle("只看标记的单词", isOn: $filter.onlyFlagged)
            }

            Section {
                Button("清除全部筛选") {
                    filter = BrowseFilter(query: filter.query)
                }
                .foregroundStyle(Palette.danger)
            }
        }
        .navigationTitle("筛选")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") { dismiss() }
            }
        }
    }

    private func toggleRow(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .foregroundStyle(Palette.textPrimary)
                Spacer()
                if isOn {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Palette.brandPrimary)
                }
            }
        }
        .accessibilityAddTraits(isOn ? [.isSelected, .isButton] : .isButton)
    }
}

#Preview {
    BrowseView()
}
