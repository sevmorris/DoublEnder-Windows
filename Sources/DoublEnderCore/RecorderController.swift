import Foundation

public enum AppState: Equatable {
    /// Waiting for the first device list.
    case selectingMic
    /// An input is chosen; RECORD waits on `canStartRecording`.
    case ready
    case recording
    /// Fatal; `reset()` returns to `.ready`.
    case error(String)
}

/// The recorder's single source of truth: the port of the Mac build's
/// RecorderViewModel (THEORY_OF_OPERATION §4–6), minus the Cloud variant.
/// Main loop only. The faceplate reads it every frame and calls into it on
/// input; `tick()` runs its timers.
public final class RecorderController {
    public let engine: AudioEngine
    public let dialogs = DialogQueue()
    public let recordingsDirectory: URL
    private let settings: SettingsStore

    public private(set) var state: AppState = .selectingMic
    /// STOP was pressed and the take is being finalized (AAC encodes).
    public private(set) var isStopping = false
    /// How far an AAC take's encode has got, 0…1, while `isStopping`; nil
    /// before ffmpeg first reports and for a WAV.
    public private(set) var saveProgress: Double?
    public private(set) var recordingTime: Double = 0
    /// Set once quitting is approved; the main loop exits on it.
    public private(set) var shouldQuit = false
    public private(set) var selectedInputDeviceID = ""

    /// Settings-popover prefix. Session-scoped, as on the Mac: cleared at
    /// launch and at quit, so a guest's custom name never carries over.
    public var filenameBase: String {
        get { settings.filenameBase }
        set { settings.filenameBase = newValue }
    }

    /// Written as the M4A's description tag. Never saved.
    public var notes = ""

    public var outputFormat: OutputFormat {
        didSet { settings.outputFormat = outputFormat }
    }

    /// AAC needs ffmpeg; without it the format picker offers WAV only.
    public let aacAvailable: Bool

    private var recordingStartedAt: Double = 0
    private var recordedFileURL: URL?
    private var pendingDisconnectReason: String?
    private var diskStopReason: String?
    private var suppressIdleInputLossAlert = false
    private var suppressIdleInputLossUntil: Double = 0
    private var lastInputLossAlertAt: Double = -.infinity
    private var dismissedNewDevices: Set<String> = []
    private var isFinalizingRecording = false
    /// The input was lost while a take was stopping; switch when it's done.
    private(set) var inputSwitchAfterStop = false
    private var quitWhenStopped = false
    private var quitPromptID: UUID?
    private var launched = false

    private var nextDiskCheck: Double = 0
    private var nextHealthCheck: Double = 0
    private var nextDevicePoll: Double = 0

    static let diskWatchInterval: Double = 5
    static let inputWatchInterval: Double = 1
    static let devicePollInterval: Double = 2
    static let inputLossAlertCooldown: Double = 3

    public init(engine: AudioEngine = AudioEngine(),
                settings: SettingsStore = SettingsStore(),
                recordingsDirectory: URL = Platform.recordingsDirectory,
                aacAvailable: Bool = AACEncoder.isAvailable) {
        self.engine = engine
        self.settings = settings
        self.recordingsDirectory = recordingsDirectory
        self.aacAvailable = aacAvailable
        let saved = settings.outputFormat ?? .aac
        outputFormat = (saved == .aac && !aacAvailable) ? .wav : saved

        engine.onSaveProgress = { [weak self] fraction in
            guard let self, self.isStopping else { return }
            self.saveProgress = fraction
        }
        engine.onTakeFailed = { [weak self] failure in
            self?.handleTakeFailure(failure)
        }
        engine.onActiveInputLostWhileIdle = { [weak self] in
            guard let self, !self.suppressIdleInputLossAlert else { return }
            self.switchToFallbackInputAfterLoss()
            self.presentInputLostWhileIdleAlert()
        }
        engine.onDevicesChanged = { [weak self] added in
            self?.handleDevicesChanged(added: added)
        }
    }

    // MARK: - Launch

