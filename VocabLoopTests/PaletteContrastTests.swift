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

    /// White is *not* an acceptable foreground in dark mode — the point of `onRating`.
    /// If someone reverts to `.foregroundStyle(.white)`, this fails.
    func testPlainWhiteWouldFailInDarkMode() {
        let worst = Rating.allCases
            .map { contrast(.white, Palette.rating($0), style: .dark) }
            .min() ?? 0
        XCTAssertLessThan(
            worst, minimumRatio,
            "White has become legible on the dark rating fills — if the fills changed, "
            + "re-derive Palette.onRating rather than deleting this test."
        )
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
}
