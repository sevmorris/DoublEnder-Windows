import CMiniaudio
import Foundation

/// A capture device the picker can offer.
public struct InputDevice: Equatable {
    /// Stable per device and backend; what selection and settings key on.
    public let uid: String
    public let name: String
    public let isDefault: Bool
    /// What it is plugged into, for the "you plugged in a mic" offers.
    public let bus: Bus
    let idBytes: [UInt8]

    public enum Bus {
        case usb
        case bluetooth
        case other
    }

    public var isUSB: Bool { bus == .usb }
    public var isBluetooth: Bool { bus == .bluetooth }

    public static func == (a: InputDevice, b: InputDevice) -> Bool {
        a.uid == b.uid && a.name == b.name && a.isDefault == b.isDefault
    }

    /// Windows: the controller's Plug and Play instance ID says
    /// (`de_context_device_controller`); every Bluetooth enumerator's name
    /// starts BTH (BTHENUM, BTHHFENUM, BTHLEDEVICE). Linux: PulseAudio and
    /// PipeWire name sources "bluez_input.…" and "alsa_input.usb-…".
    /// Otherwise the name, which is only a hint.
    static func bus(name: String, idText: String, controllerID: String) -> Bus {
        let controller = controllerID.uppercased()
        if controller.hasPrefix("BTH") { return .bluetooth }
        if controller.hasPrefix("USB\\") { return .usb }
        if !controller.isEmpty { return .other }
        let id = idText.lowercased()
        if id.hasPrefix("bluez") || id.contains("bluealsa") { return .bluetooth }
        if id.contains("usb") || name.lowercased().contains("usb") { return .usb }
        return .other
    }
}

/// What the open device delivers, for the meter and diagnostics.
public struct CaptureFormat {
    public let sampleRate: Double
    public let channels: Int
    public let sampleFormat: SampleFormat
    public let channelMap: [UInt8]
    let gains: [Float]
}

/// Why the engine stopped a take. The reason is user-facing.
public enum CaptureFailure {
    /// The input went away or went quiet: unplugged, no audio, stopped.
    case inputLost(String)
    /// The input is fine but the take couldn't continue: a file write
    /// failed (a full disk, the WAV size limit) or audio was dropped.
    case recordingFailed(String)

    public var reason: String {
        switch self {
        case .inputLost(let reason), .recordingFailed(let reason): return reason
        }
    }
}

/// Result of stopping a take: `.success(url)` saved, `.success(nil)` no
/// audio reached the file, `.failure` the main file could not be finished
/// (its sidecar, if it holds audio, is still on disk).
public typealias StopResult = Result<URL?, Error>

/// Owns capture. The cross-platform counterpart of the Mac build's
/// AudioEngine: it knows nothing about UI or app state, publishes flags the
/// controller reads, and reports failures through callbacks on the main
/// loop.
///
/// Threads:
///   - miniaudio's real-time thread copies native frames into a ring buffer
///     (de_audio.c) and nothing else;
///   - the pump thread drains the ring, mixes to mono, drives the meter,
///     hands the take's audio to `TakeIO` and runs the watchdogs; it never
///     waits on the disk;
///   - `ioQueue` writes the take's files, in order (`TakeIO`);
///   - `deviceQueue` opens and closes devices and enumerates them, which
///     can block for a moment on some backends;
///   - everything public is called on the main loop, and callbacks arrive
///     there through `MainQueue`.
public final class AudioEngine {

    // MARK: Main-loop state

    public private(set) var availableInputDevices: [InputDevice] = []
    /// A device is open and running.
    public private(set) var engineHealthy = false
    /// False when the last pick could not be opened; the previous device
    /// stays bound, as on the Mac, but RECORD stays off until a good pick.
    public private(set) var selectedDeviceUsable = true
    public private(set) var isRebuilding = false
    public private(set) var boundDeviceUID: String?
    /// Why the last open failed, for the error state.
    public private(set) var lastOpenError: String?
    public private(set) var accessDenied = false
    public let backendName: String

    /// The engine stopped a take. Fires at most once per take.
    public var onTakeFailed: ((CaptureFailure) -> Void)?
    /// While a stopped AAC take encodes: the fraction done, 0…1, each time
    /// it passes a whole percent.
    public var onSaveProgress: ((Double) -> Void)?
    /// The device list changed; `added` excludes the first enumeration.
    public var onDevicesChanged: ((_ added: [InputDevice]) -> Void)?
    /// The bound device vanished while no take was running.
    public var onActiveInputLostWhileIdle: (() -> Void)?

