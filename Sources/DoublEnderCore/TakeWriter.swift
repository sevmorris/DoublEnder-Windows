import Foundation

public enum RecordingError: LocalizedError {
    case noActiveRecording
    case noInput
    case cannotCreateFile(String)
    case fileTooLarge
    case encoderMissing
    case encoderFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noActiveRecording: return "No recording in progress."
        case .noInput: return "No microphone is available."
        case .cannotCreateFile(let name): return "Couldn't create \(name)."
        case .fileTooLarge: return "The recording reached the 4 GB WAV size limit."
        case .encoderMissing: return "AAC encoding needs ffmpeg, which wasn't found."
        case .encoderFailed(let detail): return "AAC encoding failed (\(detail))."
        }
    }
}

/// Streams a 24-bit mono PCM WAV. The header's sizes stay zero until
/// `finalize`, so a crashed file reads as empty, as a crashed Mac WAV does,
/// and the sidecar beside it is what recovery uses.
final class WAVWriter {
    let url: URL
    private let handle: FileHandle
    private var dataBytes: UInt64 = 0
    private var scratch: [UInt8] = []

    init(url: URL, sampleRate: UInt32) throws {
        let header = WAVFile.header(format: .pcm24, sampleRate: sampleRate, channels: 1, dataSize: 0)
        guard FileManager.default.createFile(atPath: url.path, contents: header) else {
            throw RecordingError.cannotCreateFile(url.lastPathComponent)
        }
        do {
            handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        self.url = url
    }

    func append(_ samples: UnsafeBufferPointer<Float>) throws {
        let byteCount = samples.count * 3
        guard dataBytes + UInt64(byteCount) <= UInt64(UInt32.max) - 36 else {
            throw RecordingError.fileTooLarge
        }
        if scratch.count < byteCount { scratch = [UInt8](repeating: 0, count: byteCount) }
        for (i, sample) in samples.enumerated() {
            // Full scale is 2^23; +1.0 lands one step under it.
            let scaled = (Double(sample) * 8_388_608).rounded()
            let v = Int32(max(-8_388_608, min(8_388_607, scaled)))
            scratch[i * 3] = UInt8(truncatingIfNeeded: v)
            scratch[i * 3 + 1] = UInt8(truncatingIfNeeded: v >> 8)
            scratch[i * 3 + 2] = UInt8(truncatingIfNeeded: v >> 16)
        }
        try scratch.withUnsafeBufferPointer { buf in
            try handle.write(contentsOf: UnsafeRawBufferPointer(rebasing: UnsafeRawBufferPointer(buf)[0..<byteCount]))
        }
        dataBytes += UInt64(byteCount)
    }

    /// Writes the real sizes into the header and closes the file.
    func finalize() throws {
        let data = UInt32(dataBytes)
        var riff = Data(); riff.appendLE(36 &+ data)
        var dataSize = Data(); dataSize.appendLE(data)
        try handle.seek(toOffset: 4)
        try handle.write(contentsOf: riff)
        try handle.seek(toOffset: 40)
        try handle.write(contentsOf: dataSize)
        try handle.synchronize()
        try handle.close()
    }

    /// Closes without fixing up the header.
    func abandon() {
        try? handle.close()
    }
}

/// Encodes an AAC take from its sidecar with ffmpeg: 256 kbps mono at
/// 48 kHz, the Mac build's settings, with the notes as the description tag.
/// No platform the port runs on ships an AAC encoder Swift can reach
/// without one, so ffmpeg is looked for next to the app, then on PATH.
public enum AACEncoder {

    public static var ffmpegPath: String? { Platform.findExecutable("ffmpeg") }

    public static var isAvailable: Bool { ffmpegPath != nil }

