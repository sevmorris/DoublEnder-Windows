import XCTest
@testable import DoublEnderCore

/// The on-disk formats: the DEP2 sidecar (shared with the Mac build), the
/// 24-bit WAV, and the "is this take finished" checks crash recovery uses.
final class RecordingFormatTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DoublEnderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func samples(_ values: [Float]) -> UnsafeBufferPointer<Float> {
        let buffer = UnsafeMutableBufferPointer<Float>.allocate(capacity: values.count)
        _ = buffer.initialize(from: values)
        return UnsafeBufferPointer(buffer)
    }

    // MARK: - Sidecar

    func testSidecarHeaderMatchesTheMacFormat() throws {
        let main = dir.appendingPathComponent("Take.m4a")
        let sidecar = try PCMSidecar(mainOutput: main, sampleRate: 48_000)
        sidecar.close()
        let bytes = [UInt8](try Data(contentsOf: PCMSidecar.url(for: main)))
        XCTAssertEqual(bytes.count, 20)
        XCTAssertEqual(Array(bytes[0..<4]), Array("DEP2".utf8))
        XCTAssertEqual(Double(bitPattern: bytes.loadLE(UInt64.self, at: 4)), 48_000)
        XCTAssertEqual(bytes.loadLE(UInt32.self, at: 12), 1)  // channels
        XCTAssertEqual(bytes.loadLE(UInt32.self, at: 16), 1)  // Float32 payload
        XCTAssertFalse(PCMSidecar.hasRecoverableContent(at: PCMSidecar.url(for: main)))
    }

    func testSidecarRecoversToFloatWAV() throws {
        let main = dir.appendingPathComponent("Take.wav")
        let sidecar = try PCMSidecar(mainOutput: main, sampleRate: 44_100)
        try sidecar.append(samples([0.5, -0.25, 1.0]))
        sidecar.close()
        XCTAssertTrue(PCMSidecar.hasRecoverableContent(at: sidecar.url))

        let recovered = try PCMSidecar.recoverToWAV(sidecarURL: sidecar.url)
        XCTAssertEqual(recovered.lastPathComponent, "Take (recovered).wav")
        let bytes = [UInt8](try Data(contentsOf: recovered))
        XCTAssertEqual(bytes.count, 44 + 12)
        XCTAssertEqual(bytes.loadLE(UInt16.self, at: 20), 3)  // IEEE float
        XCTAssertEqual(bytes.loadLE(UInt32.self, at: 24), 44_100)
        XCTAssertEqual(bytes.loadLE(UInt32.self, at: 40), 12)
        XCTAssertEqual(Float(bitPattern: bytes.loadLE(UInt32.self, at: 48)), -0.25)
        XCTAssertTrue(WAVFile.isFinished(recovered))

        // A second recovery doesn't overwrite the first.
        let again = try PCMSidecar.recoverToWAV(sidecarURL: sidecar.url)
        XCTAssertEqual(again.lastPathComponent, "Take (recovered 2).wav")
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: dir.path).contains { $0.hasSuffix(".part") },
                       "the temporary name is gone once the WAV is complete")
    }

    #if !os(Windows)  // relies on a sparse file
    func testSidecarPastTheWAVLimitSaysSo() throws {
        let main = dir.appendingPathComponent("Long.m4a")
        let sidecar = try PCMSidecar(mainOutput: main, sampleRate: 48_000)
        sidecar.close()
        let handle = try FileHandle(forWritingTo: sidecar.url)
        try handle.truncate(atOffset: UInt64(UInt32.max) + 1024)
        try handle.close()
        XCTAssertThrowsError(try PCMSidecar.recoverToWAV(sidecarURL: sidecar.url)) { error in
            guard case .tooLongForWAV? = error as? PCMSidecar.RecoveryError else {
                return XCTFail("expected tooLongForWAV, got \(error)")
            }
        }
    }
    #endif

    func testTornFinalSampleIsDroppedOnRecovery() throws {
        let main = dir.appendingPathComponent("Take.m4a")
        let sidecar = try PCMSidecar(mainOutput: main, sampleRate: 48_000)
        try sidecar.append(samples([0.1, 0.2]))
        sidecar.close()
        let handle = try FileHandle(forWritingTo: sidecar.url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0xAB, 0xCD]))  // half a sample, as a power cut might leave
        try handle.close()
        let recovered = try PCMSidecar.recoverToWAV(sidecarURL: sidecar.url)
        XCTAssertEqual([UInt8](try Data(contentsOf: recovered)).loadLE(UInt32.self, at: 40), 8)
    }

    func testCorruptSidecarHeaderIsRejected() throws {
        let url = dir.appendingPathComponent("Bad.m4a.pcmrec")
        var data = Data("DEP2".utf8)
        data.appendLE(Double.nan.bitPattern)
        data.appendLE(UInt32(1)); data.appendLE(UInt32(1))
        data.append(Data(count: 64))
        try data.write(to: url)
        XCTAssertThrowsError(try PCMSidecar.recoverToWAV(sidecarURL: url))
    }

    // MARK: - WAV writer

    func testWAVWriterIsUnfinishedUntilFinalized() throws {
        let url = dir.appendingPathComponent("Take.wav")
        let writer = try WAVWriter(url: url, sampleRate: 48_000)
        try writer.append(samples([0, 0.5, -1, 1]))
        XCTAssertFalse(WAVFile.isFinished(url), "a crashed WAV must read as empty")
        try writer.finalize()
        XCTAssertTrue(WAVFile.isFinished(url))

        let bytes = [UInt8](try Data(contentsOf: url))
        XCTAssertEqual(bytes.count, 44 + 4 * 3)
        XCTAssertEqual(bytes.loadLE(UInt16.self, at: 34), 24)
        XCTAssertEqual(bytes.loadLE(UInt32.self, at: 40), 12)
        func sample(_ i: Int) -> Int32 {
            let b = bytes[44 + i * 3..<44 + i * 3 + 3].map(Int32.init)
            let raw = b[0] | b[1] << 8 | b[2] << 16
            return raw & 0x800000 != 0 ? raw | Int32(bitPattern: 0xFF00_0000) : raw
        }
        XCTAssertEqual(sample(1), 4_194_304)
        XCTAssertEqual(sample(2), -8_388_608)
        XCTAssertEqual(sample(3), 8_388_607, "full scale clips one step under 2^23")
    }

    func testMP4CheckNeedsMoov() throws {
        let url = dir.appendingPathComponent("Take.m4a")
        func box(_ type: String, _ payload: Int) -> Data {
            var d = Data()
            withUnsafeBytes(of: UInt32(8 + payload).bigEndian) { d.append(contentsOf: $0) }
            d.append(contentsOf: Array(type.utf8))
            d.append(Data(count: payload))
            return d
        }
        try (box("ftyp", 16) + box("mdat", 100)).write(to: url)
        XCTAssertFalse(MP4File.isFinished(url), "no moov: the writer never closed it")
        try (box("ftyp", 16) + box("mdat", 100) + box("moov", 40)).write(to: url)
        XCTAssertTrue(MP4File.isFinished(url))
    }

    /// Crash recovery reads an M4A beside every sidecar at launch; a corrupt
    /// one must read as unfinished, not crash the app on every launch.
    func testMP4CheckSurvivesCorruptBoxSizes() throws {
        let url = dir.appendingPathComponent("Corrupt.m4a")
        var huge = Data()
        withUnsafeBytes(of: UInt32(1).bigEndian) { huge.append(contentsOf: $0) }  // 64-bit size follows
        huge.append(contentsOf: Array("ftyp".utf8))
        withUnsafeBytes(of: UInt64.max.bigEndian) { huge.append(contentsOf: $0) }
        huge.append(Data(count: 32))
        try huge.write(to: url)
        XCTAssertFalse(MP4File.isFinished(url))

        var truncated = Data()
        withUnsafeBytes(of: UInt32(8 + 16).bigEndian) { truncated.append(contentsOf: $0) }
        truncated.append(contentsOf: Array("moov".utf8))
        truncated.append(Data(count: 16))
        withUnsafeBytes(of: UInt32(8 + 1000).bigEndian) { truncated.append(contentsOf: $0) }
        truncated.append(contentsOf: Array("mdat".utf8))
        truncated.append(Data(count: 100))  // 900 bytes short
        try truncated.write(to: url)
        XCTAssertFalse(MP4File.isFinished(url), "a truncated file isn't finished")
    }

    // MARK: - Takes

    func testWAVTakeSavesAndRemovesItsSidecar() throws {
        let url = dir.appendingPathComponent("Take.wav")
        let take = try TakeWriter(mainURL: url, format: .wav, notes: "", sampleRate: 48_000)
        try take.write(samples([Float](repeating: 0.1, count: 480)))
        guard case .saved(let saved) = take.finish() else { return XCTFail("not saved") }
        XCTAssertEqual(saved, url)
        XCTAssertTrue(WAVFile.isFinished(url))
        XCTAssertFalse(FileManager.default.fileExists(atPath: PCMSidecar.url(for: url).path))
    }

    func testEmptyTakeLeavesNothing() throws {
        let url = dir.appendingPathComponent("Take.wav")
        let take = try TakeWriter(mainURL: url, format: .wav, notes: "", sampleRate: 48_000)
        guard case .nothingWritten = take.finish() else { return XCTFail("expected nothing written") }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [])
    }

    func testAACTakeEncodesFromItsSidecar() throws {
        try XCTSkipUnless(AACEncoder.isAvailable, "ffmpeg not installed")
        let url = dir.appendingPathComponent("Take.m4a")
        let take = try TakeWriter(mainURL: url, format: .aac, notes: "Guest: Ada", sampleRate: 44_100)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "only the sidecar exists while recording")
        let tone = (0..<44_100).map { Float(sin(Double($0) * 2 * .pi * 440 / 44_100) * 0.5) }
        try take.write(samples(tone))
        guard case .saved = take.finish() else { return XCTFail("not saved") }
        XCTAssertTrue(MP4File.isFinished(url))
        XCTAssertFalse(FileManager.default.fileExists(atPath: PCMSidecar.url(for: url).path))
        XCTAssertTrue(try Data(contentsOf: url).range(of: Data("Guest: Ada".utf8)) != nil,
                      "notes are written as the description tag")
    }

    /// The encode from the sidecar, when the live one failed, reports how
    /// far it has got, for "SAVING… 42%".
    func testAACEncodeReportsProgress() throws {
        try XCTSkipUnless(AACEncoder.isAvailable, "ffmpeg not installed")
        let url = dir.appendingPathComponent("Take.m4a")
        let sidecar = try PCMSidecar(mainOutput: url, sampleRate: 48_000)
        let tone = (0..<48_000 * 3).map { Float(sin(Double($0) * 2 * .pi * 440 / 48_000) * 0.5) }
        try sidecar.append(samples(tone))
        sidecar.close()
        var fractions: [Double] = []
        try AACEncoder.encode(sidecar: sidecar.url, sampleRate: 48_000, notes: "", to: url,
                              progress: { fractions.append($0) })
        XCTAssertFalse(fractions.isEmpty, "ffmpeg reported no progress")
        XCTAssertEqual(fractions.last ?? 0, 1, accuracy: 0.1, "the last report is the whole take")
        XCTAssertEqual(fractions, fractions.sorted(), "never goes backwards")
        XCTAssertTrue(MP4File.isFinished(url))
    }

    func testCancelledTakeDeletesEverything() throws {
        let url = dir.appendingPathComponent("Take.wav")
        let take = try TakeWriter(mainURL: url, format: .wav, notes: "", sampleRate: 48_000)
        try take.write(samples([0.2, 0.2]))
        take.cancel()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [])
    }
}