    // MARK: Pump-shared state, under `lock`

    private let lock = NSLock()
    private var capture: OpaquePointer?
    private var format: CaptureFormat?
    private var take: TakeIO<TakeWriter>?
    private var takeStartedAt: Double = 0
    private var pendingEnd: (cancel: Bool, completion: (StopResult) -> Void)?
    private var meterDB: Float = LevelMeter.dbFloor
    private var lastDataAt: Double = 0
    private var captureOpenedAt: Double = 0
    private var droppedAtTakeStart: UInt64 = 0
    private var droppedFrameWarningFlag = false
    private var sidecarFailedFlag = false
    private var sidecarUnavailableFlag = false
    /// First failure path wins; the rest stand down for the take.
    private var disconnectStopPending = false
    private var idleStopNoticed = false
    private var pumpRunning = true

    private let context: OpaquePointer?
    private let deviceQueue = DispatchQueue(label: "DoublEnder.devices")
    private let finishQueue = DispatchQueue(label: "DoublEnder.finish", qos: .userInitiated)
    private let ioQueue = DispatchQueue(label: "DoublEnder.io", qos: .userInitiated)
    private var pump: Thread?
    private var knownUIDs: Set<String>?
    /// Controller IDs by device uid; `deviceQueue` only.
    private var controllerIDs: [String: String] = [:]

    static let firstBufferTimeout: Double = 5
    static let dataFlowTimeout: Double = 3
    static let ringSeconds: UInt32 = 10
    /// A take fails once this much audio has been dropped in total.
    static let droppedFailureSeconds: Double = 1

    public convenience init() {
        self.init(nullBackend: false)
    }

    /// `nullBackend`: miniaudio's null backend, whose one input delivers
    /// silence at real time. Tests record through the whole engine with it,
    /// on any machine.
    init(nullBackend: Bool) {
        context = nullBackend ? de_context_create_null() : de_context_create()
        backendName = context.map { String(cString: de_context_backend_name($0)) } ?? "none"
        let thread = Thread { [weak self] in self?.pumpLoop() }
        thread.name = "DoublEnder.pump"
        thread.qualityOfService = .userInteractive
        pump = thread
        thread.start()
    }

    /// Stops the pump and closes the device. Call once, at exit.
    public func shutdown() {
        lock.lock()
        pumpRunning = false
        let cap = capture
        capture = nil
        lock.unlock()
        deviceQueue.sync {
            de_capture_close(cap)
            if let context { de_context_destroy(context) }
        }
    }

    public var hasAudioBackend: Bool { context != nil }

    // MARK: - Readouts for the faceplate

    public var meterLevel: Float { locked { meterDB } }

    /// Audio reached the file within the last 150 ms.
    public var isWritingData: Bool {
        guard let take = locked({ take }) else { return false }
        return Platform.now() - take.lastWrite < 0.15
    }

    /// Seconds of the take captured but not yet on disk: a slow disk.
    public var writeBacklogSeconds: Double {
        guard let take = locked({ take }), let rate = currentFormat?.sampleRate, rate > 0 else { return 0 }
        return Double(take.backlogFrames) / rate
    }

    public var isRecordingActive: Bool { locked { take != nil } }
    public var droppedFrameWarning: Bool { locked { droppedFrameWarningFlag } }
    public var sidecarFailedDuringRecording: Bool { locked { sidecarFailedFlag } }
    public var sidecarUnavailable: Bool { locked { sidecarUnavailableFlag } }
    public var currentFormat: CaptureFormat? { locked { format } }

    /// Open, but nothing has arrived for a while outside a take.
    public var inputStalled: Bool {
        locked {
            guard capture != nil, take == nil else { return false }
            let now = Platform.now()
            return now - captureOpenedAt > Self.dataFlowTimeout && now - lastDataAt > Self.dataFlowTimeout
        }
    }

    // MARK: - Devices

    /// Re-reads the device list. Device changes while a take runs are the
    /// watchdogs' business, so `onDevicesChanged` is held back then.
    public func refreshDevices(completion: (() -> Void)? = nil) {
        guard let context else { completion?(); return }
        deviceQueue.async { [weak self] in
            let devices = self?.enumerate(context)
            MainQueue.post {
                self?.applyDeviceList(devices)
                completion?()
            }
        }
    }

