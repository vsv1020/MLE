import SwiftUI

/// The app's one celebration.
///
/// Written because the audit found something worse than a dull palette: across the whole app there
/// was no `Canvas`, no `TimelineView`, no `symbolEffect`, no `contentTransition`, and no gradient of
/// any kind. ``Motion/celebrate(_:)`` — a spring written specifically for this, with a documented
/// Reduce Motion fallback already attached — had zero call sites. Finishing twenty cards changed the
/// screen to a static grey checkmark. That is what "too dry" was describing, and no amount of
/// retinting fixes it.
///
/// Kept in the design system rather than inside the summary screen so the daily goal and the streak
/// can reuse it later without a second implementation drifting from this one.
public struct SummaryBurst: View {
    /// Whether the timeline is still asking for frames. Set false when the last particle dies, so a
    /// finished celebration stops waking the display link — a `TimelineView(.animation)` left
    /// running is a permanent 60fps tax on a screen the user is only reading.
    @State private var isRunning = true
    @State private var start: Date?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let particles: [Particle]

    /// - Parameter seed: Fixed by default so `#Preview` and any snapshot are stable. Randomness that
    ///   changes every render makes a visual regression impossible to review.
    public init(count: Int = 28, seed: UInt64 = 0x5EED_C0FF_EE15_600D) {
        var generator = SeededGenerator(seed: seed)
        particles = (0..<count).map { _ in Particle(using: &generator) }
    }

    public var body: some View {
        // Nothing at all under Reduce Motion.
        //
        // Not a single static frame: that would leave confetti frozen on screen permanently, for
        // exactly the users who asked for less movement. `Motion.celebrate` already degrades to a
        // fade of the same duration, and on this screen that fade *is* the acknowledgement.
        if reduceMotion {
            Color.clear
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !isRunning)) { timeline in
                Canvas { context, size in
                    let elapsed = start.map { timeline.date.timeIntervalSince($0) } ?? 0
                    draw(in: &context, size: size, elapsed: elapsed)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .task {
                start = .now
                // One sleep rather than a per-frame check: the lifetime is known up front.
                try? await Task.sleep(for: .seconds(Particle.lifetime + 0.2))
                isRunning = false
            }
        }
    }

    /// One `Canvas`, not one view per particle.
    ///
    /// Twenty-eight `Circle()`s in a `ZStack` would each get their own layer, layout pass and
    /// animation; a single canvas draws them in one pass with no view identity at all.
    private func draw(in context: inout GraphicsContext, size: CGSize, elapsed: TimeInterval) {
        guard elapsed > 0 else { return }
        let origin = CGPoint(x: size.width / 2, y: size.height / 2)

        for particle in particles {
            let t = elapsed - particle.delay
            guard t > 0, t < Particle.lifetime else { continue }

            // Plain projectile motion. Anything more elaborate is invisible at this scale and this
            // duration, and costs a frame budget the celebration does not have to spend.
            let x = origin.x + particle.vx * t
            let y = origin.y + particle.vy * t + 0.5 * Particle.gravity * t * t

            // Fade only at the end, so the burst reads as solid at its peak rather than as a haze.
            let remaining = 1 - (t / Particle.lifetime)
            let opacity = min(1, remaining * 3)

            var layer = context
            layer.opacity = opacity
            layer.translateBy(x: x, y: y)
            layer.rotate(by: .radians(particle.spin * t))
            layer.fill(
                Path(
                    roundedRect: CGRect(
                        x: -particle.size.width / 2, y: -particle.size.height / 2,
                        width: particle.size.width, height: particle.size.height
                    ),
                    cornerRadius: 2
                ),
                with: .color(particle.color)
            )
        }
    }

    private struct Particle {
        static let lifetime: TimeInterval = 1.4
        /// Points per second squared. Roughly earth-like at this scale, which is what makes the
        /// arcs read as confetti rather than as sparks.
        static let gravity: Double = 980

        /// Never ``Palette/rating(_:)``.
        ///
        /// The rating hues are a semantic scale — red means "I did not remember this". A red
        /// confetto in a celebration reads as an error the moment it lands next to the word
        /// "complete", which is the opposite of the whole set piece.
        static let palette: [Color] = [
            Palette.brandPrimary, Palette.brandSecondary,
            Palette.success, Palette.warning, Palette.maturity(.young),
        ]

        /// Plain `Double`s rather than `CGVector`. That type does exist in CoreGraphics but is
        /// almost never used, and this file cannot be compiled here to find out — a two-field
        /// struct is not worth a build cycle to confirm.
        let vx: Double
        let vy: Double
        let size: CGSize
        let spin: Double
        let delay: TimeInterval
        let color: Color

        init(using generator: inout SeededGenerator) {
            // Called directly rather than through a nested helper: a nested function capturing an
            // `inout` parameter runs into Swift's escaping rules, and the repetition is cheaper
            // than the risk.
            //
            // Upward and outward. `vy` is negative because the canvas y axis points down.
            vx = Double.random(in: -210...210, using: &generator)
            vy = Double.random(in: (-1080)...(-820), using: &generator)
            let width = Double.random(in: 5...9, using: &generator)
            let ratio = Double.random(in: 0.45...0.75, using: &generator)
            size = CGSize(width: width, height: width * ratio)
            spin = Double.random(in: -5.2...5.2, using: &generator)
            delay = Double.random(in: 0...0.12, using: &generator)
            color = Self.palette[Int.random(in: 0..<Self.palette.count, using: &generator)]
        }
    }
}

/// A number that counts up to its value the first time it appears.
///
/// `.contentTransition(.numericText())` animates *between* values, so a view that is born holding
/// its final number animates nothing. The baseline has to start elsewhere and change once.
public struct CountingNumber: View {
    private let value: Int
    private let format: (Int) -> String

    @State private var shown = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(_ value: Int, format: @escaping (Int) -> String = { "\($0)" }) {
        self.value = value
        self.format = format
    }

    public var body: some View {
        Text(format(shown))
            .contentTransition(.numericText(value: Double(shown)))
            // VoiceOver reads the final value immediately. Counting is decoration; the number is
            // the information, and nobody should have to wait 400ms to hear it.
            .accessibilityLabel(format(value))
            // `.task(id:)`, not `.task`.
            //
            // A plain `.task` runs once per view identity, which is right for the summary screen —
            // the number is final when it appears — and wrong for the session top bar, where
            // `reviewedCount` climbs card by card behind a stable identity. There the counter would
            // have latched onto whatever it was at first appearance (0) and never moved again: a
            // progress readout stuck on zero for the entire session. Keying on the value re-runs
            // the animation on every change and still animates the first one from the 0 baseline.
            .task(id: value) {
                guard !reduceMotion else {
                    shown = value
                    return
                }
                withAnimation(Motion.value(false)) { shown = value }
            }
    }
}
