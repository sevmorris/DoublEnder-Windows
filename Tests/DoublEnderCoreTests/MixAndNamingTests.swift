import XCTest
@testable import DoublEnderCore

final class MixAndNamingTests: XCTestCase {

    // MARK: - Mono mix (the Mac's measured AVAssetWriter weights)

    func testChannelMapGains() {
        let pair = MonoMix.stereoPairGain
        XCTAssertEqual(MonoMix.gains(channelMap: [1]), [1])
        XCTAssertEqual(MonoMix.gains(channelMap: [2, 3]), [pair, pair])          // FL FR
        XCTAssertEqual(MonoMix.gains(channelMap: [0, 0]), [pair, pair])          // unlabelled pair
        XCTAssertEqual(MonoMix.gains(channelMap: [2, 3, 6, 7]), [pair, pair, 0.5, 0.5])  // quad
        XCTAssertEqual(MonoMix.gains(channelMap: [20, 21, 22]), [1, 0, 0])       // discrete
        XCTAssertEqual(MonoMix.gains(channelMap: [0, 0, 0, 0]), [0.25, 0.25, 0.25, 0.25])
    }

    func testMixDecodesEachFormat() {
        func mix(_ bytes: [UInt8], _ format: SampleFormat, channels: Int = 1, gains: [Float] = [1]) -> [Float] {
            var out = [Float](repeating: .nan, count: 8)
            let n = bytes.withUnsafeBytes { raw in
                out.withUnsafeMutableBufferPointer {
                    MonoMix.mix(raw, format: format, channels: channels, gains: gains, into: $0.baseAddress!)
                }
            }
            return Array(out.prefix(n))
        }
        XCTAssertEqual(mix([0x00, 0x40], .s16), [0.5])
        XCTAssertEqual(mix([0x00, 0x00, 0xC0], .s24), [-0.5])
        XCTAssertEqual(mix([0x00, 0x00, 0x00, 0x40], .s32), [0.5])
        XCTAssertEqual(mix([0xC0], .u8), [0.5])
        var half = Float(0.5).bitPattern.littleEndian
        let f32 = withUnsafeBytes(of: &half) { Array($0) }
        XCTAssertEqual(mix(f32 + f32, .f32, channels: 2, gains: [1, 1]), [1.0])
        // A mic duplicated on both sides of a pair lands 3 dB hotter, as on the Mac.
        let pair = MonoMix.stereoPairGain
        XCTAssertEqual(mix(f32 + f32, .f32, channels: 2, gains: [pair, pair])[0], 0.5 * 2 * pair, accuracy: 1e-6)
    }

    // MARK: - Names and places

    func testPrefixSanitizing() {
        XCTAssertEqual(RecordingFiles.sanitizedPrefix("  Ada: Ep 3?  "), "Ada_ Ep 3_")
        XCTAssertEqual(RecordingFiles.sanitizedPrefix("..hidden"), "hidden")
        XCTAssertEqual(RecordingFiles.sanitizedPrefix("a//b"), "a_b")
        XCTAssertEqual(RecordingFiles.sanitizedPrefix("trailing. "), "trailing")
        XCTAssertEqual(RecordingFiles.sanitizedPrefix(String(repeating: "x", count: 80)).count, 64)
    }

    func testRecordingNamesAreTimestampedAndUnique() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let date = Date(timeIntervalSince1970: 1_800_000_000.25)
        let first = RecordingFiles.makeRecordingURL(in: dir, prefix: "", format: .wav, date: date)
        XCTAssertTrue(first.lastPathComponent.hasPrefix("DoublEnder_"))
        XCTAssertTrue(first.lastPathComponent.hasSuffix("-250.wav"))
        // An AAC take holds only its sidecar while recording; that still counts.
        try Data().write(to: PCMSidecar.url(for: first))
        let second = RecordingFiles.makeRecordingURL(in: dir, prefix: "", format: .wav, date: date)
        XCTAssertTrue(second.lastPathComponent.hasSuffix("-250_2.wav"))
        let named = RecordingFiles.makeRecordingURL(in: dir, prefix: "Ada", format: .aac, date: date)
        XCTAssertTrue(named.lastPathComponent.hasPrefix("Ada_"))
        XCTAssertEqual(named.pathExtension, "m4a")
    }

    #if !os(Windows)
    func testXDGUserDirsParsing() {
        let text = """
            # comment
            XDG_DESKTOP_DIR="$HOME/Schreibtisch"
            XDG_MUSIC_DIR="$HOME/"
            """
        XCTAssertEqual(Platform.parseXDGUserDirs(text, key: "XDG_DESKTOP_DIR", home: "/home/ada")?.path,
                       "/home/ada/Schreibtisch")
        XCTAssertNil(Platform.parseXDGUserDirs(text, key: "XDG_MUSIC_DIR", home: "/home/ada"))
        XCTAssertNil(Platform.parseXDGUserDirs(text, key: "XDG_VIDEOS_DIR", home: "/home/ada"))
    }
    #endif

    func testVersionFormatting() {
        XCTAssertEqual(VersionFormatting.numericVersion("2.6.0x"), "2.6.0")
        XCTAssertEqual(VersionFormatting.numericVersion("v1.0.0-beta.2"), "1.0.0")
        XCTAssertTrue(VersionFormatting.splitSuffix("2.6.0lr") == ("2.6.0", "lr"))
        XCTAssertEqual(Double(3725).hhmmss, "01:02:05")
    }

    // MARK: - What the user is told

    func testStopFailureMessages() throws {
        XCTAssertEqual(
            RecorderController.stopFailureMessage(
                for: RecordingError.noActiveRecording, mainOutput: nil,
                disconnectReason: "The microphone delivered no audio"),
            "The microphone delivered no audio. No audio was captured — try again with a different microphone.")
        XCTAssertTrue(RecorderController.stopFailureMessage(
            for: RecordingError.encoderMissing, mainOutput: nil, disconnectReason: nil)
            .hasPrefix("Failed to finalize recording:"))
    }

    func testDialogQueueRunsTheButtonAndAdvances() {
        let queue = DialogQueue()
        var pressed = ""
        queue.present(Dialog(icon: .warning, title: "One", message: "", buttons: [.init("A") { pressed = "A" }]))
        queue.present(Dialog(icon: .warning, title: "Two", message: "", buttons: [.init("B")]))
        let one = queue.current!
        queue.press(one.buttons[0], in: one)
        XCTAssertEqual(pressed, "A")
        XCTAssertEqual(queue.current?.title, "Two")
    }
}
