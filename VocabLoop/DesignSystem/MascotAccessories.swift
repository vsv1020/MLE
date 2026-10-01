import SwiftUI

/// One filled and/or outlined shape in Mochi's drawing.
///
/// Accessories are built as *data* — a list of paths with their paint — and only then rendered.
/// That split is what lets `MascotAccessoryTests` measure every item's real geometry against the
/// frame at both the study-card size and the wardrobe size, instead of trusting that a hat which
/// looked fine in one preview still fits at 58×48.
struct MascotMark {
    var path: Path
    var fill: Color?
    var stroke: Color?
    var lineWidth: CGFloat
    var dash: [CGFloat]

    init(_ path: Path, fill: Color? = nil, stroke: Color? = nil, lineWidth: CGFloat = 0, dash: [CGFloat] = []) {
        self.path = path
        self.fill = fill
        self.stroke = stroke
        self.lineWidth = lineWidth
        self.dash = dash
    }

    /// Everything the mark can paint, stroke included.
    var paintedBounds: CGRect {
        let tight = path.cgPath.boundingBoxOfPath
        guard stroke != nil, lineWidth > 0 else { return tight }
        return tight.insetBy(dx: -lineWidth / 2, dy: -lineWidth / 2)
    }
}

/// Mochi's growth stages, body details and wardrobe, all drawn from paths — no image assets.
///
/// **Coordinates.** Every item is placed in *body units*: `x` runs `0…1` across the body's width
/// and `y` runs `0…1` down its height, so negative `y` is above the head. Radii are in body widths
/// so circles stay round. Nothing is a fixed point size, which is why the same drawing works on
/// the 58×48 study card and the 160×133 wardrobe preview.
///
/// **Room.** Mochi's body fills its whole frame when nothing sticks out, so an undressed sprout
/// draws exactly as it did before 1.0.7. A hat, a cape or a stage crest needs space outside the
/// body, and a `Canvas` cannot paint outside its frame without risking a neighbour — so the body
/// shrinks, bottom-anchored, to make room (``bodyRect(for:in:)``). The *frame* never changes,
/// which is the plan's rule: the stage changes the drawing, not the layout around it.
///
/// **Colour.** Palette tokens only, every shape outlined in ``Palette/separator`` like the body —
/// the outline is what makes a bright accessory read in both appearances (WCAG 1.4.11 asks a
/// graphic for 3:1, and the outline gives it that against paper and blackboard alike).
enum MascotAccessories {
    // MARK: - Room

    /// Fraction of the frame's height kept above the body for a head item.
    static let headRoom: CGFloat = 0.26
    /// Fraction kept above the body for a stage crest (leaf tuft, sparkle line).
    static let crestRoom: CGFloat = 0.16
    /// Fraction of the frame's width kept on each side for a cape.
    static let backRoom: CGFloat = 0.07

    /// Where the body sits inside a frame of `size` for `look`.
    static func bodyRect(for look: MochiLook, in size: CGSize) -> CGRect {
        var top: CGFloat = 0
        var side: CGFloat = 0
        if wearsSomething(on: .head, look) {
            top = headRoom
        } else if showsCrest(look) {
            top = crestRoom
        }
        if wearsSomething(on: .back, look) {
            side = backRoom
        }
        let scale = min(1 - top, 1 - 2 * side)
        let width = size.width * scale
        let height = size.height * scale
        return CGRect(x: (size.width - width) / 2, y: size.height - height, width: width, height: height)
    }

    static func wearsSomething(on slot: MochiAccessory.Slot, _ look: MochiLook) -> Bool {
        look.accessories.contains { $0.slot == slot }
    }

    /// The leaf tuft or the sparkle line. A hat covers it, so it is only drawn bare-headed.
    static func showsCrest(_ look: MochiLook) -> Bool {
        guard !wearsSomething(on: .head, look) else { return false }
        switch look.stage {
        case .sprout: return false
        case .kid, .teen, .grown: return true
        }
    }

    // MARK: - Layers

    /// Drawn before the body: the cape's cloth.
    static func behindMarks(for look: MochiLook, body: CGRect) -> [MascotMark] {
        guard look.accessories.contains(.cape) else { return [] }
        return capeCloth(BodyUnits(body))
    }

