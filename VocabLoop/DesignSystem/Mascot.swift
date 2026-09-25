import SwiftUI

/// Mochi — a small round companion who reacts to how the session is going.
///
/// A face is the fastest route to "Q": roundness and colour make an interface friendly, but a
/// character makes it *cute*, and it is the one thing none of the six directions had. Drawn
/// entirely from shapes — a ``WobbleShape`` body and a `Canvas` face — so there is no image
/// asset to ship at three scales, it inherits the palette in both appearances (a paper mochi
/// in light, a chalk-outlined one on the board), and it scales with whatever frame it is given.
///
/// **It never looks disappointed.** The mood after "Forgot" is ``Mood/encourage`` — a small
/// smile and a sparkle — not sadness. The same rule already keeps `Haptics.error()` off the
/// rating bar: a companion that frowns at you for an honest answer teaches you to stop giving
/// honest answers, and dishonest grades are the one input that ruins the scheduler.
///
/// Purely decorative: hidden from VoiceOver, never hit-tested, and under Reduce Motion it
/// neither breathes nor bounces.
public struct Mascot: View {
    public enum Mood: Equatable {
        /// Waiting for an answer. Round eyes, a small "o".
        case curious
        case happy
        /// Eyes squeezed into arches, mouth open. For "Instant" and for finishing.
        case cheer
        /// After "Forgot". Deliberately positive — see the type's documentation.
        case encourage
        /// Nothing to study.
        case sleepy
    }

    private let mood: Mood

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false
    @State private var pop: CGFloat = 1

    public init(mood: Mood) {
        self.mood = mood
    }