    /// Clears session settings, runs crash recovery and binds an input.
    ///
    /// Crash recovery is only safe in the one running recorder: anything else
    /// (the command-line diagnostics) passes false, or it could take a take
    /// in progress for an abandoned one.
    public func launch(recoverInterruptedTakes: Bool = true) {
        guard !launched else { return }
        launched = true
        settings.filenameBase = ""
        if recoverInterruptedTakes {
            CrashRecovery.run(in: recordingsDirectory, dialogs: dialogs)
        }

        guard engine.hasAudioBackend else {
            state = .error(Platform.isWindows
                ? "No audio system was found. Check that Windows Audio is running, then try again."
                : "No audio system was found. DoublEnder needs PipeWire, PulseAudio or ALSA.")
            return
        }
        engine.refreshDevices { [weak self] in
            guard let self else { return }
            self.recordDevicesFirstSeen()
            // Every launch starts on the system's default input, then offers
            // the most recently plugged-in USB mic — the Mac starts on the
            // built-in mic and offers USB the same way.
            if let device = self.engine.defaultInputDevice() {
                self.selectInput(device.uid)
            } else {
                self.engine.setDevice(nil)
            }
            self.state = .ready
            if let usb = self.mostRecentlyConnectedUSBDevice() {
                self.presentNewDevicePrompt(for: usb)
            }
        }
    }

    // MARK: - Readouts

    public var isCurrentlyRecording: Bool { state == .recording }

    public var meterLevel: Float { engine.meterLevel }

    public var isWritingData: Bool { engine.isWritingData }

    /// Devices for the picker, loopback sources excluded.
    public var inputDevices: [InputDevice] { engine.availableInputDevices }

    /// The name under the meter: the pick if it is open and live, else
    /// "(no input)"; nil before anything is picked.
    public var boundInputDeviceName: String? {
        guard let device = engine.availableInputDevices.first(where: { $0.uid == selectedInputDeviceID }) else {
            return nil
        }
        if !engine.selectedDeviceUsable { return "(no input)" }
        return engine.engineHealthy && !engine.inputStalled ? device.name : "(no input)"
    }

    /// True when RECORD will reliably produce a recording.
    public var canStartRecording: Bool {
        engine.engineHealthy && engine.selectedDeviceUsable && !engine.isRebuilding
            && !engine.inputStalled && !isStopping
    }

    /// A non-fatal condition for the badge under the counter.
    public var recordingWarning: String? {
        if let format = engine.currentFormat, format.sampleRate <= 16_000 {
            return "Low-quality input (Bluetooth headset?)"
        }
        if isCurrentlyRecording && engine.sidecarUnavailable { return "No crash recovery" }
        if isCurrentlyRecording && engine.sidecarFailedDuringRecording { return "Crash backup unavailable" }
        if isCurrentlyRecording && engine.droppedFrameWarning { return "Dropped frames — check disk" }
        // The take is safe in memory and still recording; the disk is behind.
        if isCurrentlyRecording && engine.writeBacklogSeconds > 5 { return "Disk is slow — still recording" }
        return nil
    }

    // MARK: - Input selection

    /// Picks an input. Ignored during a take, as the Mac reverts the pick.
    public func selectInput(_ uid: String) {
        guard !isCurrentlyRecording, !isStopping else { return }
        guard let device = engine.availableInputDevices.first(where: { $0.uid == uid }) else { return }
        selectedInputDeviceID = uid
        engine.setDevice(device)
    }

    private func switchToFallbackInputAfterLoss() {
        inputSwitchAfterStop = false
        engine.refreshDevices { [weak self] in
            guard let self else { return }
            // A take or its save is still running, and the pick would be
            // refused: an input lost during "SAVING…" left none bound. Switch
            // once the stop has finished (`finishStop`).
            if self.isCurrentlyRecording || self.isStopping {
                self.inputSwitchAfterStop = true
                return
            }
            if let fallback = self.engine.defaultInputDevice() {
                self.selectInput(fallback.uid)
            } else {
                self.selectedInputDeviceID = ""
                self.engine.setDevice(nil)
            }
        }
    }

    // MARK: - Timers

    /// Per frame: the counter, the disk watch, the input-health poll, and
    /// the device poll that stands in for CoreAudio's device listener.
    public func tick() {
        let now = Platform.now()
        if isCurrentlyRecording && !isStopping {
            recordingTime = now - recordingStartedAt
            if now >= nextDiskCheck {
                nextDiskCheck = now + Self.diskWatchInterval
                checkDiskSpaceDuringRecording()
            }
            if now >= nextHealthCheck {
                nextHealthCheck = now + Self.inputWatchInterval
                engine.checkRecordingInputHealth()
            }
        } else if launched && engine.hasAudioBackend && now >= nextDevicePoll {
            nextDevicePoll = now + Self.devicePollInterval
            engine.refreshDevices()
        }
        if suppressIdleInputLossAlert && now >= suppressIdleInputLossUntil {
            suppressIdleInputLossAlert = false
        }
        // Windows' microphone privacy switch: nothing can be recorded until
        // the user turns it on, so say so instead of showing "(no input)".
        if engine.accessDenied, case .ready = state, !engine.engineHealthy, !engine.isRebuilding {
            state = .error(engine.lastOpenError ?? "Microphone access was denied.")
        }
    }

