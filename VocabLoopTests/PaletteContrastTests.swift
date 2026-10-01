import XCTest
import SwiftUI
import UIKit
@testable import VocabLoop

/// Holds the palette to the contrast ratio `docs/DESIGN.md` promises.
///
/// This suite exists because the promise was already broken once. The rating bar set its
/// labels in white against all four rating fills; in dark mode the fills are deliberately
/// light, so white-on-Hard measured **1.67:1** — effectively invisible — and five other
/// pairings were under 4.5:1. Nothing caught it, because a colour token has no behaviour
/// to unit-test and the failure only shows up on a device in the wrong appearance.
///
/// Colours are resolved through `UITraitCollection` so both appearances are measured the
/// way the system actually renders them, not by re-reading the hex literals.
final class PaletteContrastTests: XCTestCase {

    /// WCAG 2.1 minimum for normal-size text. Everything asserted here is normal-size:
    /// the largest is the 16pt semibold rating label, below the 18.66pt bold that would
    /// qualify for the 3:1 large-text threshold.
    private let minimumRatio = 4.5

    private let appearances: [(name: String, style: UIUserInterfaceStyle)] = [
        ("light", .light), ("dark", .dark),
    ]

    // MARK: - Ratings

    /// The regression this suite was written for.
    func testRatingLabelsAreLegibleOnEveryRatingFill() {
        for (name, style) in appearances {
            for rating in Rating.allCases {
                assertContrast(
                    Palette.onRating, on: Palette.rating(rating), style: style,
                    because: "\(rating.shortLabel) label in \(name) mode"
                )
            }
        }
    }

    /// White is *not* an acceptable foreground on a rating fill, in **either** appearance.
    ///
    /// It used to fail in dark mode only, which is what this test originally asserted. The fills
    /// are now bright in both appearances, so white fails in both — and the temptation to write
    /// `.foregroundStyle(.white)` is strongest in light mode, where it used to be correct.
    func testPlainWhiteWouldFailOnEveryRatingFill() {
        for (name, style) in appearances {
            let worst = Rating.allCases
                .map { contrast(.white, Palette.rating($0), style: style) }
                .min() ?? 0
            XCTAssertLessThan(
                worst, minimumRatio,
                "White has become legible on the \(name) rating fills — if the fills changed, "
                + "re-derive Palette.onRating rather than deleting this test."
            )
        }
    }

    /// The assertion that makes the bright fills legal.
    ///
    /// `Palette.rating` is a 400-weight fill: on a light surface the amber comes in at **1.52:1**,
    /// and it is not only a button background — it is the bars on the session summary and the
    /// history dots in entry detail, graphical objects WCAG 1.4.11 holds to 3:1. Brightening the
    /// fills without an edge would have traded readable data for prettier buttons.
    ///
    /// Measured from both sides, because an outline that vanishes into *either* neighbour is not
    /// an outline.
    func testRatingEdgeGivesEveryFillABoundary() {
        let surfaces: [(String, Color)] = [
            ("surface", Palette.surface),
            ("canvas", Palette.canvas),
            ("surfaceRaised", Palette.surfaceRaised),
        ]

        for (name, style) in appearances {
            for rating in Rating.allCases {
                let edge = Palette.ratingEdge(rating)

                let againstFill = contrast(edge, Palette.rating(rating), style: style)
                XCTAssertGreaterThanOrEqual(
                    againstFill, 3.0,
                    "\(rating.shortLabel) edge on its own fill in \(name) mode is "
                    + "\(String(format: "%.2f", againstFill)):1"
                )

                // Light mode only. In dark mode the edge is deliberately *darker* than the dark
                // surfaces and does not separate from them — it does not need to, because the
                // bright fill is already 5.44:1 there. Asserting it in both appearances would be
                // asserting something the design does not claim.
                guard style == .light else { continue }
                for (surfaceName, surface) in surfaces {
                    let ratio = contrast(edge, surface, style: style)
                    XCTAssertGreaterThanOrEqual(
                        ratio, 3.0,
                        "\(rating.shortLabel) edge on \(surfaceName) in light mode is "
                        + "\(String(format: "%.2f", ratio)):1"
                    )
                }
            }
        }
    }

    /// The dark-mode half of the same promise: there, the fill carries its own boundary.
    ///
    /// Kept separate from the edge test so that if someone later dims the dark fills, the failure
    /// says *"the fill stopped separating"* rather than *"the edge is wrong"*.
    func testRatingFillsSeparateFromDarkSurfaces() {
        let surfaces: [(String, Color)] = [
            ("surface", Palette.surface),
            ("canvas", Palette.canvas),
            ("surfaceRaised", Palette.surfaceRaised),
        ]
        for rating in Rating.allCases {
            for (surfaceName, surface) in surfaces {
                let ratio = contrast(Palette.rating(rating), surface, style: .dark)
                XCTAssertGreaterThanOrEqual(
                    ratio, 3.0,
                    "\(rating.shortLabel) fill on \(surfaceName) in dark mode is "
                    + "\(String(format: "%.2f", ratio)):1"
                )
            }
        }
    }

