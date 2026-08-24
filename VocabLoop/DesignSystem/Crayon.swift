import Foundation
import SwiftUI

// MARK: - Hand-drawn outline

/// A rounded rectangle that looks drawn rather than computed.
///
/// The whole "crayon" direction rests on this one shape. A handwriting *font* was the obvious
/// way to get the look, and it is not available: the project generates its `Info.plist` from
/// `INFOPLIST_KEY_*` build settings, `UIAppFonts` is not one of the keys that mechanism
/// supports, and adding a real plist is a project-file change that cannot be verified without
/// Xcode. So the character has to come from geometry instead — which is the better trade
/// anyway, because a wobbling *outline* reads as hand-drawn on every control at once, while a
/// font only ever affects text.
///
/// The wobble is deterministic, seeded, and computed once per layout — never animated. A border
/// that shimmers frame to frame stops looking like pencil and starts looking like a rendering
/// bug, and it is exactly the kind of motion the Reduce Motion setting exists to suppress.
public struct WobbleShape: InsettableShape {
    /// How far each sample point may drift, in points. Above roughly 3 the corners start to
    /// pinch and the rectangle stops reading as a rectangle.
    public var amplitude: CGFloat
    public var cornerRadius: CGFloat
    /// Give sibling cards different seeds so no two wobble identically — that repetition is
    /// what makes a "hand-drawn" UI look machine-made.
    public var seed: UInt64

    private var insetAmount: CGFloat = 0

    public init(cornerRadius: CGFloat = Radius.card, amplitude: CGFloat = 1.5, seed: UInt64 = 0x_C7A1_0000_0000_0001) {
        self.cornerRadius = cornerRadius
        self.amplitude = amplitude
        self.seed = seed
    }

    /// A stable seed from any string identifier.
    ///
    /// FNV-1a rather than `hashValue`: Swift seeds its string hashing per process, so
    /// `hashValue` would give the same card a different outline on every launch. ``Fuzz`` hashes
    /// its own inputs for exactly this reason.
    public static func seed(for identifier: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in identifier.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x1000_0000_01b3
        }
        return hash
    }

    public func inset(by amount: CGFloat) -> some InsettableShape {
        var copy = self
        copy.insetAmount += amount
        return copy
    }

    public func path(in rect: CGRect) -> Path {
        let box = rect.insetBy(dx: insetAmount, dy: insetAmount)
        guard box.width > 1, box.height > 1 else { return Path() }

        var generator = SeededGenerator(seed: seed)
        let points = Self.perimeter(of: box, radius: cornerRadius).map { point -> CGPoint in
            CGPoint(
                x: point.x + CGFloat(Double.random(in: -amplitude...amplitude, using: &generator)),
                y: point.y + CGFloat(Double.random(in: -amplitude...amplitude, using: &generator))
            )
        }
        return Self.smoothedLoop(through: points)
    }

    /// Sample points once around a rounded rectangle: four corner arcs joined by four edges.
    private static func perimeter(of rect: CGRect, radius: CGFloat) -> [CGPoint] {
        let r = max(0, min(radius, min(rect.width, rect.height) / 2))
        let centres = [
            CGPoint(x: rect.maxX - r, y: rect.minY + r),
            CGPoint(x: rect.maxX - r, y: rect.maxY - r),
            CGPoint(x: rect.minX + r, y: rect.maxY - r),
            CGPoint(x: rect.minX + r, y: rect.minY + r),
        ]
        let startAngles: [Double] = [-90, 0, 90, 180]
        let arcSteps = 4
        let edgeSteps = 5

        var points: [CGPoint] = []
        for index in 0..<4 {
            let centre = centres[index]
            for step in 0...arcSteps {
                let degrees = startAngles[index] + 90 * Double(step) / Double(arcSteps)
                let radians = degrees * .pi / 180
                points.append(CGPoint(x: centre.x + r * cos(radians), y: centre.y + r * sin(radians)))
            }
            // Walk the straight edge to where the next arc begins.
            let nextIndex = (index + 1) % 4
            let nextRadians = startAngles[nextIndex] * .pi / 180
            let target = CGPoint(
                x: centres[nextIndex].x + r * cos(nextRadians),
                y: centres[nextIndex].y + r * sin(nextRadians)
            )
            guard let from = points.last else { continue }
            for step in 1..<edgeSteps {
                let t = CGFloat(step) / CGFloat(edgeSteps)
                points.append(CGPoint(x: from.x + (target.x - from.x) * t, y: from.y + (target.y - from.y) * t))
            }
        }
        return points
    }

    /// Curve *through* the jittered points rather than connecting them with straight lines.
    ///
    /// Each sample becomes a quadratic control point and the curve passes through the midpoints
    /// between them, which is the standard way to smooth a closed polyline. Straight segments
    /// between jittered points would read as a low-poly shape, not a drawn one.
    private static func smoothedLoop(through points: [CGPoint]) -> Path {
        var path = Path()
        guard points.count > 2 else { return path }
        func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
            CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        }
        path.move(to: midpoint(points[points.count - 1], points[0]))
        for index in points.indices {
            let current = points[index]
            let next = points[(index + 1) % points.count]
            path.addQuadCurve(to: midpoint(current, next), control: current)
        }
        path.closeSubpath()
        return path
    }
}

// MARK: - Paper

/// The speckle that stops a flat fill reading as a screen.
///
/// Drawn in one `Canvas` rather than as a stack of views, and it never animates — this is a
/// static texture, so there is no `TimelineView` here and nothing to pause.
public struct PaperGrain: View {
    private let density: Int
    private let seed: UInt64

    public init(density: Int = 700, seed: UInt64 = 0x_9A9E_5EED_0000_0011) {
        self.density = density
        self.seed = seed
    }

    public var body: some View {
        Canvas { context, size in
            var generator = SeededGenerator(seed: seed)
            for _ in 0..<density {
                let x = Double.random(in: 0...Double(size.width), using: &generator)
                let y = Double.random(in: 0...Double(size.height), using: &generator)
                let radius = Double.random(in: 0.35...0.95, using: &generator)
                let alpha = Double.random(in: 0.05...0.16, using: &generator)
                context.fill(
                    Path(ellipseIn: CGRect(x: x, y: y, width: radius * 2, height: radius * 2)),
                    with: .color(Palette.textPrimary.opacity(alpha))
                )
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Nested panels

public extension View {
    /// A drawn sub-panel: `surfaceRaised` inside a wobbling outline.
    ///
    /// For the blocks *inside* a card — a sense, a grammar note. A hand-drawn card containing
    /// machine-drawn boxes reads as a mistake: the eye catches the two languages immediately,
    /// even when it cannot say what is wrong.
    ///
    /// Lighter than the card's own outline (1.5pt against 2.5pt, and a smaller amplitude), so
    /// the nesting still reads as nesting rather than as two cards fighting.
    func drawnPanel(seed: UInt64, cornerRadius: CGFloat = Radius.nested) -> some View {
        background {
            let shape = WobbleShape(cornerRadius: cornerRadius, amplitude: 1.0, seed: seed)
            shape.fill(Palette.surfaceRaised)
                .overlay(shape.stroke(Palette.separator.opacity(0.55), lineWidth: 1.5))
        }
    }
}
