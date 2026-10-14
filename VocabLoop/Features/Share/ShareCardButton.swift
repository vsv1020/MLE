import LinkPresentation
import SwiftUI
import UIKit

/// The one share button every celebratory moment uses (sharing plan §3).
///
/// Renders its card on first appearance (a few milliseconds) and only then shows a `ShareLink`:
/// no spinner, no button that does nothing. Hidden entirely when the parent has switched sharing
/// off (`ParentGateView` ▸ "Allow sharing cards"), and when rendering fails.
struct ShareCardButton: View {
    enum Style {
        /// A brand-filled capsule with a label, 44 pt tall.
        case capsule
        /// An icon for a navigation bar.
        case toolbar
    }

    private let card: ShareCard
    private let label: String
    private let style: Style

    @Environment(\.appDependencies) private var dependencies
    @AppStorage(ShareSettings.enabledKey) private var isSharingEnabled = true
    @State private var rendered: RenderedShareCard?

    init(card: ShareCard, label: String = "分享今天", style: Style = .capsule) {
        self.card = card
        self.label = label
        self.style = style
    }

    /// Re-render when the payload changes (e.g. Mochi's look loads after the button appears),
    /// not on every body evaluation.
    private var renderKey: String { String(describing: card) + "|" + (sharer ?? "") }

    /// The signed-in learner's name for the top of the poster; guests stay anonymous.
    private var sharer: String? { ShareCard.sharer(for: dependencies.auth.current) }

    var body: some View {
        if isSharingEnabled {
            Group {
                if let rendered {
                    ShareCardLink(rendered: rendered, label: label, style: style)
                } else {
                    // Something for `.task` to attach to while the card renders.
                    Color.clear
                        .frame(width: 1, height: 1)
                        .accessibilityHidden(true)
                }
            }
            .task(id: renderKey) {
                rendered = ShareCardRenderer.render(card, sharer: sharer)
            }
        }
    }
}

/// The styled share button for an already rendered card. ``ShareCardButton`` uses it, and so
/// does the weekly recap, which renders once for its on-screen preview and shares that same image.
///
/// Hands the share sheet the image itself, not the PNG's file URL: WeChat sends a file URL as a
/// 文件 attachment, while an image goes to chats and Moments as a picture and can be saved to
/// Photos. No text rides along — the poster carries its own QR code, and WeChat drops the image
/// when a share mixes text and pictures.
struct ShareCardLink: View {
    let rendered: RenderedShareCard
    var label: String = "分享今天"
    var style: ShareCardButton.Style = .capsule

    var body: some View {
        Button {
            ShareSheetPresenter.present(image: rendered.image, title: rendered.headline)
        } label: {
            switch style {
            case .capsule:
                Label(label, systemImage: "square.and.arrow.up")
                    .font(Typography.buttonLabel)
                    .foregroundStyle(Palette.onBrand)
                    .padding(.horizontal, Spacing.lg)
                    .frame(minHeight: LayoutMetrics.minimumTapTarget)
                    .background(Capsule().fill(Palette.brandPrimary))
                    .contentShape(Capsule())
            case .toolbar:
                Label(label, systemImage: "square.and.arrow.up")
                    .labelStyle(.iconOnly)
                    .frame(minWidth: LayoutMetrics.minimumTapTarget, minHeight: LayoutMetrics.minimumTapTarget)
                    .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .modifier(PressableIfCapsule(isCapsule: style == .capsule))
        .accessibilityLabel(label)
        .accessibilityHint(rendered.headline)
    }
}

/// Presents the system share sheet for one image from the frontmost view controller.
@MainActor
enum ShareSheetPresenter {
    static func present(image: UIImage, title: String) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.first { $0.activationState == .foregroundActive }?.keyWindow
            ?? scenes.first?.keyWindow
        guard var top = window?.rootViewController else { return }
        while let presented = top.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        let sheet = UIActivityViewController(
            activityItems: [ShareImageItem(image: image, title: title)],
            applicationActivities: nil
        )
        // iPad shows the sheet as a popover; anchor it to the middle of the screen.
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = top.view
            popover.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        top.present(sheet, animated: true)
    }
}

/// The poster as a share-sheet item: the image for every target, and a titled preview with a
/// thumbnail at the top of the sheet.
final class ShareImageItem: NSObject, UIActivityItemSource {
    let image: UIImage
    let title: String

    init(image: UIImage, title: String) {
        self.image = image
        self.title = title
    }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
        image
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        itemForActivityType activityType: UIActivity.ActivityType?
    ) -> Any? {
        image
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        subjectForActivityType activityType: UIActivity.ActivityType?
    ) -> String {
        ShareCopy.subject
    }

    func activityViewControllerLinkMetadata(_ activityViewController: UIActivityViewController) -> LPLinkMetadata? {
        let metadata = LPLinkMetadata()
        metadata.title = title
        let provider = NSItemProvider(object: image)
        metadata.imageProvider = provider
        metadata.iconProvider = provider
        return metadata
    }
}

/// `pressable()` for the capsule only; a toolbar item keeps the system's own press feedback.
private struct PressableIfCapsule: ViewModifier {
    let isCapsule: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isCapsule {
            content.pressable()
        } else {
            content
        }
    }
}
