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
    static func encode(sidecar: URL, sampleRate: Double, notes: String, to output: URL) throws {
        guard let ffmpeg = ffmpegPath else { throw RecordingError.encoderMissing }
        let partial = output.deletingLastPathComponent()
            .appendingPathComponent(".\(output.lastPathComponent).part")
        try? FileManager.default.removeItem(at: partial)

        var arguments = [
            "-hide_banner", "-nostdin", "-loglevel", "error", "-y",
            "-f", "f32le", "-ar", String(Int(sampleRate.rounded())), "-ac", "1",
            "-skip_initial_bytes", String(PCMSidecar.headerSizeV2),
            "-i", sidecar.path,
            "-c:a", "aac", "-b:a", "256k", "-ar", "48000", "-ac", "1",
        ]
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedNotes.isEmpty {
            arguments += ["-metadata", "description=\(trimmedNotes)"]
        }
        arguments += ["-f", "ipod", partial.path]

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = arguments
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw RecordingError.encoderFailed("couldn't start ffmpeg")
        }
        let message = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, MP4File.isFinished(partial) else {
            try? FileManager.default.removeItem(at: partial)
            let detail = String(decoding: message, as: UTF8.self)
                .split(whereSeparator: \.isNewline).last.map(String.init) ?? "exit \(process.terminationStatus)"
            throw RecordingError.encoderFailed(detail)
        }
        try FileManager.default.moveItem(at: partial, to: output)
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

    /// Finishes the take. Slow for AAC (it encodes), so not on the pump.
    func finish() -> Outcome {
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
                try AACEncoder.encode(sidecar: sidecar.url, sampleRate: sampleRate, notes: notes, to: mainURL)
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