    // MARK: - Text on surfaces

    func testTextTonesAreLegibleOnEverySurface() {
        let surfaces: [(String, Color)] = [
            ("surface", Palette.surface),
            ("canvas", Palette.canvas),
            ("surfaceRaised", Palette.surfaceRaised),
        ]
        let tones: [(String, Color)] = [
            ("textPrimary", Palette.textPrimary),
            ("textSecondary", Palette.textSecondary),
            // Tertiary carries information — due dates, intervals, hints — so WCAG's
            // exception for incidental text does not cover it.
            ("textTertiary", Palette.textTertiary),
        ]

        for (appearance, style) in appearances {
            for (surfaceName, surface) in surfaces {
                for (toneName, tone) in tones {
                    assertContrast(
                        tone, on: surface, style: style,
                        because: "\(toneName) on \(surfaceName) in \(appearance) mode"
                    )
                }
            }
        }
    }

    /// The hierarchy has to remain visible, or three tokens are doing one token's job.
    func testTextTonesStayDistinctFromEachOther() {
        for (appearance, style) in appearances {
            let primary = contrast(Palette.textPrimary, Palette.surface, style: style)
            let secondary = contrast(Palette.textSecondary, Palette.surface, style: style)
            let tertiary = contrast(Palette.textTertiary, Palette.surface, style: style)

            XCTAssertGreaterThan(primary, secondary, "primary must outweigh secondary in \(appearance)")
            XCTAssertGreaterThan(secondary, tertiary, "secondary must outweigh tertiary in \(appearance)")
        }
    }

    // MARK: - Brand

    func testBrandForegroundsAreLegible() {
        for (appearance, style) in appearances {
            assertContrast(
                Palette.onBrand, on: Palette.brandPrimary, style: style,
                because: "onBrand on brandPrimary in \(appearance) mode"
            )
            // Both brand colours are used as *text* — brandPrimary for buttons and links,
            // brandSecondary for CEFR chips and the streak counter.
            assertContrast(
                Palette.brandPrimary, on: Palette.surface, style: style,
                because: "brandPrimary as text on surface in \(appearance) mode"
            )
            assertContrast(
                Palette.brandSecondary, on: Palette.surface, style: style,
                because: "brandSecondary as text on surface in \(appearance) mode"
            )
        }
    }

    // MARK: - Maturity dots

    /// Dots are non-text UI components, so 3:1 applies rather than 4.5:1 — and they are
    /// never the sole signal, since `MaturityDot` carries an accessibility label.
    func testMaturityDotsAreDistinguishableFromTheirBackground() {
        for (appearance, style) in appearances {
            for maturity in CardMaturity.allCases {
                let ratio = contrast(Palette.maturity(maturity), Palette.surface, style: style)
                XCTAssertGreaterThanOrEqual(
                    ratio, 3.0,
                    "\(maturity.rawValue) dot on surface in \(appearance) mode is \(String(format: "%.2f", ratio)):1"
                )
            }
        }
    }

    // MARK: - Sticker book (1.0.7)

    private let allSurfaces: [(String, Color)] = [
        ("surface", Palette.surface),
        ("canvas", Palette.canvas),
        ("surfaceRaised", Palette.surfaceRaised),
    ]

    /// The four family tints are the sticker edges and the dots in the contents list: graphical
    /// objects, so WCAG 1.4.11's 3:1 against every surface they can sit on.
    func testWordFamilyTintsAreVisibleOnEverySurface() {
        for (appearance, style) in appearances {
            for family in WordFamily.allCases {
                for (surfaceName, surface) in allSurfaces {
                    let ratio = contrast(family.tint, surface, style: style)
                    XCTAssertGreaterThanOrEqual(
                        ratio, 3.0,
                        "\(family.rawValue) tint on \(surfaceName) in \(appearance) mode is "
                        + "\(String(format: "%.2f", ratio)):1"
                    )
                }
            }
        }
    }

    /// A coloured or shiny sticker's word: ink over the family tint at the opacity `StickerView`
    /// actually draws. The sticker paints opaque `surface` under the tint, but every surface is
    /// measured so a future change to that underlay cannot quietly break the word.
    func testStickerWordIsLegibleOnEveryFamilyTint() {
        for (appearance, style) in appearances {
            for family in WordFamily.allCases {
                for (surfaceName, surface) in allSurfaces {
                    let fill = blend(family.tint, over: surface, alpha: StickerView.fillOpacity, style: style)
                    assertContrast(
                        Palette.textPrimary, on: fill, style: style,
                        because: "sticker word on a \(family.rawValue) tint over \(surfaceName) in \(appearance) mode"
                    )
                }
            }
        }
    }

    /// Not-started and sketched stickers carry their word in a lighter tone, on paper.
    func testUncolouredStickerWordsAreLegible() {
        for (appearance, style) in appearances {
            assertContrast(
                Palette.textTertiary, on: Palette.surface, style: style,
                because: "not-started sticker word in \(appearance) mode"
            )
            assertContrast(
                Palette.textSecondary, on: Palette.surfaceRaised, style: style,
                because: "sketched sticker word in \(appearance) mode"
            )
        }
    }

