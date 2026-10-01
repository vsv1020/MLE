import SwiftUI
import SwiftData

/// One sticker-book page: twelve words in a 3×4 grid, with `7 / 12` shining in the header.
struct AlbumGridView: View {
    let album: Album
    let isPlusAlbum: Bool

    @Environment(\.appDependencies) private var dependencies
    @State private var progress: AlbumProgress?
    @State private var headwords: [String: String] = [:]
    /// Mochi on the "page complete" share card.
    @State private var look: MochiLook = .default
    @State private var level = 1

    private let columns = Array(repeating: GridItem(.flexible(), spacing: Spacing.sm), count: 3)

    init(album: Album, isPlusAlbum: Bool = false) {
        self.album = album
        self.isPlusAlbum = isPlusAlbum
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                header

                LazyVGrid(columns: columns, spacing: Spacing.md) {
                    ForEach(Array(album.entryStableIDs.enumerated()), id: \.element) { index, stableID in
                        StickerView(
                            headword: headwords[stableID] ?? "…",
                            family: album.family,
                            state: state(at: index)
                        )
                    }
                }

                if progress?.isComplete == true {
                    completeBanner
                } else {
                    Text("A sticker shines once you know its word well — about three weeks between reviews. Keep studying and they light up one by one.")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                }
            }
            .padding(Spacing.md)
            .readableWidth()
        }
        .screenBackground()
        .navigationTitle("\(album.family.title) · Page \(album.page)")
        .navigationBarTitleDisplayMode(.inline)
        .task { load() }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(album.title)
                    .font(Typography.screenTitle)
                    .foregroundStyle(Palette.textPrimary)
                HStack(spacing: Spacing.xs) {
                    Chip(album.level.rawValue, color: Palette.brandSecondary)
                    Chip(album.family.title, color: album.family.tint)
                    if isPlusAlbum {
                        Chip("Plus", color: Palette.brandSecondary, systemImage: "sparkles")
                    }
                }
            }
            Spacer(minLength: Spacing.sm)
            VStack(alignment: .trailing, spacing: 0) {
                Text("\(shinyCount) / \(album.entryStableIDs.count)")
                    .font(Typography.statValue)
                    .foregroundStyle(Palette.textPrimary)
                Text("shining")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(shinyCount) of \(album.entryStableIDs.count) stickers shining")
        }
    }

    private var completeBanner: some View {
        CardContainer(style: .crayon, wobbleSeed: WobbleShape.seed(for: album.id)) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                HStack(spacing: Spacing.md) {
                    Mascot(mood: .cheer)
                        .frame(width: 58, height: 48)
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        Text("Page complete!")
                            .font(Typography.sectionHeader)
                            .foregroundStyle(Palette.textPrimary)
                        Text("Every sticker on this page shines.")
                            .font(Typography.caption)
                            .foregroundStyle(Palette.textSecondary)
                    }
                }
                .accessibilityElement(children: .combine)

                ShareCardButton(card: .album(albumCard), label: "Share this page")
            }
        }
    }

    /// The page as a share card: its title, how many stickers shine, and Mochi.
    private var albumCard: AlbumCard {
        AlbumCard(
            albumTitle: album.title,
            familyTitle: album.family.title,
            albumLevel: album.level.rawValue,
            page: album.page,
            stickerCount: shinyCount,
            look: look,
            level: level
        )
    }

    private var shinyCount: Int { progress?.shinyCount ?? 0 }

    private func state(at index: Int) -> StickerState {
        guard let states = progress?.states, states.indices.contains(index) else { return .locked }
        return states[index]
    }

    private func load() {
        progress = try? dependencies.collection.progress(of: album)
        let engagement = dependencies.engagement
        look = engagement.currentLook()
        if let profile = try? engagement.profile() {
            level = profile.level
        }
        let entries = (try? dependencies.context.entries(stableIDs: album.entryStableIDs)) ?? []
        var names: [String: String] = [:]
        for entry in entries {
            names[entry.stableID] = entry.headword
        }
        headwords = names
    }
}
