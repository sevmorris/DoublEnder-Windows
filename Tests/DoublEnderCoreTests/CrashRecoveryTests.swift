import XCTest
@testable import DoublEnderCore

final class CrashRecoveryTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DoublEnderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func sidecar(for name: String, samples: Int) throws -> URL {
        let main = dir.appendingPathComponent(name)
        let sidecar = try PCMSidecar(mainOutput: main, sampleRate: 48_000)
        if samples > 0 {
            let values = [Float](repeating: 0.25, count: samples)
            try values.withUnsafeBufferPointer { try sidecar.append($0) }
        }
        sidecar.close()
        return sidecar.url
    }

    private func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path)
    }

    func testEmptySidecarAndStubMainFileAreDeleted() throws {
        _ = try sidecar(for: "A.m4a", samples: 0)
        try Data(count: 100).write(to: dir.appendingPathComponent("A.m4a"))
        let dialogs = DialogQueue()
        CrashRecovery.run(in: dir, dialogs: dialogs)
        XCTAssertFalse(dialogs.isShowing)
        XCTAssertFalse(exists("A.m4a"))
        XCTAssertFalse(exists("A.m4a.pcmrec"))
    }

    func testEmptySidecarBesideALargeMainFileKeepsIt() throws {
        _ = try sidecar(for: "B.wav", samples: 0)
        try Data(count: 64 * 1024).write(to: dir.appendingPathComponent("B.wav"))
        CrashRecovery.run(in: dir, dialogs: DialogQueue())
        XCTAssertTrue(exists("B.wav"), "the only copy of the audio stays")
        XCTAssertFalse(exists("B.wav.pcmrec"))
    }

    func testInterruptedTakeOffersRecovery() throws {
        _ = try sidecar(for: "C.m4a", samples: 4800)
        let dialogs = DialogQueue()
        CrashRecovery.run(in: dir, dialogs: dialogs)
        let prompt = try XCTUnwrap(dialogs.current)
        XCTAssertEqual(prompt.title, "UNSAVED RECORDING")
        XCTAssertEqual(prompt.buttons.map(\.title), ["RECOVER", "DELETE"])

        dialogs.press(prompt.buttons[0], in: prompt)
        XCTAssertTrue(dialogs.current?.showsSpinner ?? false)
        let deadline = Date().addingTimeInterval(5)
        while dialogs.current?.showsSpinner == true, Date() < deadline {
            MainQueue.drain()
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertEqual(dialogs.current?.title, "RECOVERY COMPLETE")
        XCTAssertEqual(dialogs.current?.fileName, "C (recovered).wav")
        XCTAssertTrue(exists("C (recovered).wav"))
        XCTAssertFalse(exists("C.m4a.pcmrec"))
    }

    func testFinishedMainFileOffersKeepSaved() throws {
        _ = try sidecar(for: "D.wav", samples: 480)
        let writer = try WAVWriter(url: dir.appendingPathComponent("D.wav"), sampleRate: 48_000)
        try [Float](repeating: 0.1, count: 480).withUnsafeBufferPointer { try writer.append($0) }
        try writer.finalize()

        let dialogs = DialogQueue()
        CrashRecovery.run(in: dir, dialogs: dialogs)
        let prompt = try XCTUnwrap(dialogs.current)
        XCTAssertEqual(prompt.title, "SAVED RECORDING FOUND")
        XCTAssertEqual(prompt.buttons.map(\.title), ["KEEP SAVED", "RECOVER", "DELETE"])
        dialogs.press(prompt.buttons[0], in: prompt)
        XCTAssertTrue(exists("D.wav"))
        XCTAssertFalse(exists("D.wav.pcmrec"))
    }

    func testCrashedWAVIsNotTreatedAsFinished() throws {
        _ = try sidecar(for: "E.wav", samples: 480)
        let writer = try WAVWriter(url: dir.appendingPathComponent("E.wav"), sampleRate: 48_000)
        try [Float](repeating: 0.1, count: 480).withUnsafeBufferPointer { try writer.append($0) }
        writer.abandon()  // a crash: the header never gets its sizes
        let dialogs = DialogQueue()
        CrashRecovery.run(in: dir, dialogs: dialogs)
        XCTAssertEqual(dialogs.current?.title, "UNSAVED RECORDING")
    }

    func testEachRecoverableTakeGetsItsOwnDialog() throws {
        _ = try sidecar(for: "F1.m4a", samples: 10)
        _ = try sidecar(for: "F2.m4a", samples: 10)
        let dialogs = DialogQueue()
        CrashRecovery.run(in: dir, dialogs: dialogs)
        XCTAssertEqual(dialogs.items.compactMap(\.fileName), ["F1.m4a", "F2.m4a"])
    }

    func testLeftoverEncoderOutputIsRemoved() throws {
        try Data(count: 10).write(to: dir.appendingPathComponent(".G.m4a.part"))
        try Data(count: 10).write(to: dir.appendingPathComponent(".G (recovered).wav.part"))
        try Data(count: 10).write(to: dir.appendingPathComponent("download.wav.part"))  // not ours
        CrashRecovery.run(in: dir, dialogs: DialogQueue())
        XCTAssertFalse(exists(".G.m4a.part"))
        XCTAssertFalse(exists(".G (recovered).wav.part"))
        XCTAssertTrue(exists("download.wav.part"))
    }
}