    /// Runs on `deviceQueue`.
    private func enumerate(_ context: OpaquePointer) -> [InputDevice]? {
        let capacity = 128
        var entries = [de_device_entry](repeating: de_device_entry(), count: capacity)
        let count = Int(de_context_capture_devices(context, &entries, Int32(capacity)))
        guard count >= 0 else { return nil }
        return entries.prefix(count).compactMap { entry in
            let name = Self.cString(entry.name)
            let uid = Self.cString(entry.uid)
            let idBytes = withUnsafeBytes(of: entry.id) { Array($0) }
            // The backend's own id text, where it is text (PulseAudio, ALSA).
            let idText = String(decoding: idBytes.prefix { $0 != 0 }, as: UTF8.self)
            guard !name.isEmpty, !Self.isLoopback(name: name, idText: idText) else { return nil }
            let bus = InputDevice.bus(name: name, idText: idText,
                                      controllerID: controllerID(of: entry, uid: uid, context: context))
            return InputDevice(uid: uid, name: name, isDefault: entry.isDefault != 0, bus: bus, idBytes: idBytes)
        }
    }

    /// What `de_context_device_controller` says about a device, asked once
    /// per device: on Windows it walks the device topology, and the list is
    /// re-read every second or two. Runs on `deviceQueue`.
    private func controllerID(of entry: de_device_entry, uid: String, context: OpaquePointer) -> String {
        if let known = controllerIDs[uid] { return known }
        var id = entry.id
        var buffer = [CChar](repeating: 0, count: 512)
        de_context_device_controller(context, &id, &buffer, buffer.count)
        let controller = String(cString: buffer)
        controllerIDs[uid] = controller
        return controller
    }

    /// Loopback "inputs" that record the computer's output, not a mic:
    /// PulseAudio/PipeWire monitor sources and Windows Stereo Mix. The Mac
    /// build hides virtual devices from the picker for the same reason.
    static func isLoopback(name: String, idText: String) -> Bool {
        name.hasPrefix("Monitor of ") || idText.hasSuffix(".monitor")
            || name.localizedCaseInsensitiveContains("Stereo Mix")
    }

    private func applyDeviceList(_ devices: [InputDevice]?) {
        guard let devices else { return }
        let changed = devices != availableInputDevices
        availableInputDevices = devices
        let uids = Set(devices.map(\.uid))
        let added: [InputDevice]
        if let known = knownUIDs {
            added = devices.filter { !known.contains($0.uid) }
        } else {
            added = []  // launch-time devices are not new arrivals
        }
        // Updated before the callback, so a re-entrant refresh while a
        // prompt is up doesn't offer the same device twice.
        knownUIDs = (knownUIDs ?? []).union(uids)

        let recording = isRecordingActive
        if let bound = boundDeviceUID, !uids.contains(bound) {
            if recording {
                triggerCaptureFailure(.inputLost("The microphone was disconnected"))
            } else if engineHealthy {
                closeCapture()
                onActiveInputLostWhileIdle?()
            }
        }
        if !recording && (changed || !added.isEmpty) {
            onDevicesChanged?(added)
        }
    }

    /// The system default input, else the first one.
    public func defaultInputDevice() -> InputDevice? {
        availableInputDevices.first(where: \.isDefault) ?? availableInputDevices.first
    }

    // MARK: - Opening a device