    /// Mochi's face is drawn in `textPrimary` on whatever colour Mochi is wearing.
    func testMochiFaceIsLegibleOnEveryBodyColour() {
        for (appearance, style) in appearances {
            for color in MochiBodyColor.allCases {
                assertContrast(
                    Palette.textPrimary, on: color.fill, style: style,
                    because: "Mochi's face on \(color.rawValue) in \(appearance) mode"
                )
            }
        }
    }

    // MARK: - Measurement

    private func assertContrast(
        _ foreground: Color, on background: Color,
        style: UIUserInterfaceStyle, because reason: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let ratio = contrast(foreground, background, style: style)
        XCTAssertGreaterThanOrEqual(
            ratio, minimumRatio,
            "\(reason) is \(String(format: "%.2f", ratio)):1, below the \(minimumRatio):1 "
            + "this design system commits to",
            file: file, line: line
        )
    }

    // MARK: - Translucent fills

    /// `Chip` text over `Chip`'s own tint, on every surface a chip can sit on.
    ///
    /// This is the assertion whose absence let a 2.52:1 chip ship. The suite measured every tone
    /// against every *surface* and concluded the palette was safe, while `Chip` quietly composited
    /// its foreground at 14% to make a background nothing had a name for. Eight of twelve
    /// token/appearance combinations were under 4.5:1 — and these chips render on the flashcard,
    /// carrying part of speech, register and synonyms.
    func testChipTextIsLegibleOverItsOwnTint() {
        let tokens: [(String, Color)] = [
            ("brandPrimary", Palette.brandPrimary),
            ("brandSecondary", Palette.brandSecondary),
            ("textSecondary", Palette.textSecondary),
            ("success", Palette.success),
            ("warning", Palette.warning),
            ("danger", Palette.danger),
        ]
        let surfaces: [(String, Color)] = [
            ("surface", Palette.surface),
            ("surfaceRaised", Palette.surfaceRaised),
            ("canvas", Palette.canvas),
        ]

        for (appearance, style) in appearances {
            for (tokenName, token) in tokens {
                for (surfaceName, surface) in surfaces {
                    let tint = blend(token, over: surface, alpha: Chip.fillOpacity, style: style)
                    assertContrast(
                        Palette.textPrimary, on: tint, style: style,
                        because: "chip text on a \(tokenName) tint over \(surfaceName) in \(appearance) mode"
                    )
                }
            }
        }
    }

    /// The old scheme must stay broken, so nobody "simplifies" it back.
    ///
    /// If someone restores `foregroundStyle(color)` this fails and says why, rather than the
    /// regression going unnoticed for another release.
    func testTintedForegroundOnItsOwnTintWouldStillFail() {
        let worst = [Palette.warning, Palette.success, Palette.danger]
            .map { token in
                contrast(
                    token,
                    blend(token, over: Palette.surfaceRaised, alpha: Chip.fillOpacity, style: .light),
                    style: .light
                )
            }
            .min() ?? 99

        XCTAssertLessThan(
            worst, minimumRatio,
            "Colouring chip text with its own hue has become legible over its own tint. If the "
            + "fill opacity changed, re-derive the foreground rather than deleting this test."
        )
    }

    private func contrast(_ a: Color, _ b: Color, style: UIUserInterfaceStyle) -> Double {
        let la = luminance(a, style)
        let lb = luminance(b, style)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// WCAG relative luminance, from the colour as the system resolves it for `style`.
    private func luminance(_ color: Color, _ style: UIUserInterfaceStyle) -> Double {
        let resolved = UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha)

        func channel(_ value: CGFloat) -> Double {
            let v = Double(value)
            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }
    /// Composite a translucent colour over an opaque one, the way the renderer does.
    ///
    /// The gap this closes is the reason a real failure shipped. Every other assertion here
    /// measures a tone against one of the three named surfaces — but a translucent fill creates a
    /// colour that is in no token at all, and the text sits on *that*. `Chip` drew `color` on
    /// `color.opacity(0.14)`, so its true background was a tint of its own foreground, and the
    /// suite had no way to name it, let alone measure it.
    private func blend(
        _ foreground: Color, over background: Color, alpha: Double, style: UIUserInterfaceStyle
    ) -> Color {
        let traits = UITraitCollection(userInterfaceStyle: style)
        let f = UIColor(foreground).resolvedColor(with: traits)
        let b = UIColor(background).resolvedColor(with: traits)
        var fr: CGFloat = 0, fg: CGFloat = 0, fb: CGFloat = 0, fa: CGFloat = 0
        var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
        f.getRed(&fr, green: &fg, blue: &fb, alpha: &fa)
        b.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
        let a = CGFloat(alpha)
        return Color(
            .sRGB,
            red: Double(fr * a + br * (1 - a)),
            green: Double(fg * a + bg * (1 - a)),
            blue: Double(fb * a + bb * (1 - a)),
            opacity: 1
        )
    }
}
