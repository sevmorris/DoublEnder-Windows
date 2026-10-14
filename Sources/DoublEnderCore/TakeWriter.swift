import CPlatform
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

    /// Where an M4A is written until it is finished, beside its final name.
    static func partialURL(for output: URL) -> URL {
        output.deletingLastPathComponent().appendingPathComponent(".\(output.lastPathComponent).part")
    }

    /// Everything after the input: 256 kbps mono AAC at 48 kHz in an M4A,
    /// the notes as its description tag, written to `partial`. Shared by
    /// this encode and the live one (`LiveEncoder`).
    static func outputArguments(notes: String, to partial: URL) -> [String] {
        var arguments = ["-c:a", "aac", "-b:a", "256k", "-ar", "48000", "-ac", "1"]
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedNotes.isEmpty {
            arguments += ["-metadata", "description=\(trimmedNotes)"]
        }
        return arguments + ["-f", "ipod", partial.path]
    }

    /// Encodes the take from its sidecar: the fallback when the live
    /// encoder couldn't finish the M4A. Writes `output` through a temporary
    /// name and renames it into place, so a finished M4A never coexists with
    /// a half-written one.
    ///
    /// `progress` gets the fraction encoded, 0…1, about twice a second, on
    /// this thread: ffmpeg's native encoder runs at roughly 12× real time on
    /// an older laptop, so a 35-minute take takes about 3 minutes.
    static func encode(sidecar: URL, sampleRate: Double, notes: String, to output: URL,
                       progress: ((Double) -> Void)? = nil) throws {
        guard let ffmpeg = ffmpegPath else { throw RecordingError.encoderMissing }
        let partial = partialURL(for: output)
        let seconds = Double(max(0, (PCMSidecar.fileSize(sidecar) ?? 0) - Int64(PCMSidecar.headerSizeV2)))
            / 4 / max(1, sampleRate)

        func arguments(reportingProgress: Bool) -> [String] {
            var arguments = ["-hide_banner", "-nostdin", "-loglevel", "error", "-y"]
            if reportingProgress { arguments += ["-nostats", "-progress", "pipe:1"] }
            return arguments + [
                "-f", "f32le", "-ar", String(Int(sampleRate.rounded())), "-ac", "1",
                "-skip_initial_bytes", String(PCMSidecar.headerSizeV2),
                "-i", sidecar.path,
            ] + outputArguments(notes: notes, to: partial)
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
            throw RecordingError.encoderFailed(lastLine(of: run.message) ?? "exit \(run.status)")
        }
        try FileManager.default.moveItem(at: partial, to: output)
    }

    /// ffmpeg's last line of complaint, for an error message.
    static func lastLine(of message: String) -> String? {
        message.split(whereSeparator: \.isNewline).last.map(String.init)
    }

    /// Runs ffmpeg to the end, through `ChildProcess` so Windows shows no
    /// console window. Returns its exit status and what it wrote to stderr;
    /// its stdout carries `-progress` blocks when asked for.
    private static func runFFmpeg(_ ffmpeg: String, _ arguments: [String], seconds: Double,
                                  progress: ((Double) -> Void)?) throws -> (status: Int32, message: String) {
        let child: ChildProcess
        do {
            child = try ChildProcess(ffmpeg, arguments)
        } catch {
            throw RecordingError.encoderFailed("couldn't start ffmpeg")
        }
        child.closeInput()  // it reads the sidecar, never stdin
        // stderr is read on its own thread, so neither pipe can fill up and
        // stall ffmpeg while the other is being read.
        let stderr = PipeDrain(child, DE_CHILD_STDERR)
        readProgress(child, seconds: seconds, into: progress)
        let message = String(decoding: stderr.wait(), as: UTF8.self)
        return (child.wait(), message)
    }

    /// Reads ffmpeg's `-progress` blocks until it closes stdout, passing on
    /// `out_time_us` as a fraction of the take's `seconds`.
    private static func readProgress(_ child: ChildProcess, seconds: Double, into progress: ((Double) -> Void)?) {
        let key = "out_time_us="
        var pending = Data()
        child.read(DE_CHILD_STDOUT) { chunk in
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

/// One take's files, written from one thread at a time (`TakeIO`'s queue).
///
/// WAV: the 24-bit WAV and the Float32 sidecar side by side; stopping
/// finalizes the WAV and deletes the sidecar. AAC: the sidecar, and the M4A
/// encoded live from the same stream (`LiveEncoder`); stopping finishes the
/// M4A, or encodes it from the sidecar if the live encode failed, then
/// deletes the sidecar. Either way a failure leaves the sidecar for recovery.
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
    /// An AAC take's encoder, running while it records; nil if ffmpeg
    /// couldn't start, and the take is then encoded after STOP.
    private(set) var liveEncoder: LiveEncoder?
    /// The saved M4A came from the live encoder, not the sidecar.
    private(set) var savedLive = false

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
            if let ffmpeg = AACEncoder.ffmpegPath {
                do {
                    liveEncoder = try LiveEncoder(ffmpeg: ffmpeg, sampleRate: sampleRate, notes: notes, output: mainURL)
                } catch {
                    Log.error("The live AAC encoder didn't start (\(error)); the take will be encoded after STOP")
                }
            }
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
        liveEncoder?.write(samples)
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
            liveEncoder?.cancel()
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
            // The live encode: only its last few blocks are left to do.
            if let liveEncoder, liveEncoder.finish(expectedFrames: framesWritten) {
                do {
                    try FileManager.default.moveItem(at: liveEncoder.partial, to: mainURL)
                    try? FileManager.default.removeItem(at: sidecar.url)
                    savedLive = true
                    progress?(1)
                    return .saved(mainURL)
                } catch {
                    try? FileManager.default.removeItem(at: liveEncoder.partial)
                    Log.error("Couldn't put the live M4A in place (\(error)); encoding from the sidecar")
                }
            }
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
        liveEncoder?.cancel()
    }
}