    /// Drawn on the body, under the face, in the body's own coordinates (origin at its corner).
    static func underFaceMarks(for look: MochiLook, size: CGSize) -> [MascotMark] {
        let g = BodyUnits(CGRect(origin: .zero, size: size))
        var marks: [MascotMark] = []

        if look.color == .galaxy {
            // Specks of starlight, so the Plus colour is more than a tint.
            for (x, y, arm) in [(0.2, 0.26, 0.03), (0.8, 0.27, 0.025), (0.27, 0.8, 0.025),
                                (0.82, 0.72, 0.03), (0.12, 0.55, 0.02)] as [(CGFloat, CGFloat, CGFloat)] {
                marks.append(MascotMark(g.sparkle(x, y, arm: arm), fill: Palette.rating(.hard)))
            }
        }

        switch look.stage {
        case .sprout, .kid:
            break
        case .teen, .grown:
            // A bigger blush, laid under the face's own so the two read as one rosier cheek.
            for side in [-1.0, 1.0] as [CGFloat] {
                marks.append(MascotMark(
                    g.ellipse(0.5 + side * 0.29, 0.565, width: 0.21, height: 0.12),
                    fill: Palette.rating(.again).opacity(0.3)
                ))
            }
            // A star on the belly.
            marks.append(MascotMark(
                g.star(0.5, 0.83, outer: 0.065, inner: 0.03),
                fill: Palette.rating(.hard), stroke: Palette.separator, lineWidth: g.line * 0.6
            ))
        }
        return marks
    }

    /// Drawn after the face, in the frame's coordinates: everything worn, then the crest.
    static func frontMarks(for look: MochiLook, body: CGRect) -> [MascotMark] {
        var marks: [MascotMark] = []
        for slot in [MochiAccessory.Slot.back, .neck, .eyes, .head] {
            for accessory in look.accessories where accessory.slot == slot {
                marks += self.marks(for: accessory, body: body)
            }
        }
        if showsCrest(look) {
            marks += crestMarks(for: look.stage, body: body)
        }
        return marks
    }

    static func render(_ marks: [MascotMark], in context: inout GraphicsContext) {
        for mark in marks {
            if let fill = mark.fill {
                context.fill(mark.path, with: .color(fill))
            }
            if let stroke = mark.stroke, mark.lineWidth > 0 {
                context.stroke(
                    mark.path, with: .color(stroke),
                    style: StrokeStyle(lineWidth: mark.lineWidth, lineCap: .round, lineJoin: .round, dash: mark.dash)
                )
            }
        }
    }

    /// Draw one accessory on a body occupying `body`. The cape's cloth is drawn separately, behind
    /// the body — see ``behindMarks(for:body:)``.
    static func draw(_ accessory: MochiAccessory, in context: inout GraphicsContext, body: CGRect) {
        render(marks(for: accessory, body: body), in: &context)
    }

    // MARK: - Stage crest