    /// Writes `output` through a temporary name and renames it into place,
    /// so a finished M4A never coexists with a half-written one.
    ///
    /// `progress` gets the fraction encoded, 0…1, about twice a second, on
    /// this thread: ffmpeg's native encoder runs at roughly 12× real time on
    /// an older laptop, so a 35-minute take takes about 3 minutes to save.
    static func encode(sidecar: URL, sampleRate: Double, notes: String, to output: URL,
                       progress: ((Double) -> Void)? = nil) throws {
        guard let ffmpeg = ffmpegPath else { throw RecordingError.encoderMissing }
        let partial = output.deletingLastPathComponent()
            .appendingPathComponent(".\(output.lastPathComponent).part")
        let seconds = Double(max(0, (PCMSidecar.fileSize(sidecar) ?? 0) - Int64(PCMSidecar.headerSizeV2)))
            / 4 / max(1, sampleRate)

        func arguments(reportingProgress: Bool) -> [String] {
            var arguments = ["-hide_banner", "-nostdin", "-loglevel", "error", "-y"]
            if reportingProgress { arguments += ["-nostats", "-progress", "pipe:1"] }
            arguments += [
                "-f", "f32le", "-ar", String(Int(sampleRate.rounded())), "-ac", "1",
                "-skip_initial_bytes", String(PCMSidecar.headerSizeV2),
                "-i", sidecar.path,
                "-c:a", "aac", "-b:a", "256k", "-ar", "48000", "-ac", "1",
            ]
            let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedNotes.isEmpty {
                arguments += ["-metadata", "description=\(trimmedNotes)"]
            }
            return arguments + ["-f", "ipod", partial.path]
        }

        try? FileManager.default.removeItem(at: partial)
        var run = try runFFmpeg(ffmpeg, arguments(reportingProgress: progress != nil), seconds: seconds, progress: progress)
        // An ffmpeg without the pipe protocol (an older build beside the
        // app, say) refuses -progress pipe:1 before it starts. Encode
        // without the percentage rather than fail the save.
        if run.status != 0, progress != nil, run.message.contains("progress URL") {
            Log.info("ffmpeg can't report progress; encoding without it")
            try? FileManager.default.removeItem(at: partial)
            run = try runFFmpeg(ffmpeg, arguments(reportingProgress: false), seconds: seconds, progress: nil)
        }
        guard run.status == 0, MP4File.isFinished(partial) else {
            try? FileManager.default.removeItem(at: partial)
            let detail = run.message.split(whereSeparator: \.isNewline).last.map(String.init) ?? "exit \(run.status)"
            throw RecordingError.encoderFailed(detail)
        }
        try FileManager.default.moveItem(at: partial, to: output)
    }

    /// Runs ffmpeg to the end. Returns its exit status and what it wrote to
    /// stderr; its stdout carries `-progress` blocks when asked for.
    private static func runFFmpeg(_ ffmpeg: String, _ arguments: [String], seconds: Double,
                                  progress: ((Double) -> Void)?) throws -> (status: Int32, message: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = arguments
        let errors = Pipe()
        let report = Pipe()
        process.standardError = errors
        process.standardOutput = report
        do {
            try process.run()
        } catch {
            throw RecordingError.encoderFailed("couldn't start ffmpeg")
        }
        // stderr is read on its own thread, so neither pipe can fill up and
        // stall ffmpeg while the other is being read.
        let stderr = PipeDrain(errors)
        readProgress(report, seconds: seconds, into: progress)
        let message = String(decoding: stderr.wait(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus, message)
    }

    /// Reads ffmpeg's `-progress` blocks until it closes the pipe, passing on
    /// `out_time_us` as a fraction of the take's `seconds`.
    private static func readProgress(_ pipe: Pipe, seconds: Double, into progress: ((Double) -> Void)?) {
        let key = "out_time_us="
        var pending = Data()
        while true {
            let chunk = pipe.fileHandleForReading.availableData
            if chunk.isEmpty { return }
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
                pending.removeSubrange(pending.startIndex...newline)
                guard let progress, seconds > 0, line.hasPrefix(key),
                      let microseconds = Double(line.dropFirst(key.count)) else { continue }
                progress(min(1, max(0, microseconds / 1_000_000 / seconds)))
            }
        }
    }
}

/// Reads a pipe to its end on a background thread; `wait()` returns it all.
private final class PipeDrain {
    private var data = Data()
    private let done = DispatchSemaphore(value: 0)

