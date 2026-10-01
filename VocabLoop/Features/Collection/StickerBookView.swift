import SwiftUI

/// The sticker book's contents: every page of the active language, by level, then by family.
///
/// Albums are derived from the dictionary and stored nowhere (`ENGAGEMENT-PLAN.md` §1.7), so this
/// screen is one cached album list plus one card fetch for the sticker states. Plus-pack pages
/// carry a small "Plus" tag and stay browsable — looking at a page is never what Plus sells.
struct StickerBookView: View {
    @Environment(\.appDependencies) private var dependencies

    @State private var progresses: [AlbumProgress] = []
    @State private var plusOnlyEntryIDs: Set<String> = []
    @State private var level: AlbumLevel = .a1
    @State private var hasLoaded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                if hasLoaded && progresses.isEmpty {
                    EmptyStateView(
                        systemImage: "book.closed",
                        title: "No stickers yet",
                        message: "The sticker book fills in once the word packs have finished loading."
                    )
                } else {
                    summaryCard
                    legend
                    levelPicker
                    ForEach(WordFamily.allCases, id: \.self) { family in
                        familySection(family)
                    }
                }
            }
            .padding(Spacing.md)
            .readableWidth()
        }
        .task { load() }
    }

    // MARK: - Summary

    private var completeCount: Int { progresses.filter(\.isComplete).count }
    private var shinyCount: Int { progresses.reduce(0) { $0 + $1.shinyCount } }

    private var summaryCard: some View {
        CardContainer(style: .crayon, wobbleSeed: 0x571C_4E85_0001) {
            HStack(spacing: Spacing.md) {
                Image(systemName: "book.closed.fill")
                    .font(Typography.heroGlyph)
                    .foregroundStyle(Palette.brandPrimary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text("\(completeCount) of \(progresses.count) pages complete")
                        .font(Typography.sectionHeader)
                        .foregroundStyle(Palette.textPrimary)
                    Text("\(shinyCount.formatted()) shining stickers")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// What each sticker look means, drawn with the real sticker so the key cannot drift.
    private var legend: some View {
        HStack(spacing: Spacing.xs) {
            ForEach(Self.legendItems) { item in
                VStack(spacing: Spacing.xxs) {
                    StickerView(headword: "Aa", family: .nouns, state: item.state)
                        .accessibilityHidden(true)
                    Text(item.label)
                        .font(Typography.chip)
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Key: dotted, not started. Pencil, learning. Coloured, known. Shining, well known.")
    }

    private struct LegendItem: Identifiable {
        let state: StickerState
        let label: String
        var id: String { label }
    }

    private static let legendItems: [LegendItem] = [
        LegendItem(state: .locked, label: "Not started"),
        LegendItem(state: .sketch, label: "Learning"),
        LegendItem(state: .coloured, label: "Known"),
        LegendItem(state: .shiny, label: "Shining"),
    ]

    private var levelPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.xs) {
                ForEach(availableLevels, id: \.self) { candidate in
                    FilterChip(candidate.rawValue, isSelected: candidate == level) {
                        level = candidate
                    }
                }
            }
        }
    }

    private var availableLevels: [AlbumLevel] {
        let present = Set(progresses.map(\.album.level))
        return AlbumLevel.allCases.filter { present.contains($0) }
    }

    // MARK: - Pages

    @ViewBuilder
    private func familySection(_ family: WordFamily) -> some View {
        let pages = progresses.filter { $0.album.level == level && $0.album.family == family }
        if !pages.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                SectionHeader(family.title, subtitle: "\(pages.count) \(pages.count == 1 ? "page" : "pages")")
                ForEach(pages, id: \.album.id) { progress in
                    let isPlus = CollectionService.isPlusAlbum(progress.album, plusOnlyEntryIDs: plusOnlyEntryIDs)
                    NavigationLink {
                        AlbumGridView(album: progress.album, isPlusAlbum: isPlus)
                    } label: {
                        StickerAlbumRow(progress: progress, isPlus: isPlus)
                    }
                    .pressable()
                }
            }
        }
    }

    private func load() {
        let languageCode = dependencies.preferences?.activeLanguageCode ?? LearningLanguage.default.rawValue
        progresses = (try? dependencies.collection.allProgress(languageCode: languageCode)) ?? []
        plusOnlyEntryIDs = (try? dependencies.collection.plusOnlyEntryIDs(languageCode: languageCode)) ?? []
        // Open on the first level that has pages, if A1 has none (a user-only language, say).
        let levels = availableLevels
        if !levels.contains(level), let first = levels.first {
            level = first
        }
        hasLoaded = true
    }
}

/// One page in the contents list: a 3×4 dot map of its stickers and `7 / 12`.
private struct StickerAlbumRow: View {
    let progress: AlbumProgress
    let isPlus: Bool

    var body: some View {
        HStack(spacing: Spacing.md) {
            DotMap(states: progress.states, tint: progress.album.family.tint)
                .frame(width: 44, height: 56)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("Page \(progress.album.page)")
                    .font(Typography.bodyEmphasis)
                    .foregroundStyle(Palette.textPrimary)
                HStack(spacing: Spacing.xs) {
                    if progress.isComplete {
                        Chip("Complete", color: Palette.success, systemImage: "star.fill")
                    }
                    if isPlus {
                        Chip("Plus", color: Palette.brandSecondary, systemImage: "sparkles")
                    }
                }
            }

            Spacer(minLength: Spacing.xs)

            Text("\(progress.shinyCount) / \(progress.states.count)")
                .font(Typography.statValueSmall)
                .foregroundStyle(Palette.textPrimary)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Palette.textTertiary)
                .accessibilityHidden(true)
        }
        .padding(Spacing.sm)
        .tappableArea()
        .drawnPanel(seed: WobbleShape.seed(for: progress.album.id))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel)
        .accessibilityAddTraits(.isButton)
    }

    private var spokenLabel: String {
        var label = "\(progress.album.family.title), page \(progress.album.page). "
            + "\(progress.shinyCount) of \(progress.states.count) stickers shining"
        if progress.isComplete { label += ". Complete" }
        if isPlus { label += ". Plus pack" }
        return label
    }
}

/// Twelve dots in the page's 3×4 layout, one per sticker, filled by state.
private struct DotMap: View {
    let states: [StickerState]
    let tint: Color

    var body: some View {
        Canvas { context, size in
            let columns = 3
            let rows = 4
            let cell = min(size.width / CGFloat(columns), size.height / CGFloat(rows))
            let radius = cell * 0.34
            for index in 0..<(columns * rows) {
                let column = index % columns
                let row = index / columns
                let centre = CGPoint(
                    x: (CGFloat(column) + 0.5) * size.width / CGFloat(columns),
                    y: (CGFloat(row) + 0.5) * size.height / CGFloat(rows)
                )
                let dot = Path(ellipseIn: CGRect(x: centre.x - radius, y: centre.y - radius,
                                                 width: radius * 2, height: radius * 2))
                guard index < states.count else { continue }
                switch states[index] {
                case .locked:
                    context.stroke(dot, with: .color(Palette.textTertiary),
                                   style: StrokeStyle(lineWidth: 1, dash: [1.5, 1.5]))
                case .sketch:
                    context.stroke(dot, with: .color(Palette.textSecondary), lineWidth: 1.2)
                case .coloured:
                    context.fill(dot, with: .color(tint.opacity(0.45)))
                    context.stroke(dot, with: .color(tint), lineWidth: 1.2)
                case .shiny:
                    context.fill(dot, with: .color(tint))
                    context.stroke(dot, with: .color(Palette.separator), lineWidth: 1)
                }
            }
        }
    }
}