    static func crestMarks(for stage: MochiStage, body: CGRect) -> [MascotMark] {
        let g = BodyUnits(body)
        switch stage {
        case .sprout:
            return []
        case .kid, .teen:
            // A tiny leaf tuft: a stem and two leaves.
            var stem = Path()
            stem.move(to: g.p(0.5, 0.03))
            stem.addQuadCurve(to: g.p(0.515, -0.075), control: g.p(0.49, -0.03))
            var left = Path()
            left.move(to: g.p(0.51, -0.05))
            left.addQuadCurve(to: g.p(0.38, -0.11), control: g.p(0.43, -0.01))
            left.addQuadCurve(to: g.p(0.51, -0.05), control: g.p(0.45, -0.15))
            left.closeSubpath()
            var right = Path()
            right.move(to: g.p(0.515, -0.07))
            right.addQuadCurve(to: g.p(0.66, -0.12), control: g.p(0.6, -0.03))
            right.addQuadCurve(to: g.p(0.515, -0.07), control: g.p(0.58, -0.17))
            right.closeSubpath()
            return [
                MascotMark(stem, stroke: Palette.success, lineWidth: g.line * 1.2),
                MascotMark(left, fill: Palette.success, stroke: Palette.separator, lineWidth: g.line * 0.8),
                MascotMark(right, fill: Palette.success, stroke: Palette.separator, lineWidth: g.line * 0.8),
            ]
        case .grown:
            // A line of sparkles arching over the head, like a crown drawn in light.
            let start = CGPoint(x: 0.22, y: -0.01)
            let control = CGPoint(x: 0.5, y: -0.2)
            let end = CGPoint(x: 0.78, y: -0.01)
            var arc = Path()
            arc.move(to: g.p(start.x, start.y))
            arc.addQuadCurve(to: g.p(end.x, end.y), control: g.p(control.x, control.y))
            var marks = [MascotMark(arc, stroke: Palette.textTertiary, lineWidth: g.line * 0.6,
                                    dash: [g.line * 0.6, g.line * 1.8])]
            let steps: [(t: CGFloat, arm: CGFloat)] = [(0, 0.03), (0.25, 0.035), (0.5, 0.04), (0.75, 0.035), (1, 0.03)]
            for (index, step) in steps.enumerated() {
                let t = step.t
                let x = (1 - t) * (1 - t) * start.x + 2 * (1 - t) * t * control.x + t * t * end.x
                let y = (1 - t) * (1 - t) * start.y + 2 * (1 - t) * t * control.y + t * t * end.y
                let colour = index.isMultiple(of: 2) ? Palette.rating(.hard) : Palette.brandSecondary
                marks.append(MascotMark(g.sparkle(x, y, arm: step.arm), fill: colour))
            }
            return marks
        }
    }

    // MARK: - Accessories

    /// Everything one accessory paints in front of the body.
    static func marks(for accessory: MochiAccessory, body: CGRect) -> [MascotMark] {
        let g = BodyUnits(body)
        switch accessory {
        case .redScarf: return scarf(g, stripes: nil)
        case .rainbowScarf:
            return scarf(g, stripes: [Palette.rating(.again), Palette.rating(.hard), Palette.rating(.good), Palette.rating(.easy)])
        case .goldStarPin: return goldStarPin(g)
        case .roundGlasses: return roundGlasses(g)
        case .cape: return capeTies(g)
        case .partyHat: return partyHat(g)
        case .bow: return bow(g)
        case .strawHat: return strawHat(g)
        case .crown: return crown(g)
        case .headphones: return headphones(g)
        case .nightcap: return nightcap(g)
        case .sunVisor: return sunVisor(g)
        case .graduationCap: return graduationCap(g)
        case .wizardHat: return wizardHat(g)
        case .halo: return halo(g)
        case .astronautHelmet: return astronautHelmet(g)
        }
    }

    // MARK: Neck

    /// A band wrapped round the lower body plus a hanging tail. `stripes` paints the band in
    /// horizontal bands (the rainbow scarf) instead of one colour.
    private static func scarf(_ g: BodyUnits, stripes: [Color]?) -> [MascotMark] {
        let ink = Palette.separator
        let upper = (start: CGPoint(x: 0.07, y: 0.70), control: CGPoint(x: 0.5, y: 0.80), end: CGPoint(x: 0.93, y: 0.70))
        let lower = (start: CGPoint(x: 0.05, y: 0.82), control: CGPoint(x: 0.5, y: 0.94), end: CGPoint(x: 0.95, y: 0.82))
        func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
            CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        }
        func band(from t0: CGFloat, to t1: CGFloat) -> Path {
            var path = Path()
            path.move(to: g.p(lerp(upper.start, lower.start, t0)))
            path.addQuadCurve(to: g.p(lerp(upper.end, lower.end, t0)), control: g.p(lerp(upper.control, lower.control, t0)))
            path.addLine(to: g.p(lerp(upper.end, lower.end, t1)))
            path.addQuadCurve(to: g.p(lerp(upper.start, lower.start, t1)), control: g.p(lerp(upper.control, lower.control, t1)))
            path.closeSubpath()
            return path
        }

