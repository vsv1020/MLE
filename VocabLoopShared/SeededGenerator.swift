import Foundation

/// Deterministic pseudo-random generator, for reproducible shuffles.
///
/// SplitMix64: tiny, no state to persist, well-distributed, and — critically — gives
/// the same sequence for the same seed on every platform and every launch.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        // A zero seed makes SplitMix64 degenerate, so it is nudged off zero.
        self.state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