    init(_ pipe: Pipe) {
        DispatchQueue.global(qos: .utility).async { [self] in
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
    }

    func wait() -> Data {
        done.wait()
        return data
    }
}

/// One take's files, written from the engine's pump thread only.
///
/// WAV: the 24-bit WAV and the Float32 sidecar side by side; stopping
/// finalizes the WAV and deletes the sidecar. AAC: only the sidecar while
/// recording; stopping encodes the M4A from it, then deletes it. Either way
/// a failure leaves the sidecar for recovery.
final class TakeWriter {
    let mainURL: URL
    let format: OutputFormat
    let notes: String
    let sampleRate: Double
    private var wav: WAVWriter?
    private(set) var sidecar: PCMSidecar?
    private(set) var framesWritten: Int64 = 0
    /// The sidecar stopped taking writes (WAV takes carry on without it).
    private(set) var sidecarFailed = false

    /// Opens the take's files. An AAC take can't run without its sidecar; a
    /// WAV take records without one, flagged so the faceplate can say so.
    init(mainURL: URL, format: OutputFormat, notes: String, sampleRate: Double) throws {
        self.mainURL = mainURL
        self.format = format
        self.notes = notes
        self.sampleRate = sampleRate
        switch format {
        case .aac:
            sidecar = try PCMSidecar(mainOutput: mainURL, sampleRate: sampleRate)
        case .wav:
            wav = try WAVWriter(url: mainURL, sampleRate: UInt32(sampleRate.rounded()))
            do {
                sidecar = try PCMSidecar(mainOutput: mainURL, sampleRate: sampleRate)
            } catch {
                Log.error("Crash-recovery sidecar unavailable: \(error)")
                sidecarFailed = true
            }
        }
    }

    var sidecarUnavailable: Bool { format == .wav && sidecar == nil }

    /// Throws when the take can't continue: the main file failed, or for
    /// AAC, the sidecar that is its only copy.
    func write(_ samples: UnsafeBufferPointer<Float>) throws {
        if let wav { try wav.append(samples) }
        if let sidecar, !sidecarFailed {
            do {
                try sidecar.append(samples)
            } catch {
                sidecarFailed = true
                if format == .aac { throw error }
                Log.error("Sidecar write failed; WAV take continues: \(error)")
            }
        }
        framesWritten += Int64(samples.count)
    }

    enum Outcome {
        case saved(URL)
        case nothingWritten
        case failed(Error)
    }

    /// Finishes the take. Slow for AAC (it encodes), so not on the pump;
    /// `progress` follows the encode (see `AACEncoder.encode`).
    func finish(progress: ((Double) -> Void)? = nil) -> Outcome {
        if framesWritten == 0 {
            wav?.abandon()
            try? FileManager.default.removeItem(at: mainURL)
            sidecar?.discard()
            return .nothingWritten
        }
        switch format {
        case .wav:
            do {
                try wav?.finalize()
                sidecar?.discard()
                return .saved(mainURL)
            } catch {
                sidecar?.close()
                return .failed(error)
            }
        case .aac:
            guard let sidecar else { return .failed(RecordingError.noActiveRecording) }
            sidecar.close()
            do {
                try AACEncoder.encode(sidecar: sidecar.url, sampleRate: sampleRate, notes: notes, to: mainURL,
                                      progress: progress)
                try? FileManager.default.removeItem(at: sidecar.url)
                return .saved(mainURL)
            } catch {
                return .failed(error)
            }
        }
    }

    /// Discards everything: the user quit without saving.
    func cancel() {
        wav?.abandon()
        try? FileManager.default.removeItem(at: mainURL)
        sidecar?.discard()
    }
}