    /// Binds `device` (nil = system default). Refused during a take.
    public func setDevice(_ device: InputDevice?) {
        guard let context, !isRecordingActive else { return }
        isRebuilding = true
        let idBytes = device?.idBytes
        deviceQueue.async { [weak self] in
            guard let self else { return }
            var cap: OpaquePointer?
            var result: ma_result
            if let idBytes {
                var id = ma_device_id()
                withUnsafeMutableBytes(of: &id) { dst in
                    dst.copyBytes(from: idBytes.prefix(dst.count))
                }
                result = de_capture_open(context, &id, Self.ringSeconds, &cap)
            } else {
                result = de_capture_open(context, nil, Self.ringSeconds, &cap)
            }
            if result == MA_SUCCESS, let opened = cap {
                result = de_capture_start(opened)
                if result != MA_SUCCESS { de_capture_close(opened); cap = nil }
            }
            if result == MA_SUCCESS, let opened = cap {
                let format = Self.readFormat(opened)
                self.lock.lock()
                let old = self.capture
                self.capture = opened
                self.format = format
                self.meterDB = LevelMeter.dbFloor
                let now = Platform.now()
                self.captureOpenedAt = now
                self.lastDataAt = now
                self.idleStopNoticed = false
                self.lock.unlock()
                de_capture_close(old)
                Log.info("Input: \(device?.name ?? "the system default"), \(Int(format.sampleRate)) Hz, \(format.channels) ch, \(format.sampleFormat.diagnosticName) (\(self.backendName))")
                MainQueue.post {
                    self.isRebuilding = false
                    self.engineHealthy = true
                    self.selectedDeviceUsable = true
                    self.accessDenied = false
                    self.lastOpenError = nil
                    self.boundDeviceUID = device?.uid ?? self.defaultInputDevice()?.uid
                }
            } else {
                let denied = result == MA_ACCESS_DENIED
                let message = denied
                    ? Self.accessDeniedMessage
                    : "Couldn't open \(device?.name ?? "the microphone") (\(String(cString: ma_result_description(result))))."
                Log.error("Opening input failed: \(message)")
                MainQueue.post {
                    self.isRebuilding = false
                    self.lastOpenError = message
                    self.accessDenied = denied
                    if self.locked({ self.capture != nil }) {
                        self.selectedDeviceUsable = false
                    } else {
                        self.engineHealthy = false
                    }
                }
            }
        }
    }

    static var accessDeniedMessage: String {
        Platform.isWindows
            ? "Microphone access is turned off. Open Settings → Privacy & security → Microphone, turn on \"Let desktop apps access your microphone\", then try again."
            : "Microphone access was denied by the system."
    }

    private static func readFormat(_ cap: OpaquePointer) -> CaptureFormat {
        let channels = Int(de_capture_channels(cap))
        var map = [ma_channel](repeating: 0, count: max(channels, 1))
        _ = de_capture_channel_map(cap, &map, UInt32(map.count))
        let sampleFormat = SampleFormat(rawValue: Int(de_capture_format(cap).rawValue)) ?? .f32
        let channelMap = Array(map.prefix(channels))
        return CaptureFormat(
            sampleRate: Double(de_capture_sample_rate(cap)), channels: channels,
            sampleFormat: sampleFormat, channelMap: channelMap,
            gains: MonoMix.gains(channelMap: channelMap))
    }

    private func closeCapture() {
        lock.lock()
        let cap = capture
        capture = nil
        format = nil
        meterDB = LevelMeter.dbFloor
        lock.unlock()
        engineHealthy = false
        boundDeviceUID = nil
        deviceQueue.async { de_capture_close(cap) }
    }

    // MARK: - Takes

    /// Opens the take's files and starts writing from the next buffer.
    public func startRecording(to url: URL, format outputFormat: OutputFormat, notes: String) throws {
        guard let format = currentFormat, engineHealthy else { throw RecordingError.noInput }
        let writer = try TakeWriter(mainURL: url, format: outputFormat, notes: notes,
                                    sampleRate: format.sampleRate)
        lock.lock()
        take = TakeIO(sink: writer, queue: ioQueue)
        takeStartedAt = Platform.now()
        droppedAtTakeStart = capture.map { de_capture_frames_dropped($0) } ?? 0
        droppedFrameWarningFlag = false
        sidecarFailedFlag = false
        sidecarUnavailableFlag = writer.sidecarUnavailable
        disconnectStopPending = false
        pendingEnd = nil
        lock.unlock()
    }

    /// Finishes the take: the pump drains what is buffered, the I/O queue
    /// writes what it was handed, then the files are finalized off the pump
    /// (AAC encodes). `completion` runs on the main loop.
    public func stopRecording(completion: @escaping (StopResult) -> Void) {
        endTake(cancel: false, completion: completion)
    }

    /// Discards the take and its files.
    public func cancelRecording(completion: @escaping () -> Void) {
        endTake(cancel: true) { _ in completion() }
    }

    private func endTake(cancel: Bool, completion: @escaping (StopResult) -> Void) {
        lock.lock()
        guard take != nil, pendingEnd == nil else {
            lock.unlock()
            MainQueue.post { completion(.failure(RecordingError.noActiveRecording)) }
            return
        }
        pendingEnd = (cancel, completion)
        lock.unlock()
    }

