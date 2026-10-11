import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

/// The QR code printed on every share poster: the China App Store page, so a friend who sees the
/// poster in WeChat Moments or 小红书 can long-press it (or scan it) and land on the download page.
/// A printed URL is no use there — nobody types one, and links in those apps are not tappable.
///
/// Built with CoreImage, black modules on white, error correction "M" (15 %, enough for a code
/// that is only ever shown on screens and re-compressed by chat apps). Scaled with
/// nearest-neighbour sampling so every module stays a hard-edged square, and padded with a white
/// quiet zone so scanners find it even on a busy background.
enum ShareQRCode {
    /// Pixels per module in the generated bitmap. The poster draws it smaller, with
    /// `.interpolation(.none)`, so the edges stay crisp at any size.
    static let pixelsPerModule: CGFloat = 12

    /// White margin around the code, in modules. The QR spec asks for four; CoreImage adds one of
    /// its own, so the code ends up with five.
    static let quietZoneModules: CGFloat = 4

    /// The poster's code for ``AppLinks/appStoreChina``. Generated once: the link never changes.
    static let appStoreChina: UIImage? = image(for: AppLinks.appStoreChina.absoluteString)

    /// A black-on-white QR code for `string`, with a white quiet zone; `nil` if CoreImage cannot
    /// encode it.
    static func image(for string: String, correctionLevel: String = "M") -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = correctionLevel
        guard let output = filter.outputImage, !output.extent.isEmpty else { return nil }

        let scaled = output
            .samplingNearest()
            .transformed(by: CGAffineTransform(scaleX: pixelsPerModule, y: pixelsPerModule))
        let context = CIContext(options: [.cacheIntermediates: false])
        guard let code = context.createCGImage(scaled, from: scaled.extent.integral) else { return nil }

        let margin = quietZoneModules * pixelsPerModule
        let codeSize = CGSize(width: code.width, height: code.height)
        let size = CGSize(width: codeSize.width + margin * 2, height: codeSize.height + margin * 2)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { drawing in
            UIColor.white.setFill()
            drawing.fill(CGRect(origin: .zero, size: size))
            drawing.cgContext.interpolationQuality = .none
            // `UIImage.draw` keeps the code the right way up (a raw `CGContext.draw` would flip it).
            UIImage(cgImage: code).draw(in: CGRect(origin: CGPoint(x: margin, y: margin), size: codeSize))
        }
    }
}

/// The poster's QR code at `side` points, quiet zone included. Draws nothing if the code could
/// not be generated, so the footer still lays out.
struct ShareQRCodeView: View {
    var side: CGFloat = 76

    var body: some View {
        if let image = ShareQRCode.appStoreChina {
            Image(uiImage: image)
                .interpolation(.none)
                .resizable()
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Palette.separator.opacity(0.35), lineWidth: 1)
                )
                .accessibilityHidden(true)
        }
    }
}