        let tail = g.polygon([(0.63, 0.80), (0.77, 0.79), (0.8, 0.95), (0.66, 0.96)])
        var marks: [MascotMark] = []
        if let stripes, !stripes.isEmpty {
            marks.append(MascotMark(tail, fill: stripes[stripes.count - 1], stroke: ink, lineWidth: g.line))
            let step = 1 / CGFloat(stripes.count)
            for (index, colour) in stripes.enumerated() {
                marks.append(MascotMark(band(from: CGFloat(index) * step, to: CGFloat(index + 1) * step), fill: colour))
            }
            marks.append(MascotMark(band(from: 0, to: 1), stroke: ink, lineWidth: g.line))
        } else {
            marks.append(MascotMark(tail, fill: Palette.danger, stroke: ink, lineWidth: g.line))
            marks.append(MascotMark(band(from: 0, to: 1), fill: Palette.danger, stroke: ink, lineWidth: g.line))
            // A knitted stripe along the middle.
            var stripe = Path()
            stripe.move(to: g.p(lerp(upper.start, lower.start, 0.5)))
            stripe.addQuadCurve(to: g.p(lerp(upper.end, lower.end, 0.5)), control: g.p(lerp(upper.control, lower.control, 0.5)))
            marks.append(MascotMark(stripe, stroke: Palette.surface.opacity(0.6), lineWidth: g.line * 0.7,
                                    dash: [g.line * 1.5, g.line * 1.2]))
        }
        return marks
    }

    private static func goldStarPin(_ g: BodyUnits) -> [MascotMark] {
        [
            MascotMark(g.star(0.68, 0.76, outer: 0.085, inner: 0.04),
                       fill: Palette.rating(.hard), stroke: Palette.separator, lineWidth: g.line * 0.8),
            MascotMark(g.sparkle(0.81, 0.67, arm: 0.03), fill: Palette.rating(.hard)),
        ]
    }

    // MARK: Eyes

    private static func roundGlasses(_ g: BodyUnits) -> [MascotMark] {
        let ink = Palette.textPrimary
        var marks: [MascotMark] = []
        for side in [-1.0, 1.0] as [CGFloat] {
            let lens = g.circle(0.5 + side * 0.17, 0.45, radius: 0.1)
            marks.append(MascotMark(lens, fill: Palette.surface.opacity(0.2), stroke: ink, lineWidth: g.line * 1.1))
            var temple = Path()
            temple.move(to: g.p(0.5 + side * 0.27, 0.43))
            temple.addLine(to: g.p(0.5 + side * 0.43, 0.4))
            marks.append(MascotMark(temple, stroke: ink, lineWidth: g.line))
        }
        var bridge = Path()
        bridge.move(to: g.p(0.43, 0.44))
        bridge.addQuadCurve(to: g.p(0.57, 0.44), control: g.p(0.5, 0.39))
        marks.append(MascotMark(bridge, stroke: ink, lineWidth: g.line))
        return marks
    }

    // MARK: Back

    private static func capeCloth(_ g: BodyUnits) -> [MascotMark] {
        var cloth = Path()
        cloth.move(to: g.p(0.14, 0.6))
        cloth.addQuadCurve(to: g.p(0.86, 0.6), control: g.p(0.5, 0.7))
        cloth.addLine(to: g.p(1.05, 0.95))
        cloth.addQuadCurve(to: g.p(-0.05, 0.95), control: g.p(0.5, 0.97))
        cloth.closeSubpath()
        return [MascotMark(cloth, fill: Palette.brandSecondary, stroke: Palette.separator, lineWidth: g.line)]
    }

    private static func capeTies(_ g: BodyUnits) -> [MascotMark] {
        var left = Path()
        left.move(to: g.p(0.1, 0.64))
        left.addQuadCurve(to: g.p(0.46, 0.77), control: g.p(0.26, 0.76))
        var right = Path()
        right.move(to: g.p(0.9, 0.64))
        right.addQuadCurve(to: g.p(0.54, 0.77), control: g.p(0.74, 0.76))
        return [
            MascotMark(left, stroke: Palette.brandSecondary, lineWidth: g.line * 1.2),
            MascotMark(right, stroke: Palette.brandSecondary, lineWidth: g.line * 1.2),
            MascotMark(g.circle(0.5, 0.77, radius: 0.035),
                       fill: Palette.rating(.hard), stroke: Palette.separator, lineWidth: g.line * 0.6),
        ]
    }

    // MARK: Head

    private static func partyHat(_ g: BodyUnits) -> [MascotMark] {
        var cone = Path()
        cone.move(to: g.p(0.37, 0.1))
        cone.addLine(to: g.p(0.53, -0.27))
        cone.addLine(to: g.p(0.65, 0.08))
        cone.addQuadCurve(to: g.p(0.37, 0.1), control: g.p(0.51, 0.14))
        cone.closeSubpath()
        let dot = Palette.rating(.hard)
        return [
            MascotMark(cone, fill: Palette.brandPrimary, stroke: Palette.separator, lineWidth: g.line),
            MascotMark(g.circle(0.5, 0.03, radius: 0.026), fill: dot),
            MascotMark(g.circle(0.53, -0.1, radius: 0.02), fill: dot),
            MascotMark(g.circle(0.47, -0.04, radius: 0.016), fill: dot),
            MascotMark(g.circle(0.53, -0.27, radius: 0.04), fill: dot, stroke: Palette.separator, lineWidth: g.line * 0.8),
        ]
    }

    private static func bow(_ g: BodyUnits) -> [MascotMark] {
        let fill = Palette.rating(.again)
        var left = Path()
        left.move(to: g.p(0.72, 0.05))
        left.addQuadCurve(to: g.p(0.57, 0.11), control: g.p(0.58, -0.1))
        left.addQuadCurve(to: g.p(0.72, 0.05), control: g.p(0.66, 0.13))
        left.closeSubpath()
        var right = Path()
        right.move(to: g.p(0.72, 0.05))
        right.addQuadCurve(to: g.p(0.87, 0.11), control: g.p(0.86, -0.1))
        right.addQuadCurve(to: g.p(0.72, 0.05), control: g.p(0.78, 0.13))
        right.closeSubpath()
        return [
            MascotMark(left, fill: fill, stroke: Palette.separator, lineWidth: g.line),
            MascotMark(right, fill: fill, stroke: Palette.separator, lineWidth: g.line),
            MascotMark(g.circle(0.72, 0.05, radius: 0.035), fill: fill, stroke: Palette.separator, lineWidth: g.line),
        ]
    }

    private static func strawHat(_ g: BodyUnits) -> [MascotMark] {
        let straw = Palette.rating(.hard)
        var crown = Path()
        crown.move(to: g.p(0.31, 0.075))
        crown.addLine(to: g.p(0.33, -0.12))
        crown.addQuadCurve(to: g.p(0.67, -0.12), control: g.p(0.5, -0.21))
        crown.addLine(to: g.p(0.69, 0.075))
        crown.addQuadCurve(to: g.p(0.31, 0.075), control: g.p(0.5, 0.11))
        crown.closeSubpath()
        return [
            MascotMark(g.ellipse(0.5, 0.075, width: 0.9, height: 0.12), fill: straw, stroke: Palette.separator, lineWidth: g.line),
            MascotMark(crown, fill: straw, stroke: Palette.separator, lineWidth: g.line),
            MascotMark(g.polygon([(0.322, -0.005), (0.678, -0.005), (0.684, 0.05), (0.316, 0.05)]),
                       fill: Palette.danger, stroke: Palette.separator, lineWidth: g.line * 0.6),
        ]
    }

    private static func crown(_ g: BodyUnits) -> [MascotMark] {
        let gold = Palette.rating(.hard)
        var band = Path()
        band.move(to: g.p(0.3, 0.1))
        band.addLine(to: g.p(0.28, -0.16))
        band.addLine(to: g.p(0.39, -0.04))
        band.addLine(to: g.p(0.5, -0.21))
        band.addLine(to: g.p(0.61, -0.04))
        band.addLine(to: g.p(0.72, -0.16))
        band.addLine(to: g.p(0.7, 0.1))
        band.addQuadCurve(to: g.p(0.3, 0.1), control: g.p(0.5, 0.13))
        band.closeSubpath()
        return [
            MascotMark(band, fill: gold, stroke: Palette.separator, lineWidth: g.line),
            MascotMark(g.circle(0.28, -0.16, radius: 0.018), fill: gold, stroke: Palette.separator, lineWidth: g.line * 0.6),
            MascotMark(g.circle(0.5, -0.21, radius: 0.02), fill: gold, stroke: Palette.separator, lineWidth: g.line * 0.6),
            MascotMark(g.circle(0.72, -0.16, radius: 0.018), fill: gold, stroke: Palette.separator, lineWidth: g.line * 0.6),
            MascotMark(g.circle(0.5, 0.03, radius: 0.03), fill: Palette.rating(.again)),
            MascotMark(g.circle(0.385, 0.05, radius: 0.022), fill: Palette.rating(.easy)),
            MascotMark(g.circle(0.615, 0.05, radius: 0.022), fill: Palette.rating(.easy)),
        ]
    }

    private static func headphones(_ g: BodyUnits) -> [MascotMark] {
        var band = Path()
        band.move(to: g.p(0.06, 0.4))
        band.addQuadCurve(to: g.p(0.94, 0.4), control: g.p(0.5, -0.56))
        var marks = [
            MascotMark(band, stroke: Palette.separator, lineWidth: g.line * 3.2),
            MascotMark(band, stroke: Palette.brandPrimary, lineWidth: g.line * 1.8),
        ]
        for x in [-0.05, 0.9] as [CGFloat] {
            let cup = Path(
                roundedRect: CGRect(origin: g.p(x, 0.3), size: CGSize(width: g.width * 0.15, height: g.height * 0.3)),
                cornerRadius: g.width * 0.06
            )
            marks.append(MascotMark(cup, fill: Palette.brandPrimary, stroke: Palette.separator, lineWidth: g.line))
        }
        return marks
    }

    private static func nightcap(_ g: BodyUnits) -> [MascotMark] {
        var cap = Path()
        cap.move(to: g.p(0.18, 0.17))
        cap.addQuadCurve(to: g.p(0.93, -0.1), control: g.p(0.34, -0.32))
        cap.addQuadCurve(to: g.p(0.82, 0.16), control: g.p(0.74, -0.04))
        cap.addQuadCurve(to: g.p(0.18, 0.17), control: g.p(0.5, 0.24))
        cap.closeSubpath()
        var band = Path()
        band.move(to: g.p(0.15, 0.13))
        band.addQuadCurve(to: g.p(0.85, 0.13), control: g.p(0.5, -0.01))
        band.addLine(to: g.p(0.86, 0.22))
        band.addQuadCurve(to: g.p(0.14, 0.22), control: g.p(0.5, 0.1))
        band.closeSubpath()
        return [
            MascotMark(cap, fill: Palette.brandPrimary, stroke: Palette.separator, lineWidth: g.line),
            MascotMark(g.sparkle(0.42, -0.02, arm: 0.035), fill: Palette.rating(.hard)),
            MascotMark(g.sparkle(0.63, -0.08, arm: 0.03), fill: Palette.rating(.hard)),
            MascotMark(band, fill: Palette.surfaceRaised, stroke: Palette.separator, lineWidth: g.line),
            MascotMark(g.circle(0.93, -0.1, radius: 0.05), fill: Palette.surface, stroke: Palette.separator, lineWidth: g.line),
        ]
    }

    private static func sunVisor(_ g: BodyUnits) -> [MascotMark] {
        var bill = Path()
        bill.move(to: g.p(0.2, 0.29))
        bill.addQuadCurve(to: g.p(0.8, 0.29), control: g.p(0.5, 0.44))
        bill.addQuadCurve(to: g.p(0.2, 0.29), control: g.p(0.5, 0.16))
        bill.closeSubpath()
        var band = Path()
        band.move(to: g.p(0.1, 0.25))
        band.addQuadCurve(to: g.p(0.9, 0.25), control: g.p(0.5, -0.05))
        band.addLine(to: g.p(0.88, 0.32))
        band.addQuadCurve(to: g.p(0.12, 0.32), control: g.p(0.5, 0.04))
        band.closeSubpath()
        return [
            MascotMark(bill, fill: Palette.rating(.good), stroke: Palette.separator, lineWidth: g.line),
            MascotMark(band, fill: Palette.success, stroke: Palette.separator, lineWidth: g.line),
        ]
    }

    private static func graduationCap(_ g: BodyUnits) -> [MascotMark] {
        var skull = Path()
        skull.move(to: g.p(0.28, -0.06))
        skull.addLine(to: g.p(0.28, 0.1))
        skull.addQuadCurve(to: g.p(0.72, 0.1), control: g.p(0.5, 0.17))
        skull.addLine(to: g.p(0.72, -0.06))
        skull.closeSubpath()
        var tassel = Path()
        tassel.move(to: g.p(0.5, -0.105))
        tassel.addLine(to: g.p(0.86, -0.06))
        tassel.addLine(to: g.p(0.87, 0.1))
        let gold = Palette.rating(.hard)
        return [
            MascotMark(skull, fill: Palette.textSecondary, stroke: Palette.separator, lineWidth: g.line),
            MascotMark(g.polygon([(0.5, -0.24), (0.95, -0.1), (0.5, 0.03), (0.05, -0.1)]),
                       fill: Palette.textPrimary, stroke: Palette.separator, lineWidth: g.line),
            MascotMark(tassel, stroke: gold, lineWidth: g.line * 1.3),
            MascotMark(g.circle(0.5, -0.105, radius: 0.025), fill: gold),
            MascotMark(g.polygon([(0.845, 0.08), (0.895, 0.08), (0.905, 0.16), (0.835, 0.16)]),
                       fill: gold, stroke: Palette.separator, lineWidth: g.line * 0.6),
        ]
    }

    private static func wizardHat(_ g: BodyUnits) -> [MascotMark] {
        let cloth = Palette.rating(.easy)
        var cone = Path()
        cone.move(to: g.p(0.29, 0.08))
        cone.addQuadCurve(to: g.p(0.66, -0.31), control: g.p(0.38, -0.1))
        cone.addQuadCurve(to: g.p(0.71, 0.08), control: g.p(0.6, -0.12))
        cone.addQuadCurve(to: g.p(0.29, 0.08), control: g.p(0.5, 0.12))
        cone.closeSubpath()
        return [
            MascotMark(g.ellipse(0.5, 0.08, width: 0.8, height: 0.13), fill: cloth, stroke: Palette.separator, lineWidth: g.line),
            MascotMark(cone, fill: cloth, stroke: Palette.separator, lineWidth: g.line),
            MascotMark(g.sparkle(0.48, -0.01, arm: 0.045), fill: Palette.rating(.hard)),
            MascotMark(g.sparkle(0.57, -0.15, arm: 0.03), fill: Palette.rating(.hard)),
            MascotMark(g.circle(0.4, 0.04, radius: 0.012), fill: Palette.rating(.hard)),
        ]
    }

    private static func halo(_ g: BodyUnits) -> [MascotMark] {
        let ring = g.ellipse(0.5, -0.17, width: 0.56, height: 0.12)
        return [
            MascotMark(ring, stroke: Palette.separator, lineWidth: g.line * 3),
            MascotMark(ring, stroke: Palette.rating(.hard), lineWidth: g.line * 1.8),
            MascotMark(g.sparkle(0.84, -0.2, arm: 0.045), fill: Palette.rating(.hard)),
        ]
    }

    private static func astronautHelmet(_ g: BodyUnits) -> [MascotMark] {
        let bubble = Path(ellipseIn: CGRect(origin: g.p(-0.1, -0.24), size: CGSize(width: g.width * 1.2, height: g.height * 1.22)))
        var glint = Path()
        glint.move(to: g.p(0.06, 0.22))
        glint.addQuadCurve(to: g.p(0.34, -0.17), control: g.p(0.08, -0.12))
        var antenna = Path()
        antenna.move(to: g.p(0.5, -0.24))
        antenna.addLine(to: g.p(0.5, -0.28))
        let collar = Path(
            roundedRect: CGRect(origin: g.p(0.06, 0.8), size: CGSize(width: g.width * 0.88, height: g.height * 0.17)),
            cornerRadius: g.width * 0.06
        )
        return [
            MascotMark(bubble, fill: Palette.surface.opacity(0.22), stroke: Palette.separator, lineWidth: g.line),
            MascotMark(glint, stroke: Palette.separator.opacity(0.35), lineWidth: g.line * 1.6),
            MascotMark(antenna, stroke: Palette.separator, lineWidth: g.line),
            MascotMark(g.circle(0.5, -0.28, radius: 0.02), fill: Palette.rating(.again), stroke: Palette.separator, lineWidth: g.line * 0.6),
            MascotMark(collar, fill: Palette.surfaceRaised, stroke: Palette.separator, lineWidth: g.line),
            MascotMark(g.circle(0.4, 0.885, radius: 0.025), fill: Palette.brandPrimary),
            MascotMark(g.circle(0.5, 0.885, radius: 0.025), fill: Palette.rating(.again)),
            MascotMark(g.circle(0.6, 0.885, radius: 0.025), fill: Palette.rating(.good)),
        ]
    }
}

