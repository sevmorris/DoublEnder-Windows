import DoublEnderCore
import Foundation

/// Command-line diagnostics. They let a producer (or a developer) check a
/// guest's machine without the window: which inputs miniaudio sees, and
/// whether a take records and saves.
enum Diagnostics {

    /// Runs the main-loop work without a window until `done` or `timeout`.
    @discardableResult
    static func pump(_ controller: RecorderController, timeout: Double, until done: () -> Bool) -> Bool {
        let deadline = Platform.now() + timeout
        while Platform.now() < deadline {
            MainQueue.drain()
            controller.tick()
            if done() { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return false
    }

    static func listDevices() -> Int32 {
        let controller = RecorderController(settings: SettingsStore(directory: nil))
        print("Audio backend: \(controller.engine.backendName)")
        controller.launch()
        pump(controller, timeout: 5) { controller.state != .selectingMic }
        for device in controller.inputDevices {
            print("\(device.isDefault ? "*" : " ") \(device.name)\(device.isUSB ? "  [usb]" : "")")
        }
        if controller.inputDevices.isEmpty { print("No capture devices found.") }
        pump(controller, timeout: 5) { controller.canStartRecording }
        if let format = controller.engine.currentFormat {
            print("Default input opens as \(Int(format.sampleRate)) Hz, \(format.channels) ch, \(format.sampleFormat.diagnosticName), map \(format.channelMap)")
        } else if let error = controller.engine.lastOpenError {
            print("Default input failed to open: \(error)")
        }
        print("AAC encoder: \(AACEncoder.ffmpegPath ?? "not found (WAV only)")")
        print("Recordings go to: \(Platform.recordingsDirectory.path)")
        controller.engine.shutdown()
        return 0
    }

    static func testRecord(seconds: Double, format: OutputFormat, directory: URL) -> Int32 {
        let controller = RecorderController(settings: SettingsStore(directory: nil), recordingsDirectory: directory)
        controller.outputFormat = format
        controller.launch()
        guard pump(controller, timeout: 10, until: { controller.canStartRecording }) else {
            print("Input never became ready: \(controller.engine.lastOpenError ?? String(describing: controller.state))")
            controller.engine.shutdown()
            return 1
        }
        controller.dialogs.items.forEach { controller.dialogs.remove($0.id) }
        print("Recording \(seconds)s from \(controller.boundInputDeviceName ?? "?") as \(format.displayName)…")
        controller.startRecording()
        var peak = LevelMeter.dbFloor
        pump(controller, timeout: seconds) {
            peak = max(peak, controller.meterLevel)
            return controller.state != .recording
        }
        print(String(format: "Meter peak: %.1f dBFS", peak))
        controller.stopRecording()
        pump(controller, timeout: 120) { !controller.isStopping }
        controller.engine.shutdown()
        if let saved = controller.dialogs.current, let name = saved.fileName {
            print("\(saved.message) \(directory.appendingPathComponent(name).path)")
            return 0
        }
        print("Take did not save: \(controller.state)")
        return 1
    }
}

/// Development aid: walks the UI through its main states and saves a
/// screenshot of each into a folder, so the rendering can be checked
/// against the Mac app's without clicking through by hand.
final class UITour {
    private let directory: URL
    private var stage = 0
    private var stageStart = 0.0
    private var pendingShot: String?

    init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func capture(app: App) {
        guard let name = pendingShot else { return }
        app.screenshot(to: directory.appendingPathComponent("\(name).png").path)
        pendingShot = nil
    }

    func step(app: App) {
        let c = app.controller
        let now = Platform.now()
        let elapsed = now - stageStart
        func next() { stage += 1; stageStart = now }
        switch stage {
        case 0 where c.canStartRecording && elapsed > 2:
            pendingShot = "01-idle"; next()
        case 1:
            app.faceplate.popover = .devices; next()
        case 2 where elapsed > 0.3:
            pendingShot = "02-devices"; next()
        case 3:
            app.faceplate.popover = .settings; next()
        case 4 where elapsed > 0.3:
            pendingShot = "03-settings"; next()
        case 5:
            app.faceplate.popover = nil
            c.toggleRecording(); next()
        case 6 where elapsed > 4:
            pendingShot = "04-recording"; next()
        case 7:
            c.toggleRecording(); next()
        case 8 where c.dialogs.current != nil && elapsed > 0.5:
            pendingShot = "05-saved"; next()
        case 9:
            if let dialog = c.dialogs.current, let ok = dialog.buttons.first(where: \.isDefault) {
                c.dialogs.press(ok, in: dialog)
            }
            next()
        case 10 where elapsed > 0.5:
            c.requestQuit(); next()
        default:
            break
        }
    }
}
