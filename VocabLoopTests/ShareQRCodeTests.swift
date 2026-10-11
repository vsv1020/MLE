import UIKit
import XCTest
@testable import VocabLoop

/// The poster's QR code: generated, square, black on white with a white quiet zone, and cached.
final class ShareQRCodeTests: XCTestCase {
    func testChinaAppStoreCodeIsGenerated() throws {
        let image = try XCTUnwrap(ShareQRCode.image(for: AppLinks.appStoreChina.absoluteString))
        XCTAssertEqual(image.size.width, image.size.height)
        // At least a version-1 code (21 modules) plus the quiet zone on both sides.
        let minimum = (21 + 2 * ShareQRCode.quietZoneModules) * ShareQRCode.pixelsPerModule
        XCTAssertGreaterThanOrEqual(image.size.width * image.scale, minimum)
    }

    func testPosterCodeIsCached() throws {
        let first = try XCTUnwrap(ShareQRCode.appStoreChina)
        let second = try XCTUnwrap(ShareQRCode.appStoreChina)
        XCTAssertTrue(first === second)
    }

    func testCodeHasWhiteQuietZoneAndBlackModules() throws {
        let image = try XCTUnwrap(ShareQRCode.appStoreChina)
        let cgImage = try XCTUnwrap(image.cgImage)
        let pixels = try Self.grayscalePixels(of: cgImage)
        let width = cgImage.width
        let height = cgImage.height
        let margin = Int(ShareQRCode.quietZoneModules * ShareQRCode.pixelsPerModule)

        // The quiet zone is white all the way round.
        for x in stride(from: 0, to: width, by: 3) {
            XCTAssertGreaterThan(pixels[x], 240)
            XCTAssertGreaterThan(pixels[(height - 1) * width + x], 240)
        }
        for y in stride(from: 0, to: height, by: 3) {
            XCTAssertGreaterThan(pixels[y * width], 240)
            XCTAssertGreaterThan(pixels[y * width + width - 1], 240)
        }
        // Inside it there are black modules: the centre of the top-left finder pattern. Three
        // and a half modules in from our margin lands in the finder's solid 3×3 core whether or
        // not CoreImage adds its own one-module border.
        let module = Int(ShareQRCode.pixelsPerModule)
        let corner = margin + 3 * module + module / 2
        XCTAssertLessThan(pixels[corner * width + corner], 15)
        // And only pure black and pure white: nearest-neighbour scaling, no grey edges.
        let greys = pixels.filter { $0 > 15 && $0 < 240 }
        XCTAssertEqual(greys.count, 0)
    }

    /// The image redrawn into an 8-bit grey buffer, row by row from the top.
    private static func grayscalePixels(of image: CGImage) throws -> [UInt8] {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw XCTSkip("Could not create a grey bitmap context") }
        return pixels
    }
}