    // MARK: - Recording

    /// The RECORD/STOP button.
    public func toggleRecording() {
        switch state {
        case .recording:
            guard !isStopping else { return }
            stopRecording()
        case .ready, .selectingMic:
            guard canStartRecording else { return }
            startRecording()
        case .error:
            break
        }
    }

    public func startRecording() {
        diskStopReason = nil
        if let reason = DiskSpaceChecker.recordingBlockedReason(for: recordingsDirectory, format: outputFormat) {
            state = .error(reason)
            return
        }
        let url = RecordingFiles.makeRecordingURL(in: recordingsDirectory, prefix: filenameBase, format: outputFormat)
        do {
            try engine.startRecording(to: url, format: outputFormat, notes: notes)
        } catch {
            state = .error("Failed to start recording: \(error.localizedDescription)")
            return
        }
        recordedFileURL = url
        state = .recording
        let now = Platform.now()
        recordingStartedAt = now
        recordingTime = 0
        nextDiskCheck = now + Self.diskWatchInterval
        nextHealthCheck = now + Self.inputWatchInterval
    }

    private func checkDiskSpaceDuringRecording() {
        guard isCurrentlyRecording,
              let reason = DiskSpaceChecker.recordingBlockedReason(
                  for: recordingsDirectory, format: outputFormat, recordedSeconds: recordingTime)
        else { return }
        diskStopReason = reason
        stopRecording()
    }

    public static func diskStopNote(reason: String) -> String {
        "Recording stopped early. \(reason)"
    }

    /// Finishes the take. `completion` runs once the file is closed, or
    /// the stop has failed.
    public func stopRecording(completion: (() -> Void)? = nil) {
        let alreadyFinalizing = isFinalizingRecording
        isFinalizingRecording = true
        isStopping = true
        saveProgress = nil

        engine.stopRecording { [weak self] result in
            guard let self else { completion?(); return }
            // A second stop racing the first gets noActiveRecording; the
            // first one is saving the file, so this one stays quiet.
            if alreadyFinalizing, case .failure(let error) = result,
               case .noActiveRecording? = error as? RecordingError {
                completion?()
                return
            }
            let diskReason = self.diskStopReason
            self.diskStopReason = nil
            // The main file failed: re-wrap the sidecar into a WAV now, so
            // the guest leaves with a file rather than a relaunch
            // instruction. Off the main loop, under "SAVING…": a long take's
            // sidecar is gigabytes, and copying it here froze the window.
            if case .failure = result, let main = self.recordedFileURL,
               PCMSidecar.hasRecoverableContent(at: PCMSidecar.url(for: main)) {
                self.saveProgress = nil
                CrashRecovery.recover(sidecar: PCMSidecar.url(for: main), main: main) { [weak self] recovered in
                    guard let self else { completion?(); return }
                    self.finishStop(result, recovered: recovered, diskReason: diskReason, completion: completion)
                }
                return
            }
            self.finishStop(result, recovered: nil, diskReason: diskReason, completion: completion)
        }
    }

    /// The end of a stop: the take is saved, recovered (`recovered`), or
    /// lost, and the faceplate says which.
    private func finishStop(_ result: StopResult, recovered: Result<URL, Error>?, diskReason: String?,
                            completion: (() -> Void)?) {
        isFinalizingRecording = false
        isStopping = false
        saveProgress = nil
        recordingTime = 0
        let diskNote = diskReason.map { Self.diskStopNote(reason: $0) }

        switch result {
        case .success(.some(let url)):
            recordedFileURL = nil
            state = .ready
            presentSavedConfirmation(url, note: diskNote)
        case .success(.none):
            recordedFileURL = nil
            if let reason = pendingDisconnectReason {
                state = .error(Self.noAudioCapturedMessage(reason: reason))
            } else if let diskReason {
                state = .error(diskReason)
            } else {
                state = .ready
            }
        case .failure(let error):
            switch recovered {
            case .success(let url)?:
                recordedFileURL = nil
                if case .recording = state { state = .ready }
                presentSavedConfirmation(url, note: diskNote)
            case .failure(let recoveryError)?:
                state = .error("The recording couldn't be recovered: \(recoveryError.localizedDescription). The recovery file is still on disk — check disk space and permissions, then relaunch to retry.")
            case nil:
                let message = Self.stopFailureMessage(
                    for: error, mainOutput: recordedFileURL, disconnectReason: pendingDisconnectReason)
                state = .error(diskReason.map { "\($0) \(message)" } ?? message)
            }
        }
        pendingDisconnectReason = nil
        completion?()
        if quitWhenStopped {
            prepareForExit()
            shouldQuit = true
            return
        }
        if inputSwitchAfterStop {
            switchToFallbackInputAfterLoss()
        }
    }