// MARK: - Geometry

/// Body-unit helpers. See ``MascotAccessories`` for the coordinate convention.
private struct BodyUnits {
    let rect: CGRect

    init(_ rect: CGRect) {
        self.rect = rect
    }

    var width: CGFloat { rect.width }
    var height: CGFloat { rect.height }

    /// The house stroke for accessories, a little lighter than the body's own outline.
    var line: CGFloat { max(1.2, rect.width * 0.03) }

    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
    }

    func p(_ point: CGPoint) -> CGPoint {
        p(point.x, point.y)
    }

    /// `radius` in body widths, so the circle stays round on a body wider than it is tall.
    func circle(_ x: CGFloat, _ y: CGFloat, radius: CGFloat) -> Path {
        let centre = p(x, y)
        let r = radius * rect.width
        return Path(ellipseIn: CGRect(x: centre.x - r, y: centre.y - r, width: r * 2, height: r * 2))
    }

    /// `width` in body widths, `height` in body heights.
    func ellipse(_ x: CGFloat, _ y: CGFloat, width w: CGFloat, height h: CGFloat) -> Path {
        let centre = p(x, y)
        let pw = w * rect.width
        let ph = h * rect.height
        return Path(ellipseIn: CGRect(x: centre.x - pw / 2, y: centre.y - ph / 2, width: pw, height: ph))
    }

    func polygon(_ points: [(CGFloat, CGFloat)]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: p(first.0, first.1))
        for point in points.dropFirst() {
            path.addLine(to: p(point.0, point.1))
        }
        path.closeSubpath()
        return path
    }

    /// The same concave four-point twinkle Mochi wears after "Forgot". `arm` in body widths.
    func sparkle(_ x: CGFloat, _ y: CGFloat, arm: CGFloat) -> Path {
        let centre = p(x, y)
        let a = arm * rect.width
        var star = Path()
        star.move(to: CGPoint(x: centre.x, y: centre.y - a))
        star.addQuadCurve(to: CGPoint(x: centre.x + a, y: centre.y), control: centre)
        star.addQuadCurve(to: CGPoint(x: centre.x, y: centre.y + a), control: centre)
        star.addQuadCurve(to: CGPoint(x: centre.x - a, y: centre.y), control: centre)
        star.addQuadCurve(to: CGPoint(x: centre.x, y: centre.y - a), control: centre)
        star.closeSubpath()
        return star
    }

    /// A five-point star, radii in body widths.
    func star(_ x: CGFloat, _ y: CGFloat, outer: CGFloat, inner: CGFloat) -> Path {
        let centre = p(x, y)
        var path = Path()
        for index in 0..<10 {
            let angle = -Double.pi / 2 + Double(index) * Double.pi / 5
            let radius = (index.isMultiple(of: 2) ? outer : inner) * rect.width
            let point = CGPoint(x: centre.x + radius * CGFloat(cos(angle)), y: centre.y + radius * CGFloat(sin(angle)))
            if index == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        path.closeSubpath()
        return path
    }
}