    public var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let shape = WobbleShape(cornerRadius: side / 2, amplitude: 0.7, seed: 0x0C41_0000_0000_0001)
            ZStack {
                shape.fill(Chunky.baseColor).offset(y: max(2, side * 0.06))
                shape.fill(Palette.surface)
                    .overlay(shape.stroke(Palette.separator, lineWidth: max(2, side * 0.05)))
                Canvas { context, size in
                    Self.drawFace(mood, in: &context, size: size)
                }
            }
        }
        // Wider than tall: a mochi sits, it is not a ball.
        .aspectRatio(1.2, contentMode: .fit)
        .scaleEffect(x: 1, y: breathing ? 1.035 : 1, anchor: .bottom)
        .scaleEffect(pop, anchor: .bottom)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                breathing = true
            }
        }
        .onChange(of: mood) { _, _ in
            // A hop on every change of mood, so a reaction is noticed without being read.
            // Two plain animations rather than `keyframeAnimator`: the effect is simple, and
            // this file cannot be compiled here to confirm the keyframe builder's overloads.
            guard !reduceMotion else { return }
            withAnimation(.spring(duration: 0.14)) { pop = 1.14 }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(140))
                withAnimation(Motion.squish(false)) { pop = 1 }
            }
        }
    }

    // MARK: - Face

    /// Everything is proportional to the canvas, so the face survives any frame size.
    private static func drawFace(_ mood: Mood, in context: inout GraphicsContext, size: CGSize) {
        let width = size.width
        let height = size.height
        let centreX = width / 2
        let eyeY = height * 0.45
        let eyeOffset = width * 0.17
        let eyeRadius = width * 0.052
        let mouthY = height * 0.6
        let ink = GraphicsContext.Shading.color(Palette.textPrimary)
        let line = StrokeStyle(lineWidth: max(1.6, width * 0.04), lineCap: .round, lineJoin: .round)

        // Blush first, so the eyes draw over it.
        for side in [-1.0, 1.0] {
            let x = centreX + CGFloat(side) * width * 0.29
            context.fill(
                Path(ellipseIn: CGRect(x: x - width * 0.075, y: eyeY + height * 0.07,
                                       width: width * 0.15, height: height * 0.085)),
                with: .color(Palette.rating(.again).opacity(0.45))
            )
        }

        // Eyes.
        for side in [-1.0, 1.0] {
            let x = centreX + CGFloat(side) * eyeOffset
            switch mood {
            case .cheer:
                // ^ ^ — squeezed shut with joy.
                var arch = Path()
                arch.move(to: CGPoint(x: x - eyeRadius * 1.3, y: eyeY + eyeRadius * 0.6))
                arch.addQuadCurve(to: CGPoint(x: x + eyeRadius * 1.3, y: eyeY + eyeRadius * 0.6),
                                  control: CGPoint(x: x, y: eyeY - eyeRadius * 1.5))
                context.stroke(arch, with: ink, style: line)
            case .sleepy:
                var lid = Path()
                lid.move(to: CGPoint(x: x - eyeRadius * 1.2, y: eyeY))
                lid.addQuadCurve(to: CGPoint(x: x + eyeRadius * 1.2, y: eyeY),
                                 control: CGPoint(x: x, y: eyeY + eyeRadius * 0.9))
                context.stroke(lid, with: ink, style: line)
            case .curious, .happy, .encourage:
                let radius = mood == .curious ? eyeRadius * 1.15 : eyeRadius
                context.fill(
                    Path(ellipseIn: CGRect(x: x - radius, y: eyeY - radius,
                                           width: radius * 2, height: radius * 2)),
                    with: ink
                )
                // A catch-light. Tiny, and the difference between a dot and an eye.
                let glint = radius * 0.38
                context.fill(
                    Path(ellipseIn: CGRect(x: x - radius * 0.1, y: eyeY - radius * 0.7,
                                           width: glint, height: glint)),
                    with: .color(Palette.surface)
                )
            }
        }

        // Mouth.
        switch mood {
        case .happy, .encourage:
            var smile = Path()
            smile.move(to: CGPoint(x: centreX - width * 0.07, y: mouthY))
            smile.addQuadCurve(to: CGPoint(x: centreX + width * 0.07, y: mouthY),
                               control: CGPoint(x: centreX, y: mouthY + height * 0.09))
            context.stroke(smile, with: ink, style: line)
        case .cheer:
            var open = Path()
            open.move(to: CGPoint(x: centreX - width * 0.09, y: mouthY - height * 0.01))
            open.addQuadCurve(to: CGPoint(x: centreX + width * 0.09, y: mouthY - height * 0.01),
                              control: CGPoint(x: centreX, y: mouthY + height * 0.2))
            open.closeSubpath()
            context.fill(open, with: ink)
        case .curious:
            let radius = width * 0.034
            context.stroke(
                Path(ellipseIn: CGRect(x: centreX - radius, y: mouthY - radius,
                                       width: radius * 2, height: radius * 2.2)),
                with: ink, style: line
            )
        case .sleepy:
            var flat = Path()
            flat.move(to: CGPoint(x: centreX - width * 0.04, y: mouthY + height * 0.01))
            flat.addLine(to: CGPoint(x: centreX + width * 0.04, y: mouthY + height * 0.01))
            context.stroke(flat, with: ink, style: line)
            // A "z", drawn as three strokes rather than as text so no fixed-size font creeps in.
            // Inside the body's top-right, not on its outline, where it read as a scribble.
            let z = width * 0.09
            let origin = CGPoint(x: width * 0.7, y: height * 0.14)
            var letter = Path()
            letter.move(to: origin)
            letter.addLine(to: CGPoint(x: origin.x + z, y: origin.y))
            letter.addLine(to: CGPoint(x: origin.x, y: origin.y + z))
            letter.addLine(to: CGPoint(x: origin.x + z, y: origin.y + z))
            context.stroke(letter, with: .color(Palette.textSecondary), style: line)
        }

        // "You'll get it": a twinkle rather than a frown, after Forgot.
        //
        // A filled four-point star with concave sides, not two crossed strokes — the crossed
        // version read as a plus sign, which on a face means "first aid", not "sparkle".
        if mood == .encourage {
            let centre = CGPoint(x: width * 0.8, y: height * 0.2)
            let arm = width * 0.09
            var star = Path()
            star.move(to: CGPoint(x: centre.x, y: centre.y - arm))
            star.addQuadCurve(to: CGPoint(x: centre.x + arm, y: centre.y), control: centre)
            star.addQuadCurve(to: CGPoint(x: centre.x, y: centre.y + arm), control: centre)
            star.addQuadCurve(to: CGPoint(x: centre.x - arm, y: centre.y), control: centre)
            star.addQuadCurve(to: CGPoint(x: centre.x, y: centre.y - arm), control: centre)
            star.closeSubpath()
            context.fill(star, with: .color(Palette.brandSecondary))
        }
    }
}
