import SwiftUI

// App-only: `CardMaturity` belongs to the SwiftData model layer, which the widget extension never
// compiles. The rest of `Palette` lives in `VocabLoopShared/`.

public extension Palette {
    /// Dots are non-text UI, so WCAG 1.4.11's 3:1 applies rather than 4.5:1 — but these sit well
    /// above it anyway (5.08:1 at worst, the light `new` dot), because a dot is small and that
    /// threshold assumes a shape whose edges you can already make out.
    static func maturity(_ maturity: CardMaturity) -> Color {
        switch maturity {
        case .new: Color(light: 0x7A6B55, dark: 0x8A8474)
        case .learning: Color(light: 0xB2681B, dark: 0xF2C46B)
        case .young: Color(light: 0x2F7A6B, dark: 0x7FD4C4)
        case .mature: Color(light: 0x2A62A8, dark: 0x8FBEF0)
        }
    }
}
