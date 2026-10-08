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

    @AppStorage(ShareSettings.enabledKey) private var isSharingEnabled = true
    @State private var rendered: RenderedShareCard?

    init(card: ShareCard, label: String = "分享今天", style: Style = .capsule) {
        self.card = card
        self.label = label
        self.style = style
    }

    /// Re-render when the payload changes (e.g. Mochi's look loads after the button appears),
    /// not on every body evaluation.
    private var renderKey: String { String(describing: card) }

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
                rendered = ShareCardRenderer.render(card)
            }
        }
    }
}

/// The styled `ShareLink` for an already rendered card. ``ShareCardButton`` uses it, and so does
/// the weekly recap, which renders once for its on-screen preview and shares that same file.
struct ShareCardLink: View {
    let rendered: RenderedShareCard
    var label: String = "分享今天"
    var style: ShareCardButton.Style = .capsule

    var body: some View {
        ShareLink(
            item: rendered.url,
            subject: Text(ShareCopy.subject),
            message: Text(rendered.message),
            preview: SharePreview(rendered.headline, image: Image(uiImage: rendered.image))
        ) {
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
        .modifier(PressableIfCapsule(isCapsule: style == .capsule))
        .accessibilityLabel(label)
        .accessibilityHint(rendered.headline)
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
