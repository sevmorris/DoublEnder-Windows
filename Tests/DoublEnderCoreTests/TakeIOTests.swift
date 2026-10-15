import XCTest
@testable import DoublEnderCore

/// The take's disk writes run off the thread that drains the capture ring,
/// so a slow disk can't make the ring overflow.
final class TakeIOTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DoublEnderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// A disk that takes `delay` per write, or fails from the `failAt`th.
    final class SlowSink: TakeSink {
        let delay: Double
        let failAt: Int?
        private(set) var received: [Float] = []
        private var writes = 0
        var sidecarFailed: Bool { false }

        init(delay: Double = 0, failAt: Int? = nil) {
            self.delay = delay
            self.failAt = failAt
        }

        func write(_ samples: UnsafeBufferPointer<Float>) throws {
            writes += 1
            if let failAt, writes >= failAt { throw RecordingError.cannotCreateFile("disk full") }
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            received += samples
        }
    }

    private func enqueue<S: TakeSink>(_ io: TakeIO<S>, value: Float, count: Int = 480) {
        let block = [Float](repeating: value, count: count)
        block.withUnsafeBufferPointer { io.enqueue($0) }
    }

    func testSlowDiskNeverHoldsUpTheCaller() {
        let sink = SlowSink(delay: 0.05)
        let io = TakeIO(sink: sink, queue: DispatchQueue(label: "test.io"))
        let start = Date()
        for i in 0..<20 { enqueue(io, value: Float(i)) }
        let handOver = Date().timeIntervalSince(start)
        XCTAssertLessThan(handOver, 0.1, "20 blocks to a 50 ms-per-write disk must hand over at once, not take ~1 s")
        XCTAssertGreaterThan(io.backlogFrames, 0, "the disk is behind, so the audio waits in memory")
        XCTAssertEqual(io.framesEnqueued, 20 * 480)

        io.drain()
        XCTAssertEqual(io.backlogFrames, 0)
        XCTAssertEqual(sink.received.count, 20 * 480, "nothing lost")
        XCTAssertEqual(stride(from: 0, to: sink.received.count, by: 480).map { sink.received[$0] },
                       (0..<20).map(Float.init), "written in the order captured")
        XCTAssertGreaterThan(io.lastWrite, 0)
        XCTAssertGreaterThanOrEqual(io.ioSummary.longestWrite, 0.05)
        XCTAssertGreaterThan(io.ioSummary.largestBacklogFrames, 480)
    }

    func testFirstWriteErrorIsReported() {
        let io = TakeIO(sink: SlowSink(failAt: 3), queue: DispatchQueue(label: "test.io"))
        for i in 0..<5 { enqueue(io, value: Float(i)) }
        io.drain()
        guard case .cannotCreateFile("disk full")? = io.error as? RecordingError else {
            return XCTFail("expected the first write error, got \(String(describing: io.error))")
        }
        XCTAssertGreaterThan(io.lastWrite, 0, "the writes before it reached the disk")
    }

    func testWAVTakeWrittenThroughTheQueue() throws {
        let url = dir.appendingPathComponent("Take.wav")
        let writer = try TakeWriter(mainURL: url, format: .wav, notes: "", sampleRate: 48_000)
        let io = TakeIO(sink: writer, queue: DispatchQueue(label: "test.io"))
        for i in 0..<10 { enqueue(io, value: Float(i) / 20) }
        io.drain()
        guard case .saved = writer.finish() else { return XCTFail("not saved") }
        let bytes = [UInt8](try Data(contentsOf: url))
        XCTAssertEqual(bytes.loadLE(UInt32.self, at: 40), 10 * 480 * 3)
        // The first sample of each block, in order: 24-bit, little-endian.
        for i in 0..<10 {
            let offset = 44 + i * 480 * 3
            let raw = Int32(bytes[offset]) | Int32(bytes[offset + 1]) << 8 | Int32(bytes[offset + 2]) << 16
            XCTAssertEqual(raw, Int32((Double(Float(i) / 20) * 8_388_608).rounded()), "block \(i)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: PCMSidecar.url(for: url).path))
    }

    func testSidecarSyncsByTime() throws {
        let sidecar = try PCMSidecar(mainOutput: dir.appendingPathComponent("Take.m4a"), sampleRate: 48_000)
        defer { sidecar.discard() }
        sidecar.syncInterval = 0.05
        let block = [Float](repeating: 0.1, count: 4800)
        try block.withUnsafeBufferPointer { try sidecar.append($0) }
        XCTAssertEqual(sidecar.syncCount, 0, "not due yet")
        Thread.sleep(forTimeInterval: 0.06)
        try block.withUnsafeBufferPointer { try sidecar.append($0) }
        XCTAssertEqual(sidecar.syncCount, 1)
        try block.withUnsafeBufferPointer { try sidecar.append($0) }
        XCTAssertEqual(sidecar.syncCount, 1, "however much arrives, once per interval")
    }

    /// The whole engine: capture thread, ring, pump, TakeIO, finish. The null
    /// backend's input delivers silence at real time, so this needs no
    /// microphone and runs on every CI runner.
    func testEngineRecordsAndSavesThroughTheNullBackend() throws {
        let engine = AudioEngine(nullBackend: true)
        defer { engine.shutdown() }
        XCTAssertEqual(engine.backendName, "Null")
        var failure: CaptureFailure?
        engine.onTakeFailed = { failure = $0 }

        engine.refreshDevices()
        XCTAssertTrue(runMainLoop(until: { !engine.availableInputDevices.isEmpty }), "the null input is listed")
        engine.setDevice(engine.availableInputDevices.first)
        XCTAssertTrue(runMainLoop(until: { engine.engineHealthy && engine.currentFormat != nil }), "it opens")
        let rate = try XCTUnwrap(engine.currentFormat?.sampleRate)

        let url = dir.appendingPathComponent("Take.wav")
        try engine.startRecording(to: url, format: .wav, notes: "")
        XCTAssertTrue(runMainLoop(until: { engine.isWritingData }), "audio reaches the file")
        runMainLoop(for: 1)
        var result: StopResult?
        engine.stopRecording { result = $0 }
        XCTAssertTrue(runMainLoop(until: { result != nil }, timeout: 10), "the stop completes")

        guard case .success(.some(let saved))? = result else {
            return XCTFail("expected a saved take, got \(String(describing: result))")
        }
        XCTAssertNil(failure, "no watchdog fired: \(String(describing: failure))")
        XCTAssertEqual(saved, url)
        XCTAssertTrue(WAVFile.isFinished(url))
        let seconds = Double([UInt8](try Data(contentsOf: url)).loadLE(UInt32.self, at: 40) / 3) / rate
        XCTAssertGreaterThan(seconds, 0.9, "about the second recorded")
        XCTAssertLessThan(seconds, 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: PCMSidecar.url(for: url).path), "sidecar removed")
    }

    func testTakeReportLine() throws {
        let url = dir.appendingPathComponent("Take.wav")
        let writer = try TakeWriter(mainURL: url, format: .wav, notes: "", sampleRate: 48_000)
        let io = TakeIO(sink: writer, queue: DispatchQueue(label: "test.io"))
        enqueue(io, value: 0.1)
        io.noteDrain(gap: 0.012)
        io.drain()
        let result: StopResult
        if case .saved(let saved) = writer.finish() { result = .success(saved) } else { return XCTFail("not saved") }
        let format = CaptureFormat(sampleRate: 48_000, channels: 2, sampleFormat: .f32, channelMap: [2, 3],
                                   gains: MonoMix.gains(channelMap: [2, 3]))
        let line = AudioEngine.takeReport(io, result: result, cancelled: false, format: format, seconds: 12.34, dropped: 0)
        XCTAssertTrue(line.hasPrefix("Take saved: 12.3 s, wav, 48000 Hz 2 ch float32; dropped 0 frames; "), line)
        XCTAssertTrue(line.contains("longest wait between ring reads 12 ms"), line)
    }
}
