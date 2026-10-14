import XCTest
@testable import DoublEnderCore

/// ffmpeg runs through `ChildProcess` (no console window on Windows), and an
/// AAC take is encoded while it records, falling back to its sidecar.
final class LiveEncodeTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DoublEnderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func files() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
    }

    /// The take's log line, as the engine writes it when the take stops.
    private func report(_ take: TakeWriter, _ saved: URL) -> String {
        let io = TakeIO(sink: take, queue: DispatchQueue(label: "test.io"))
        return AudioEngine.takeReport(io, result: .success(saved), cancelled: false, format: nil, seconds: 3, dropped: 0)
    }

    private func write(_ take: TakeWriter, seconds: Double, rate: Double = 48_000) throws {
        let block = 4_800  // 100 ms, about what the pump hands over
        for start in stride(from: 0, to: Int(seconds * rate), by: block) {
            let tone = (start..<start + block).map { Float(sin(Double($0) * 2 * .pi * 440 / rate) * 0.4) }
            try tone.withUnsafeBufferPointer { try take.write($0) }
        }
    }

    // MARK: - The Windows command line

    /// Each argument must come back out of the child's C runtime unchanged:
    /// a path with spaces, and notes with quotes and backslashes.
    func testWindowsCommandLineQuoting() {
        let line = ChildProcess.windowsCommandLine
        XCTAssertEqual(line(["abc", "def"]), #"abc def"#)
        XCTAssertEqual(line(["a b", "c"]), #""a b" c"#)
        XCTAssertEqual(line([""]), #""""#)
        XCTAssertEqual(line([#"a\b"#]), #"a\b"#, "backslashes stand for themselves outside quotes")
        XCTAssertEqual(line([#"a"b"#]), #""a\"b""#)
        XCTAssertEqual(line([#"a\"b"#]), #""a\\\"b""#, "a backslash before a quote is doubled, then the quote escaped")
        XCTAssertEqual(line([#"a b\"#]), #""a b\\""#, "a trailing backslash is doubled before the closing quote")
        XCTAssertEqual(line([#"a\\b c"#]), #""a\\b c""#, "backslashes not before a quote stay as they are")
        XCTAssertEqual(line([#"C:\Program Files\DoublEnder\ffmpeg.exe"#, #"description=Guest "Ada" \ ok"#]),
                       #""C:\Program Files\DoublEnder\ffmpeg.exe" "description=Guest \"Ada\" \ ok""#)
        XCTAssertEqual(line(["tab\there"]), "\"tab\there\"")
    }

    // MARK: - Child processes

    #if os(Windows)
    private var system32: String {
        (ProcessInfo.processInfo.environment["SystemRoot"] ?? #"C:\Windows"#) + #"\System32"#
    }

    func testChildRoundTripOnWindows() throws {
        let sort = try ChildProcess(system32 + #"\sort.exe"#, [])
        XCTAssertTrue(Data("b\r\na\r\n".utf8).withUnsafeBytes { sort.write($0) })
        sort.closeInput()
        let errors = PipeDrain(sort, 2)
        XCTAssertEqual(String(decoding: sort.readAll(1), as: UTF8.self), "a\r\nb\r\n")
        _ = errors.wait()
        XCTAssertEqual(sort.wait(), 0)
    }

    func testChildExitStatusOnWindows() throws {
        let cmd = try ChildProcess(system32 + #"\cmd.exe"#, ["/c", "exit 3"])
        cmd.closeInput()
        XCTAssertEqual(cmd.wait(), 3)
    }

    /// A child that runs for about 30 s.
    private func longRunningChild() throws -> ChildProcess {
        try ChildProcess(system32 + #"\PING.EXE"#, ["-n", "30", "127.0.0.1"])
    }
    #else
    func testChildRoundTrip() throws {
        let cat = try ChildProcess("/bin/cat", [])
        XCTAssertTrue(Data("hello\n".utf8).withUnsafeBytes { cat.write($0) })
        cat.closeInput()
        XCTAssertEqual(String(decoding: cat.readAll(1), as: UTF8.self), "hello\n")
        XCTAssertEqual(cat.wait(), 0)
    }

    func testChildKeepsStdoutAndStderrApart() throws {
        let sh = try ChildProcess("/bin/sh", ["-c", "echo out; echo err >&2; exit 3"])
        sh.closeInput()
        let errors = PipeDrain(sh, 2)
        XCTAssertEqual(String(decoding: sh.readAll(1), as: UTF8.self), "out\n")
        XCTAssertEqual(String(decoding: errors.wait(), as: UTF8.self), "err\n")
        XCTAssertEqual(sh.wait(), 3)
    }

    /// Writing to a child that has exited fails instead of raising SIGPIPE,
    /// which would end the app.
    func testWritingToAnExitedChildFails() throws {
        let child = try ChildProcess("/bin/sh", ["-c", "exit 0"])
        child.wait()
        let block = [UInt8](repeating: 0, count: 256 * 1024)
        XCTAssertFalse(block.withUnsafeBytes { child.write($0) })
    }

    private func longRunningChild() throws -> ChildProcess {
        try ChildProcess("/bin/sleep", ["30"])
    }

    /// ffmpeg stalling without dying: `yes` never reads its input. The
    /// encoder gives up once it is `maxBacklog` behind, rather than hold the
    /// rest of the take in memory, and the take is saved from its sidecar.
    func testALiveEncoderThatFallsBehindIsAbandoned() throws {
        let output = dir.appendingPathComponent("Take.m4a")
        let encoder = try LiveEncoder(ffmpeg: "/usr/bin/yes", sampleRate: 48_000, notes: "", output: output,
                                      maxBacklog: 0.5)
        let block = [Float](repeating: 0.1, count: 4_800)
        for _ in 0..<20 { block.withUnsafeBufferPointer { encoder.write($0) } }
        XCTAssertTrue(encoder.fellBehind)
        let started = Date()
        XCTAssertFalse(encoder.finish(expectedFrames: 20 * 4_800, timeout: 20))
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "ended at once, not at the timeout")
        XCTAssertEqual(try files(), [])
    }
    #endif

    /// A kill reaches a child another thread is waiting for (as when the
    /// live encode times out), and a kill after the wait does nothing.
    func testKillEndsAChildBeingWaitedFor() throws {
        let child = try longRunningChild()
        child.closeInput()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { child.kill() }
        let started = Date()
        XCTAssertNotEqual(child.wait(), 0)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
        child.kill()
    }

    func testStartingAMissingProgramThrows() {
        XCTAssertThrowsError(try ChildProcess(dir.appendingPathComponent("no-such-program").path, []))
    }

    // MARK: - Live AAC encoding

    func testAACTakeIsEncodedWhileItRecords() throws {
        try XCTSkipUnless(AACEncoder.isAvailable, "ffmpeg not installed")
        let url = dir.appendingPathComponent("Take.m4a")
        let take = try TakeWriter(mainURL: url, format: .aac, notes: #"Guest: "Ada" \ ok"#, sampleRate: 48_000)
        XCTAssertNotNil(take.liveEncoder, "ffmpeg is running from the first sample")
        try write(take, seconds: 3)
        guard case .saved(let saved) = take.finish() else { return XCTFail("not saved") }
        XCTAssertEqual(saved, url)
        XCTAssertTrue(take.savedLive, "saved from the live encode, not the sidecar")
        XCTAssertTrue(MP4File.isFinished(url))
        XCTAssertNotNil(try Data(contentsOf: url).range(of: Data(#"Guest: "Ada" \ ok"#.utf8)),
                        "the notes arrive intact, quotes and backslash included")
        XCTAssertEqual(try files(), ["Take.m4a"], "no sidecar and no temporary file left")
        XCTAssertTrue(report(take, saved).hasPrefix("Take saved: 3.0 s, aac (encoded live), "))
    }

    /// ffmpeg dying partway through costs nothing: the take is encoded from
    /// its sidecar after STOP, as before live encoding.
    func testALiveEncoderThatDiesFallsBackToTheSidecar() throws {
        try XCTSkipUnless(AACEncoder.isAvailable, "ffmpeg not installed")
        let url = dir.appendingPathComponent("Take.m4a")
        let take = try TakeWriter(mainURL: url, format: .aac, notes: "Guest: Ada", sampleRate: 48_000)
        try write(take, seconds: 1)
        take.liveEncoder?.killForTesting()
        Thread.sleep(forTimeInterval: 0.3)
        try write(take, seconds: 1)
        guard case .saved(let saved) = take.finish() else { return XCTFail("not saved") }
        XCTAssertFalse(take.savedLive, "saved from the sidecar")
        XCTAssertTrue(report(take, saved).hasPrefix("Take saved: 3.0 s, aac (encoded after STOP), "))
        XCTAssertTrue(MP4File.isFinished(url))
        XCTAssertNotNil(try Data(contentsOf: url).range(of: Data("Guest: Ada".utf8)))
        XCTAssertEqual(try files(), ["Take.m4a"])
    }

    func testCancelledAACTakeLeavesNothing() throws {
        try XCTSkipUnless(AACEncoder.isAvailable, "ffmpeg not installed")
        let take = try TakeWriter(mainURL: dir.appendingPathComponent("Take.m4a"), format: .aac,
                                  notes: "", sampleRate: 48_000)
        try write(take, seconds: 0.5)
        take.cancel()
        XCTAssertEqual(try files(), [])
    }

    func testEmptyAACTakeLeavesNothing() throws {
        try XCTSkipUnless(AACEncoder.isAvailable, "ffmpeg not installed")
        let take = try TakeWriter(mainURL: dir.appendingPathComponent("Take.m4a"), format: .aac,
                                  notes: "", sampleRate: 48_000)
        guard case .nothingWritten = take.finish() else { return XCTFail("expected nothing written") }
        XCTAssertEqual(try files(), [])
    }
}
