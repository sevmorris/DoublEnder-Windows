import XCTest
@testable import DoublEnderCore

final class InstanceAndLogTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DoublEnderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        Log.stopFile()
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Single instance

    func testSecondCopyFindsTheLockTaken() throws {
        let name = "DoublEnderTests-\(UUID().uuidString)"
        guard case .acquired(let first) = InstanceLock.acquire(name: name, directory: dir) else {
            return XCTFail("the first copy should get the lock")
        }
        guard case .alreadyRunning = InstanceLock.acquire(name: name, directory: dir) else {
            return XCTFail("a second copy must see the first")
        }
        first.release()
        guard case .acquired = InstanceLock.acquire(name: name, directory: dir) else {
            return XCTFail("the lock is free once the first copy lets go")
        }
    }

    /// The diagnostics run beside the app; they must leave its takes alone.
    func testLaunchWithoutRecoveryLeavesSidecarsAlone() throws {
        let main = dir.appendingPathComponent("Live.wav")
        let sidecar = try PCMSidecar(mainOutput: main, sampleRate: 48_000)  // header only: a take just started
        defer { sidecar.discard() }
        let controller = RecorderController(engine: AudioEngine(), settings: SettingsStore(directory: nil),
                                            recordingsDirectory: dir, aacAvailable: false)
        defer { controller.engine.shutdown() }
        controller.launch(recoverInterruptedTakes: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecar.url.path))
        XCTAssertFalse(controller.dialogs.isShowing)
    }

    // MARK: - Log file

    func testLogFileCollectsLines() throws {
        Log.startFile(in: dir)
        Log.error("Opening input failed: test")
        Log.stopFile()
        let text = try String(contentsOf: dir.appendingPathComponent("DoublEnder.log"), encoding: .utf8)
        XCTAssertTrue(text.contains("info: DoublEnder \(AppInfo.version) started"))
        XCTAssertTrue(text.contains("error: Opening input failed: test"))
    }

    func testLargeLogIsMovedAside() throws {
        let log = dir.appendingPathComponent("DoublEnder.log")
        try Data(count: Int(Log.maxFileBytes) + 1).write(to: log)
        Log.startFile(in: dir)
        Log.stopFile()
        XCTAssertEqual(PCMSidecar.fileSize(dir.appendingPathComponent("DoublEnder.previous.log")), Log.maxFileBytes + 1)
        XCTAssertLessThan(PCMSidecar.fileSize(log) ?? .max, 1024)
    }
}
