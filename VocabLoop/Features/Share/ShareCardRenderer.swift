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
/// A file URL rather than an `Image`: `URL` is `Transferable` already, and a PNG on disk is what
/// every share target expects. 1080×1350, light, fixed text size — see ``ShareCardFrame``.
@MainActor
enum ShareCardRenderer {
    /// Render `card` and write it to `directory`. `nil` if rendering or the write fails — the
    /// share button is simply not offered then. Never throws.
    static func writePNG(
        _ card: ShareCard,
        to directory: URL = FileManager.default.temporaryDirectory
    ) -> URL? {
        render(card, to: directory)?.url
    }

    /// Render and write, keeping the image for an on-screen preview and the share sheet.
    static func render(
        _ card: ShareCard,
        to directory: URL = FileManager.default.temporaryDirectory
    ) -> RenderedShareCard? {
        guard let data = pngData(for: card), let image = UIImage(data: data) else { return nil }
        let url = directory.appendingPathComponent(card.fileName)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            return nil
        }
        return RenderedShareCard(url: url, image: image, headline: card.headline, message: card.message)
    }

    /// The PNG bytes of `card` at ``ShareCardMetrics/pixelSize``, without touching the disk.
    static func pngData(for card: ShareCard) -> Data? {
        let renderer = ImageRenderer(content: content(for: card))
        renderer.scale = ShareCardMetrics.scale
        renderer.proposedSize = ProposedViewSize(ShareCardMetrics.pointSize)
        return renderer.uiImage?.pngData()
    }

    /// The card exactly as it is rendered.
    static func content(for card: ShareCard) -> some View {
        ShareCardView(card: card)
            .environment(\.colorScheme, .light)
            .dynamicTypeSize(.large)
    }
}

/// The device-level parent switch (sharing plan §4). Default on; off hides every share button.
enum ShareSettings {
    static let enabledKey = "sharing.enabled"
}
