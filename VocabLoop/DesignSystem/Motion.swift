import SwiftUI

/// The app's motion vocabulary.
///
/// Colour has ``Palette``, type has ``Typography``, space has ``Spacing``, corners have
/// ``Radius``, depth has ``Elevation``. Motion had nothing — nine animations across seven files,
/// six different durations and four different curves, every one of them a literal at the call
/// site. Two transitions of the same kind ran at 0.2 and 0.25 for no reason anybody could state.
///
/// That mattered more than the usual consistency argument, because motion is the axis a playful
/// interface is mostly *made of*. Without a vocabulary, "make it livelier" turns into a hundred
/// independent guesses.
///
/// **Every token takes `reduceMotion`.** Five of the seven original animation sites ignored the
/// accessibility setting entirely — not from carelessness but because honouring it meant writing
/// a ternary by hand each time, and the shortest path won. Making the parameter mandatory puts
/// the accessible version on the shortest path instead.
public enum Motion {

    // MARK: Durations
    //
    // Named for the job, not the number. A duration named `fast` invites the question "faster
    // than what?"; one named `press` says where it belongs.

    /// A state flip the finger is already waiting on. Long enough to be seen, short enough that
    /// it never delays the result.
    public static let pressDuration: TimeInterval = 0.22

    /// The floor. Used when Reduce Motion is on and something still has to change visibly —
    /// an instant cut reads as a glitch, so this is a cross-fade rather than no animation.
    public static let minimalDuration: TimeInterval = 0.08

    /// One thing becoming another: an answer revealing, a card arriving, a screen changing.
    public static let transitionDuration: TimeInterval = 0.3

    /// Motion meant to be *watched* rather than merely noticed — a progress ring filling, a
    /// streak advancing, a session completing.
    public static let expressiveDuration: TimeInterval = 0.6

    // MARK: Curves

    /// Press feedback. A small bounce, because a control that springs back reads as physical;
    /// a large one reads as a toy and gets tiring by the fiftieth card.
    public static func press(_ reduceMotion: Bool) -> Animation {
        reduceMotion
            ? .linear(duration: minimalDuration)
            : .spring(duration: pressDuration, bounce: 0.1)
    }

    /// A value changing in place: a count, a bar, a label.
    public static func value(_ reduceMotion: Bool) -> Animation {
        reduceMotion
            ? .linear(duration: minimalDuration)
            : .easeOut(duration: pressDuration)
    }

    /// One view replacing another, or an answer being revealed.
    ///
    /// `easeOut` rather than `easeInOut`: the user caused this, so it should start at full speed
    /// and settle, not accelerate from nothing. Easing in makes an app feel like it is thinking.
    public static func reveal(_ reduceMotion: Bool) -> Animation {
        reduceMotion
            ? .easeInOut(duration: 0.2)
            : .easeOut(duration: transitionDuration)
    }

    /// A screen-level phase change — onboarding steps, the root switching between launch, auth
    /// and the app.
    public static func phase(_ reduceMotion: Bool) -> Animation {
        reduceMotion
            ? .linear(duration: minimalDuration)
            : .easeInOut(duration: 0.25)
    }

    /// Progress that deserves attention: the goal ring, a streak extending.
    ///
    /// The one place a visible bounce is earned — this is the app telling the user they got
    /// somewhere, and a ring that snaps into place says nothing.
    public static func progress(_ reduceMotion: Bool) -> Animation {
        reduceMotion
            ? .easeOut(duration: pressDuration)
            : .spring(duration: expressiveDuration, bounce: 0.18)
    }

    /// A squashy press-and-release: the Q-style button and the mascot's reaction.
    ///
    /// Half-bounce, which is a lot — deliberately more than ``press(_:)``. It is kept off the
    /// generic press style for the reason given there: a control pressed hundreds of times a day
    /// should not wobble. The rating bar is the exception that proves it, because its bounce
    /// happens *after* the answer is committed; it acknowledges rather than delays.
    public static func squish(_ reduceMotion: Bool) -> Animation {
        reduceMotion
            ? .linear(duration: minimalDuration)
            : .spring(duration: 0.28, bounce: 0.5)
    }

    /// A new card arriving. Springy enough to read as popping onto the table, short enough that
    /// the next answer is never waiting on it.
    public static func pop(_ reduceMotion: Bool) -> Animation {
        reduceMotion
            ? .easeInOut(duration: 0.2)
            : .spring(duration: 0.42, bounce: 0.32)
    }

    /// A celebration. Deliberately separate from ``progress(_:)`` so that turning celebrations
    /// down later does not also flatten ordinary progress.
    ///
    /// Under Reduce Motion this becomes a plain fade of the same length: the *moment* survives,
    /// the movement does not. Removing the animation entirely would remove the acknowledgement,
    /// which is the opposite of what the setting asks for.
    public static func celebrate(_ reduceMotion: Bool) -> Animation {
        reduceMotion
            ? .easeInOut(duration: expressiveDuration)
            : .spring(duration: expressiveDuration, bounce: 0.32)
    }
}
