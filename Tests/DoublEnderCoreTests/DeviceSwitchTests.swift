import XCTest
@testable import DoublEnderCore

/// Changing inputs around a take, through the engine on miniaudio's null
/// backend and the controller on top of it.
final class DeviceSwitchTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DoublEnderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Two picks in a row: each replaces the device, so a take started once
    /// the first had opened would have its input swapped by the second, at
    /// the second's sample rate. RECORD waits for the last one.
    func testRecordWaitsForTheLastQueuedPick() throws {
        let engine = AudioEngine(nullBackend: true)
        defer { engine.shutdown() }
        engine.refreshDevices()
        XCTAssertTrue(runMainLoop(until: { !engine.availableInputDevices.isEmpty }), "the null input is listed")
        let device = try XCTUnwrap(engine.availableInputDevices.first)
        engine.setDevice(device)
        XCTAssertTrue(runMainLoop(until: { engine.engineHealthy && !engine.isRebuilding }), "it opens")

        // The device queue runs these in order, so the refresh's completion
        // comes after the first pick's and before the second's.
        var rebuildingBetween: Bool?
        var startError: Error?
        engine.setDevice(device)
        engine.refreshDevices {
            rebuildingBetween = engine.isRebuilding
            do {
                try engine.startRecording(to: self.dir.appendingPathComponent("Take.wav"), format: .wav, notes: "")
            } catch {
                startError = error
            }
        }
        engine.setDevice(device)
        XCTAssertTrue(runMainLoop(until: { rebuildingBetween != nil && !engine.isRebuilding }))
        XCTAssertEqual(rebuildingBetween, true, "the second pick is still opening")
        XCTAssertNotNil(startError, "so no take starts on the device it is about to replace")
        XCTAssertFalse(engine.isRecordingActive)
    }

    /// The input is lost while a take is running or saving. Picking another
    /// is refused until the stop has finished, so the controller makes the
    /// switch then; it used to drop it, leaving no input and RECORD off.
    func testInputLostDuringATakeIsReplacedOnceItStops() throws {
        let engine = AudioEngine(nullBackend: true)
        defer { engine.shutdown() }
        let controller = RecorderController(engine: engine, settings: SettingsStore(directory: nil),
                                            recordingsDirectory: dir, aacAvailable: false)
        controller.launch(recoverInterruptedTakes: false)
        XCTAssertTrue(runMainLoop(until: { controller.canStartRecording }), "the null input opens")
        controller.startRecording()
        XCTAssertTrue(controller.isCurrentlyRecording)

        // What the engine reports when the bound input vanishes outside a
        // take, as it does while one is saving.
        engine.onActiveInputLostWhileIdle?()
        XCTAssertTrue(runMainLoop(until: { controller.inputSwitchAfterStop }), "the switch waits for the stop")
        XCTAssertFalse(engine.isRebuilding, "nothing was picked during the take")

        controller.stopRecording()
        XCTAssertTrue(runMainLoop(until: { !controller.isStopping }, timeout: 10), "the stop completes")
        XCTAssertFalse(controller.inputSwitchAfterStop)
        XCTAssertTrue(runMainLoop(until: { engine.isRebuilding }), "the fallback input is opened")
        XCTAssertTrue(runMainLoop(until: { controller.canStartRecording }), "and RECORD comes back")
    }
}
