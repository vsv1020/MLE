import XCTest
import SwiftUI
@testable import VocabLoop

/// Mochi's drawing measured as geometry: every accessory and every stage fits inside the frame
/// at the study-card size (58×48) and the wardrobe size (160×133), the undressed sprout still
/// fills its frame as before 1.0.7, and the four stages draw differently.
///
/// The paths measured are the ones `Mascot` renders — ``MascotAccessories`` builds marks as data
/// and the view only paints them — so a hat that pokes out of the frame fails here, not on a
/// device.
@MainActor
final class MascotAccessoryTests: XCTestCase {
    private let sizes = [CGSize(width: 58, height: 48), CGSize(width: 160, height: 133)]

    /// The frame, plus half a point for anti-aliasing.
    private func frame(_ size: CGSize) -> CGRect {
        CGRect(origin: .zero, size: size).insetBy(dx: -0.5, dy: -0.5)
    }

    private func allMarks(for look: MochiLook, in size: CGSize) -> [MascotMark] {
        let body = MascotAccessories.bodyRect(for: look, in: size)
        let face = MascotAccessories.underFaceMarks(for: look, size: body.size).map { mark -> MascotMark in
            var moved = mark
            moved.path = mark.path.offsetBy(dx: body.minX, dy: body.minY)
            return moved
        }
        return MascotAccessories.behindMarks(for: look, body: body)
            + face
            + MascotAccessories.frontMarks(for: look, body: body)
    }

    private func assertFits(_ look: MochiLook, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        for size in sizes {
            let marks = allMarks(for: look, in: size)
            for (index, mark) in marks.enumerated() {
                let bounds = mark.paintedBounds
                XCTAssertTrue(
                    frame(size).contains(bounds),
                    "\(what) mark \(index) at \(Int(size.width))×\(Int(size.height)) paints \(bounds), outside the frame",
                    file: file, line: line
                )
            }
        }
    }

    // MARK: - Fit

    func testEveryAccessoryFitsAtBothSizesOnEveryStage() {
        for stage in [MochiStage.sprout, .kid, .teen, .grown] {
            for accessory in MochiAccessory.allCases {
                let look = MochiLook(stage: stage, color: .vanilla, accessories: [accessory])
                XCTAssertFalse(
                    MascotAccessories.marks(for: accessory, body: CGRect(x: 0, y: 0, width: 100, height: 83)).isEmpty,
                    "\(accessory.rawValue) draws nothing"
                )
                assertFits(look, "\(accessory.rawValue) on \(stage)")
            }
        }
    }

    func testAFullOutfitFits() {
        let outfits: [[MochiAccessory]] = [
            [.astronautHelmet, .roundGlasses, .rainbowScarf, .cape],
            [.wizardHat, .roundGlasses, .goldStarPin, .cape],
            [.partyHat, .redScarf, .cape],
            [.headphones, .roundGlasses, .redScarf],
        ]
        for outfit in outfits {
            for color in MochiBodyColor.allCases {
                assertFits(MochiLook(stage: .grown, color: color, accessories: outfit),
                           "\(outfit.map(\.rawValue)) on \(color.rawValue)")
            }
        }
    }

    func testEveryStageFitsBareHeaded() {
        for stage in [MochiStage.sprout, .kid, .teen, .grown] {
            assertFits(MochiLook(stage: stage, color: .galaxy, accessories: []), "bare \(stage)")
        }
    }

    // MARK: - Layout

    func testTheDefaultMochiStillFillsItsFrame() {
        for size in sizes {
            XCTAssertEqual(MascotAccessories.bodyRect(for: .default, in: size), CGRect(origin: .zero, size: size))
            let neckOnly = MochiLook(stage: .sprout, color: .strawberry, accessories: [.redScarf, .roundGlasses])
            XCTAssertEqual(MascotAccessories.bodyRect(for: neckOnly, in: size), CGRect(origin: .zero, size: size),
                           "a scarf and glasses sit on the body and need no room")
        }
    }

    func testRoomIsMadeBottomAnchoredAndCentred() {
        let size = CGSize(width: 58, height: 48)
        for look in [
            MochiLook(stage: .sprout, color: .vanilla, accessories: [.crown]),
            MochiLook(stage: .kid, color: .vanilla, accessories: []),
            MochiLook(stage: .sprout, color: .vanilla, accessories: [.cape]),
        ] {
            let body = MascotAccessories.bodyRect(for: look, in: size)
            XCTAssertLessThan(body.height, size.height)
            XCTAssertEqual(body.maxY, size.height, accuracy: 0.001, "Mochi sits on the floor")
            XCTAssertEqual(body.midX, size.width / 2, accuracy: 0.001)
            XCTAssertEqual(body.width / body.height, size.width / size.height, accuracy: 0.001, "never squashed")
        }
    }

    // MARK: - Stages

    func testStagesDrawDifferently() {
        let body = CGRect(x: 0, y: 0, width: 120, height: 100)
        func signature(_ stage: MochiStage) -> [Int] {
            let look = MochiLook(stage: stage, color: .vanilla, accessories: [])
            return [
                MascotAccessories.underFaceMarks(for: look, size: body.size).count,
                MascotAccessories.frontMarks(for: look, body: body).count,
            ]
        }
        let signatures = [MochiStage.sprout, .kid, .teen, .grown].map(signature)
        XCTAssertEqual(signatures[0], [0, 0], "a sprout is the original Mochi")
        XCTAssertEqual(Set(signatures.map { "\($0)" }).count, 4, "every stage adds or changes something: \(signatures)")
    }

    func testAHatCoversTheCrest() {
        let bare = MochiLook(stage: .kid, color: .vanilla, accessories: [])
        let hatted = MochiLook(stage: .kid, color: .vanilla, accessories: [.strawHat])
        XCTAssertTrue(MascotAccessories.showsCrest(bare))
        XCTAssertFalse(MascotAccessories.showsCrest(hatted))
        XCTAssertFalse(MascotAccessories.showsCrest(MochiLook(stage: .sprout, color: .vanilla, accessories: [])))
    }
}