    /// Called every second during a take: re-reads the device list, which
    /// fails the take if the bound device has gone.
    public func checkRecordingInputHealth() {
        refreshDevices()
    }

    // MARK: - Pump

    private func pumpLoop() {
        var raw = [UInt8](repeating: 0, count: 1 << 16)
        var mono = [Float](repeating: 0, count: 1 << 16)
        var meterBlockPeak: Float = 0
        var meterBlockFrames = 0
        var smoothed = LevelMeter.dbFloor
        var lastReadAt = Platform.now()

        while true {
            lock.lock()
            if !pumpRunning { lock.unlock(); return }
            let cap = capture
            let format = self.format
            let activeTake = take
            let end = pendingEnd
            var bytes = 0
            var notifications: UInt32 = 0
            var dropped: UInt64 = 0
            if let cap {
                bytes = raw.withUnsafeMutableBytes { de_capture_read(cap, $0.baseAddress, $0.count) }
                notifications = de_capture_take_notifications(cap)
                dropped = de_capture_frames_dropped(cap)
            }
            lock.unlock()

            let now = Platform.now()
            if cap != nil {
                activeTake?.noteDrain(gap: now - lastReadAt)
                lastReadAt = now
            }
            if bytes > 0, let format {
                let frames = raw.withUnsafeBytes { rawBuf in
                    mono.withUnsafeMutableBufferPointer { out in
                        MonoMix.mix(UnsafeRawBufferPointer(rebasing: rawBuf[0..<bytes]),
                                    format: format.sampleFormat, channels: format.channels,
                                    gains: format.gains, into: out.baseAddress!)
                    }
                }
                // Meter: per-block peaks with the Mac's ballistics.
                let blockFrames = max(1, Int(format.sampleRate * LevelMeter.ballisticsBlockSeconds))
                for i in 0..<frames {
                    meterBlockPeak = max(meterBlockPeak, abs(mono[i]))
                    meterBlockFrames += 1
                    if meterBlockFrames >= blockFrames {
                        let instant = LevelMeter.clampedDisplayDB(fromLinear: meterBlockPeak)
                        let coef = instant > smoothed ? LevelMeter.peakAttack : LevelMeter.peakRelease
                        smoothed += coef * (instant - smoothed)
                        meterBlockPeak = 0
                        meterBlockFrames = 0
                    }
                }
                // Handed over, not written: the disk never holds up the ring.
                mono.withUnsafeBufferPointer { buf in
                    activeTake?.enqueue(UnsafeBufferPointer(rebasing: buf[0..<frames]))
                }
                lock.lock()
                meterDB = smoothed
                lastDataAt = now
                lock.unlock()
            }
            if let activeTake {
                if activeTake.sidecarFailed {
                    lock.lock(); sidecarFailedFlag = true; lock.unlock()
                }
                if let writeError = activeTake.error {
                    triggerCaptureFailure(.recordingFailed("Writing the recording failed (\(writeError.localizedDescription))"))
                }
            }

            if let end, let activeTake, bytes == 0 {
                // The ring is drained: everything captured before STOP is in.
                finishTake(activeTake, end: end)
                continue
            }

            if let activeTake, end == nil {
                runWatchdogs(take: activeTake, now: now, notifications: notifications, dropped: dropped)
            } else if notifications & UInt32(DE_NOTE_STOPPED) != 0 {
                lock.lock()
                let first = !idleStopNoticed
                idleStopNoticed = true
                lock.unlock()
                if first {
                    MainQueue.post { [weak self] in self?.refreshDevices() }
                }
            }

            if bytes == 0 {
                Thread.sleep(forTimeInterval: cap == nil ? 0.02 : 0.005)
            }
        }
    }

