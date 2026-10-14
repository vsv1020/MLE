import SwiftUI
import UIKit

/// A card rendered and written to disk, ready for a `ShareLink`.
struct RenderedShareCard: Equatable {
    let url: URL
    let image: UIImage
    let headline: String
    let message: String
}

/// Turns a ``ShareCard`` into a PNG file a `ShareLink` can hand to other apps (sharing plan §3).
///
/// The PNG on disk is kept for tests and previews; the share sheet hands over the image itself
/// (see ``ShareCardLink``) so WeChat and Photos treat it as a picture, not a file.
/// 1080×1440, always light, fixed text size — see ``ShareCardFrame``.
@MainActor
enum ShareCardRenderer {
    /// Render `card` and write it to `directory`. `nil` if rendering or the write fails — the
    /// share button is simply not offered then. Never throws.
    static func writePNG(
        _ card: ShareCard,
        sharer: String? = nil,
        to directory: URL = FileManager.default.temporaryDirectory
    ) -> URL? {
        render(card, sharer: sharer, to: directory)?.url
    }

    /// Render and write, keeping the image for an on-screen preview and the share sheet.
    static func render(
        _ card: ShareCard,
        sharer: String? = nil,
        to directory: URL = FileManager.default.temporaryDirectory
    ) -> RenderedShareCard? {
        guard let data = pngData(for: card, sharer: sharer), let image = UIImage(data: data) else { return nil }
        let url = directory.appendingPathComponent(card.fileName)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            return nil
        }
        return RenderedShareCard(url: url, image: image, headline: card.headline, message: card.message)
    }

    /// The PNG bytes of `card` at ``ShareCardMetrics/pixelSize``, without touching the disk.
    static func pngData(for card: ShareCard, sharer: String? = nil) -> Data? {
        let renderer = ImageRenderer(content: content(for: card, sharer: sharer))
        renderer.scale = ShareCardMetrics.scale
        renderer.proposedSize = ProposedViewSize(ShareCardMetrics.pointSize)
        return renderer.uiImage?.pngData()
    }

    /// The card exactly as it is rendered.
    static func content(for card: ShareCard, sharer: String? = nil) -> some View {
        ShareCardView(card: card)
            .environment(\.shareSharerName, sharer)
            .environment(\.colorScheme, .light)
            .dynamicTypeSize(.large)
    }
}

/// The device-level parent switch (sharing plan §4). Default on; off hides every share button.
enum ShareSettings {
    static let enabledKey = "sharing.enabled"
}
