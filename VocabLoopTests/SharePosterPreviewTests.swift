import XCTest
@testable import VocabLoop

/// Renders one poster of every kind as a test attachment, for the screenshot workflow's preview.
///
/// Skips itself unless the workflow sets TEST_RUNNER_SHARE_POSTER_PREVIEW=1, so the regular test
/// suite does not carry seven 1080×1440 images in every result bundle.
final class SharePosterPreviewTests: XCTestCase {
    func testRenderEveryPosterForReview() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["SHARE_POSTER_PREVIEW"] == "1",
            "Run by the screenshot workflow only."
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("poster-preview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        for card in ShareCardFixtures.all {
            let url = try XCTUnwrap(ShareCardRenderer.writePNG(card, to: directory), "\(card.kind) did not render")
            let attachment = XCTAttachment(contentsOfFile: url)
            attachment.name = "poster-\(card.kind.rawValue)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
}