    /// Quit without saving: the take's files are deleted.
    public func abortRecording(completion: (() -> Void)? = nil) {
        pendingDisconnectReason = nil
        diskStopReason = nil
        engine.cancelRecording { [weak self] in
            self?.recordingTime = 0
            self?.recordedFileURL = nil
            self?.state = .ready
            completion?()
        }
    }

    public static func noAudioCapturedMessage(reason: String?) -> String {
        let prefix = reason.map { "\($0). " } ?? ""
        return "\(prefix)No audio was captured — try again with a different microphone."
    }

    /// What the user is told when the main file couldn't be finished and
    /// its sidecar wasn't recovered on the spot.
    public static func stopFailureMessage(for error: Error, mainOutput: URL?, disconnectReason: String?) -> String {
        if let mainOutput, PCMSidecar.hasRecoverableContent(at: PCMSidecar.url(for: mainOutput)) {
            return "Recording was interrupted but your audio is safe. Quit and relaunch DoublEnder to recover it as a WAV file."
        }
        if case .noActiveRecording? = error as? RecordingError {
            return noAudioCapturedMessage(reason: disconnectReason)
        }
        let prefix = disconnectReason.map { "\($0). " } ?? ""
        return "\(prefix)Failed to finalize recording: \(error.localizedDescription)"
    }

    // MARK: - Errors

    /// TRY AGAIN.
    public func reset() {
        pendingDisconnectReason = nil
        diskStopReason = nil
        recordingTime = 0
        recordedFileURL = nil
        state = .ready
        if let device = engine.availableInputDevices.first(where: { $0.uid == selectedInputDeviceID }) {
            engine.setDevice(device)
        } else {
            switchToFallbackInputAfterLoss()
        }
    }

    // MARK: - Device changes

    private func handleTakeFailure(_ failure: CaptureFailure) {
        pendingDisconnectReason = failure.reason
        switch failure {
        case .inputLost(let reason):
            suppressIdleInputLossAlert = true
            stopRecording { [weak self] in
                guard let self else { return }
                self.presentDisconnectAlert(reason: reason)
                self.switchToFallbackInputAfterLoss()
                self.suppressIdleInputLossUntil = Platform.now() + 1
            }
        case .recordingFailed(let reason):
            // The mic is fine, so it stays selected.
            stopRecording { [weak self] in
                self?.presentRecordingFailedAlert(reason: reason)
            }
        }
    }

    private func handleDevicesChanged(added: [InputDevice]) {
        recordDevicesFirstSeen()
        // A device that was missing when picked may have come back.
        if !engine.engineHealthy, !engine.isRebuilding, !isCurrentlyRecording,
           engine.availableInputDevices.contains(where: { $0.uid == selectedInputDeviceID }) {
            selectInput(selectedInputDeviceID)
        }
        // Bluetooth earbuds connect on their own, often mid-call. Their mic
        // records at call quality (16 kHz), and opening it drops what the
        // guest hears to call quality too. They stay in the picker; they just
        // aren't offered.
        if let newest = added.last(where: { !$0.isBluetooth }) {
            presentNewDevicePrompt(for: newest)
        }
    }

    private func recordDevicesFirstSeen() {
        var map = settings.deviceFirstSeen
        let now = Date().timeIntervalSince1970
        var changed = false
        for device in engine.availableInputDevices where map[device.uid] == nil {
            map[device.uid] = now
            changed = true
        }
        if changed { settings.deviceFirstSeen = map }
    }

    private func mostRecentlyConnectedUSBDevice() -> InputDevice? {
        let map = settings.deviceFirstSeen
        return engine.availableInputDevices
            .filter(\.isUSB)
            .max { (map[$0.uid] ?? 0) < (map[$1.uid] ?? 0) }
    }

