import Foundation

/// The capture formats miniaudio delivers (`ma_format` values), all
/// interleaved, little-endian.
public enum SampleFormat: Int {
    case u8 = 1
    case s16 = 2
    case s24 = 3  // packed, 3 bytes
    case s32 = 4
    case f32 = 5

    public var bytesPerSample: Int {
        switch self {
        case .u8: return 1
        case .s16: return 2
        case .s24: return 3
        case .s32, .f32: return 4
        }
    }

    public var diagnosticName: String {
        switch self {
        case .u8: return "u8"
        case .s16: return "int16"
        case .s24: return "int24"
        case .s32: return "int32"
        case .f32: return "float32"
        }
    }
}

/// Mixes native capture frames to the mono stream every output is made
/// from: the 24-bit WAV, the Float32 crash-recovery sidecar (and so the
/// AAC encoded from it), and the level meter.
///
/// The weights are the ones the Mac build measured from AVAssetWriter's
/// downmix (THEORY_OF_OPERATION §3, "The mono mix"), applied to miniaudio's
/// channel positions, so a guest on Windows or Linux gets the file a Mac
/// guest with the same interface would. Like the Mac, a device that
/// duplicates one mic onto both channels of a stereo pair records 3 dB
/// hotter than either channel, and the meter shows it.
public enum MonoMix {

    /// Each channel of a left/right pair, or an unlabelled pair: 1/√2.
    public static let stereoPairGain: Float = 1 / Float(2).squareRoot()

    /// miniaudio channel positions (`ma_channel`).
    enum Position {
        static let none: UInt8 = 0
        static let mono: UInt8 = 1
        static let frontLeft: UInt8 = 2
        static let frontRight: UInt8 = 3
        static let frontCenter: UInt8 = 4
        static let backLeft: UInt8 = 6
        static let backRight: UInt8 = 7
        static let sideLeft: UInt8 = 11
        static let sideRight: UInt8 = 12
        static let aux0: UInt8 = 20
        static let aux31: UInt8 = 51
    }

    /// The gain for each channel of a source with this channel map.
    public static func gains(channelMap: [UInt8]) -> [Float] {
        let channels = channelMap.count
        guard channels > 1 else { return [1] }
        if channelMap.allSatisfy({ $0 == Position.none }) {
            return unlabelledGains(channels: channels)
        }
        var gains: [Float] = []
        for position in channelMap {
            switch position {
            case Position.mono, Position.frontCenter:
                gains.append(1)
            case Position.frontLeft, Position.frontRight:
                gains.append(stereoPairGain)
            case Position.sideLeft, Position.sideRight, Position.backLeft, Position.backRight:
                gains.append(0.5)
            case Position.aux0:
                gains.append(1)
            case (Position.aux0 + 1)...Position.aux31:
                // Discrete channels map to outputs by number: only the first
                // reaches a one-channel file.
                gains.append(0)
            case Position.none:
                gains.append(0)
            default:
                // A position the Mac never measured: average, as its
                // fallback does for interleaved input.
                return unlabelledGains(channels: channels)
            }
        }
        return gains
    }

    static func unlabelledGains(channels: Int) -> [Float] {
        channels == 2
            ? [stereoPairGain, stereoPairGain]
            : [Float](repeating: 1 / Float(channels), count: channels)
    }

    /// Mixes interleaved frames in `raw` into `out`, which must hold at
    /// least `raw.count / (channels * bytesPerSample)` floats. Returns the
    /// frame count.
    @discardableResult
    public static func mix(
        _ raw: UnsafeRawBufferPointer, format: SampleFormat, channels: Int,
        gains: [Float], into out: UnsafeMutablePointer<Float>
    ) -> Int {
        let bps = format.bytesPerSample
        let frameBytes = bps * channels
        guard frameBytes > 0, let base = raw.baseAddress else { return 0 }
        let frames = raw.count / frameBytes
        for frame in 0..<frames {
            let frameStart = base + frame * frameBytes
            var sum: Float = 0
            for channel in 0..<channels {
                let gain = gains[channel]
                if gain == 0 { continue }
                sum += gain * decode(frameStart + channel * bps, format)
            }
            out[frame] = sum
        }
        return frames
    }

    /// One sample as a Float, full scale ±1.
    @inline(__always)
    static func decode(_ p: UnsafeRawPointer, _ format: SampleFormat) -> Float {
        switch format {
        case .f32:
            return p.loadUnaligned(as: Float.self)
        case .s16:
            return Float(Int16(littleEndian: p.loadUnaligned(as: Int16.self))) / 32768.0
        case .s24:
            let b0 = Int32(p.load(fromByteOffset: 0, as: UInt8.self))
            let b1 = Int32(p.load(fromByteOffset: 1, as: UInt8.self))
            let b2 = Int32(p.load(fromByteOffset: 2, as: UInt8.self))
            var raw = (b2 << 16) | (b1 << 8) | b0
            if raw & 0x800000 != 0 { raw |= Int32(bitPattern: 0xFF00_0000) }
            return Float(raw) / 8_388_608.0
        case .s32:
            return Float(Int32(littleEndian: p.loadUnaligned(as: Int32.self))) / 2_147_483_648.0
        case .u8:
            return (Float(p.load(as: UInt8.self)) - 128) / 128.0
        }
    }
}
