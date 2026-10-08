import SwiftUI

/// One word's sticker: the headword on a drawn chip whose look follows how well it is known.
///
/// - `locked` (not started): a dotted outline, the word in pencil-grey — visible, so a child can
///   see what is still to collect.
/// - `sketch` (new or learning): a grey pencil sketch with hatching.
/// - `coloured` (known, still settling): filled with the family's colour.
/// - `shiny` (well known): coloured, a thicker edge, a gloss and a sparkle.
///
/// The text is always ``Palette/textPrimary`` or a text tone on a surface, never the tint itself:
/// `PaletteContrastTests` measures ink over ``fillOpacity`` of every family tint, the same check
/// that keeps ``Chip`` legible. The art is static — a sticker that shimmers forever is motion
/// nobody asked for — so there is nothing for Reduce Motion to switch off.
struct StickerView: View {
    /// Strength of the family tint behind a coloured sticker's word. `internal` so the contrast
    /// suite measures the value actually drawn.
    static let fillOpacity: Double = 0.28

    let headword: String
    let family: WordFamily
    let state: StickerState

    var body: some View {
        let seed = WobbleShape.seed(for: headword)
        let shape = WobbleShape(cornerRadius: Radius.nested, amplitude: 1.2, seed: seed)

        Text(headword)
            .font(Typography.wordTitle)
            .foregroundStyle(textColor)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .minimumScaleFactor(0.45)
            .padding(.horizontal, Spacing.xs)
            .padding(.vertical, Spacing.sm)
            .frame(maxWidth: .infinity, minHeight: 72)
            .background {
                ZStack {
                    // The chunky base, only once a sticker is "real" — a sketch lies flat.
                    if isColoured || isShiny {
                        shape.fill(Chunky.baseColor).offset(y: 3)
                    }
                    // Opaque paper under the translucent tint, so the word sits on exactly the
                    // colour the contrast suite measures — not on the tint over the grey base.
                    shape.fill(Palette.surface)
                    shape.fill(fill)
                    if isSketch {
                        Hatching(seed: seed)
                            .clipShape(shape)
                    }
                    if isShiny {
                        Gloss()
                            .clipShape(shape)
                    }
                    shape.stroke(edge, style: edgeStyle)
                }
            }
            .overlay(alignment: .topTrailing) {
                if isShiny {
                    StickerSparkle()
                        .fill(Palette.rating(.hard))
                        .overlay(StickerSparkle().stroke(Palette.ratingEdge(.hard), lineWidth: 1))
                        .frame(width: 16, height: 16)
                        .offset(x: 4, y: -4)
                        .accessibilityHidden(true)
                }
            }
            // Reserve the base's height so it never overlaps the row below.
            .padding(.bottom, 3)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(headword)，\(Self.spokenState(state))")
    }

    static func spokenState(_ state: StickerState) -> String {
        switch state {
        case .locked: return "未开始"
        case .sketch: return "学习中"
        case .coloured: return "认识了"
        case .shiny: return "闪亮"
        }
    }

    // MARK: - Looks

    private var isSketch: Bool {
        if case .sketch = state { return true }
        return false
    }

    private var isColoured: Bool {
        if case .coloured = state { return true }
        return false
    }

    private var isShiny: Bool {
        if case .shiny = state { return true }
        return false
    }

    private var fill: Color {
        switch state {
        case .locked: return Palette.surface
        case .sketch: return Palette.surfaceRaised
        case .coloured, .shiny: return family.tint.opacity(Self.fillOpacity)
        }
    }

    private var textColor: Color {
        switch state {
        case .locked: return Palette.textTertiary
        case .sketch: return Palette.textSecondary
        case .coloured, .shiny: return Palette.textPrimary
        }
    }

    private var edge: Color {
        switch state {
        case .locked: return Palette.textTertiary
        case .sketch: return Palette.textSecondary
        case .coloured, .shiny: return family.tint
        }
    }

    private var edgeStyle: StrokeStyle {
        switch state {
        case .locked: return StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [2, 4])
        case .sketch: return StrokeStyle(lineWidth: 1.2, lineCap: .round, dash: [7, 2, 3, 2])
        case .coloured: return StrokeStyle(lineWidth: 2.5, lineCap: .round)
        case .shiny: return StrokeStyle(lineWidth: 3.5, lineCap: .round)
        }
    }
}

// MARK: - Decoration

/// Light pencil hatching for a sketched sticker.
private struct Hatching: View {
    let seed: UInt64

    var body: some View {
        Canvas { context, size in
            var generator = SeededGenerator(seed: seed)
            let spacing: CGFloat = 9
            var x: CGFloat = -size.height
            while x < size.width {
                let wobble = CGFloat(Double.random(in: -1.5...1.5, using: &generator))
                var line = Path()
                line.move(to: CGPoint(x: x, y: size.height))
                line.addLine(to: CGPoint(x: x + size.height + wobble, y: 0))
                context.stroke(line, with: .color(Palette.textTertiary.opacity(0.18)), lineWidth: 1)
                x += spacing
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A diagonal sheen across the top-left corner, away from the word.
private struct Gloss: View {
    var body: some View {
        Canvas { context, size in
            var band = Path()
            band.move(to: CGPoint(x: 0, y: size.height * 0.42))
            band.addLine(to: CGPoint(x: size.width * 0.3, y: 0))
            band.addLine(to: CGPoint(x: size.width * 0.42, y: 0))
            band.addLine(to: CGPoint(x: 0, y: size.height * 0.6))
            band.closeSubpath()
            context.fill(band, with: .color(Palette.surface.opacity(0.55)))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The concave four-point twinkle used across the app.
struct StickerSparkle: Shape {
    func path(in rect: CGRect) -> Path {
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        var star = Path()
        star.move(to: CGPoint(x: centre.x, y: rect.minY))
        star.addQuadCurve(to: CGPoint(x: rect.maxX, y: centre.y), control: centre)
        star.addQuadCurve(to: CGPoint(x: centre.x, y: rect.maxY), control: centre)
        star.addQuadCurve(to: CGPoint(x: rect.minX, y: centre.y), control: centre)
        star.addQuadCurve(to: CGPoint(x: centre.x, y: rect.minY), control: centre)
        star.closeSubpath()
        return star
    }
}