    /// Offers to switch to a mic that just appeared. Never during a take,
    /// never for the current input, once per device per session, and not on
    /// top of another dialog.
    private func presentNewDevicePrompt(for device: InputDevice) {
        guard !isCurrentlyRecording, !isStopping,
              device.uid != selectedInputDeviceID,
              !dismissedNewDevices.contains(device.uid),
              !dialogs.isShowing else { return }
        let uid = device.uid
        dialogs.present(Dialog(
            icon: .question, title: "MICROPHONE DETECTED",
            message: "Switch input to this device?",
            fileName: device.name,
            buttons: [
                .init("SWITCH", isDefault: true) { [weak self] in self?.selectInput(uid) },
                .init("KEEP CURRENT", isCancel: true) { [weak self] in self?.dismissedNewDevices.insert(uid) },
            ]))
    }

    private func shouldPresentInputLossAlert() -> Bool {
        let now = Platform.now()
        guard now - lastInputLossAlertAt >= Self.inputLossAlertCooldown else { return false }
        lastInputLossAlertAt = now
        return true
    }

    private func presentDisconnectAlert(reason: String) {
        guard shouldPresentInputLossAlert() else { return }
        dialogs.present(Dialog(
            icon: .warning, title: "MICROPHONE DISCONNECTED",
            message: "\(reason). Your recording has been stopped and saved if possible. Switched to the default microphone.",
            buttons: [.init("OK", isDefault: true)]))
    }

    private func presentRecordingFailedAlert(reason: String) {
        dialogs.present(Dialog(
            icon: .warning, title: "RECORDING STOPPED",
            message: "\(reason). What was recorded has been saved if possible.",
            buttons: [.init("OK", isDefault: true)]))
    }

    private func presentInputLostWhileIdleAlert() {
        guard shouldPresentInputLossAlert() else { return }
        dialogs.present(Dialog(
            icon: .warning, title: "MICROPHONE DISCONNECTED",
            message: "The selected input is no longer available. Switched to the default microphone.",
            buttons: [.init("OK", isDefault: true)]))
    }

    private func presentSavedConfirmation(_ url: URL, note: String?) {
        let place = RecordingFiles.locationName(for: url.deletingLastPathComponent())
        dialogs.present(Dialog(
            icon: .success, title: "DoublEnder",
            message: "Recording saved to \(place).",
            fileName: url.lastPathComponent,
            note: note,
            buttons: [
                .init("SHOW IN \(Platform.fileManagerName.uppercased())") { Platform.reveal(url) },
                .init("OK", isDefault: true),
            ]))
    }

    // MARK: - Quitting

    /// The window's close request, Ctrl+Q or the close button. A take in
    /// progress asks first, as ⌘Q does on the Mac.
    public func requestQuit() {
        if isStopping {
            quitWhenStopped = true
            return
        }
        guard isCurrentlyRecording else {
            prepareForExit()
            shouldQuit = true
            return
        }
        // Asked already: a second Alt+F4 doesn't stack another prompt.
        guard !dialogs.items.contains(where: { $0.id == quitPromptID }) else { return }
        let prompt = Dialog(
            icon: .warning, title: "RECORDING IN PROGRESS",
            message: "Stopping now will save what has been recorded so far. Quitting without saving will lose the current recording.",
            buttons: [
                .init("STOP & SAVE", isDefault: true) { [weak self] in
                    guard let self else { return }
                    if self.isCurrentlyRecording && !self.isStopping {
                        self.quitWhenStopped = true
                        self.stopRecording()
                    } else if self.isStopping {
                        // Already saving: quit when it's done.
                        self.quitWhenStopped = true
                    } else {
                        // The engine stopped and saved the take while the
                        // prompt was up; nothing is left to stop.
                        self.prepareForExit()
                        self.shouldQuit = true
                    }
                },
                .init("QUIT WITHOUT SAVING") { [weak self] in
                    guard let self else { return }
                    // The engine stopped the take while the prompt was up and
                    // it is being saved: let that finish rather than exit
                    // halfway through writing the file.
                    if self.isStopping {
                        self.quitWhenStopped = true
                        return
                    }
                    self.abortRecording {
                        self.prepareForExit()
                        self.shouldQuit = true
                    }
                },
                .init("CANCEL", isCancel: true),
            ])
        quitPromptID = prompt.id
        dialogs.present(prompt, first: true)
    }

    private func prepareForExit() {
        settings.filenameBase = ""
    }
}