    private func finishTake(_ activeTake: TakeIO<TakeWriter>, end: (cancel: Bool, completion: (StopResult) -> Void)) {
        lock.lock()
        take = nil
        pendingEnd = nil
        disconnectStopPending = false
        // At the stop: an AAC take's encode, below, isn't recording time.
        let seconds = Platform.now() - takeStartedAt
        let dropped = capture.map { de_capture_frames_dropped($0) &- droppedAtTakeStart } ?? 0
        let format = self.format
        lock.unlock()
        finishQueue.async { [weak self] in
            // Everything the pump handed over reaches the files first.
            activeTake.drain()
            let writer = activeTake.sink
            let result: StopResult
            if end.cancel {
                writer.cancel()
                result = .success(nil)
            } else {
                var lastPercent = -1
                let report: (Double) -> Void = { fraction in
                    let percent = Int(fraction * 100)
                    guard percent != lastPercent else { return }
                    lastPercent = percent
                    MainQueue.post { self?.onSaveProgress?(fraction) }
                }
                switch writer.finish(progress: report) {
                case .saved(let url): result = .success(url)
                case .nothingWritten: result = .success(nil)
                case .failed(let error): result = .failure(error)
                }
            }
            Log.info(Self.takeReport(activeTake, result: result, cancelled: end.cancel, format: format,
                                     seconds: seconds, dropped: dropped))
            MainQueue.post { end.completion(result) }
        }
    }

    /// One line per take, so a guest's log says what the input delivered and
    /// whether anything held the capture or the disk up.
    static func takeReport(_ take: TakeIO<TakeWriter>, result: StopResult, cancelled: Bool,
                           format: CaptureFormat?, seconds: Double, dropped: UInt64) -> String {
        let outcome: String
        switch result {
        case .success(.some): outcome = "saved"
        case .success(.none): outcome = cancelled ? "discarded" : "nothing recorded"
        case .failure(let error): outcome = "failed (\(error.localizedDescription))"
        }
        let input = format.map { "\(Int($0.sampleRate)) Hz \($0.channels) ch \($0.sampleFormat.diagnosticName)" } ?? "no input"
        let rate = format?.sampleRate ?? 48_000
        let io = take.ioSummary
        let sidecar = take.sink.sidecar.map { "\($0.syncCount) syncs, slowest \(ms($0.longestSync))" } ?? "no sidecar"
        return "Take \(outcome): \(String(format: "%.1f", seconds)) s, \(take.sink.format.rawValue), \(input); "
            + "dropped \(dropped) frames; longest wait between ring reads \(ms(take.longestDrainGap)); "
            + "slowest write \(ms(io.longestWrite)), largest backlog \(ms(Double(io.largestBacklogFrames) / rate)); "
            + "sidecar \(sidecar)"
    }

    private static func ms(_ seconds: Double) -> String { "\(Int((seconds * 1000).rounded())) ms" }

    private func runWatchdogs(take: TakeIO<TakeWriter>, now: Double, notifications: UInt32, dropped: UInt64) {
        let (startedAt, lastData, droppedAtStart, sampleRate) = locked {
            (takeStartedAt, lastDataAt, droppedAtTakeStart, format?.sampleRate ?? 48_000)
        }
        // Watchdog 4: armed at record start, met by the first captured sample.
        if take.framesEnqueued == 0, now - startedAt > Self.firstBufferTimeout {
            triggerCaptureFailure(.inputLost("The microphone delivered no audio"))
            return
        }
        // Watchdog 2: data stopped arriving mid-take.
        if take.framesEnqueued > 0, now - lastData > Self.dataFlowTimeout {
            triggerCaptureFailure(.inputLost("The microphone stopped delivering audio"))
            return
        }
        // The backend stopped the device: unplugged, or the server went away.
        if notifications & UInt32(DE_NOTE_STOPPED) != 0 {
            triggerCaptureFailure(.inputLost("The microphone was disconnected"))
            return
        }
        // The pump fell behind and the ring overflowed.
        let droppedThisTake = dropped &- droppedAtStart
        if droppedThisTake > 0 {
            lock.lock(); droppedFrameWarningFlag = true; lock.unlock()
            if Double(droppedThisTake) > sampleRate * Self.droppedFailureSeconds {
                triggerCaptureFailure(.recordingFailed("Audio was dropped — the computer couldn't keep up"))
            }
        }
    }

    /// The disconnect latch: the first failure path of a take wins, and the
    /// controller hears about it exactly once.
    private func triggerCaptureFailure(_ failure: CaptureFailure) {
        lock.lock()
        guard take != nil, pendingEnd == nil, !disconnectStopPending else {
            lock.unlock()
            return
        }
        disconnectStopPending = true
        lock.unlock()
        Log.error("Take stopped by engine: \(failure.reason)")
        MainQueue.post { [weak self] in self?.onTakeFailed?(failure) }
    }

    // MARK: - Helpers

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    static func cString<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
