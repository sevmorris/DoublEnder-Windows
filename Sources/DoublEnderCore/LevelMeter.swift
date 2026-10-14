import Foundation

/// Level-meter parameters, shared by the engine's ballistics and the
/// faceplate's segment scale. Ported unchanged from the Mac build's
/// `LevelMeter`, so both read the same.
///
/// The meter answers one question: "Is audio coming in?" It reads the mono
/// mix the file records (`MonoMix`), with instant attack and a ~250 ms
/// release — tuned for a guest confirming their mic works, not for a
/// producer setting levels.
public enum LevelMeter {
    public static let dbFloor: Float = -36
    public static let dbCeiling: Float = 0
    public static let segmentCount = 40

    /// Peak-hold ballistics per ~15 ms block: instant rise, ~250 ms fall.
    public static let peakAttack: Float = 1.0
    public static let peakRelease: Float = 0.12
    /// The block the ballistics above were tuned for.
    public static let ballisticsBlockSeconds: Double = 0.015

    public static let scaleLabels: [(Float, String)] = [
        (dbFloor, "-36"), (-24, "-24"), (-12, "-12"),
        (-6, "-6"), (dbCeiling, "0"),
    ]

    public static func dbFS(fromLinear linear: Float) -> Float {
        linear > 1e-9 ? 20.0 * log10f(linear) : dbFloor
    }

    public static func clampedDisplayDB(fromLinear linear: Float) -> Float {
        max(dbFloor, min(dbCeiling, dbFS(fromLinear: linear)))
    }

    /// Peak linear level (max abs, not RMS).
    public static func peakLinear(in samples: UnsafeBufferPointer<Float>) -> Float {
        var peak: Float = 0
        for s in samples {
            let a = abs(s)
            if a > peak { peak = a }
        }
        return peak
    }
}
