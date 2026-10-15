import Foundation

/// Crash-recovery sidecar, file-compatible with the Mac build's: a 20-byte
/// DEP2 header, then raw Float32 mono samples. A sidecar written on any
/// platform recovers on any other.
///
/// It is a flat append-only stream with a self-describing header, so even
/// a truncated one (crash, kill, power loss) re-wraps into a valid WAV at
/// the next launch. It exists on disk if and only if the take's main file
/// was never finalized.
///
/// In this port it also backs up an AAC take: the M4A is encoded live
/// (`LiveEncoder`), and if that fails it is encoded from the sidecar after
/// STOP (`AACEncoder`), so an AAC recording is crash-safe from its first
/// sample.
public final class PCMSidecar {
    /// `Recording.m4a` → `Recording.m4a.pcmrec`.
    public static let pathExtension = "pcmrec"

    /// Main-file size at or below which launch cleanup treats a main file
    /// next to an empty sidecar as a stub and deletes both. As on the Mac,
    /// only used where keeping the file is the safe side.
    public static let mainFileValidThresholdBytes: Int64 = 8 * 1024

    static let magicV1: [UInt8] = Array("DEP1".utf8)
    static let magicV2: [UInt8] = Array("DEP2".utf8)
    static let headerSizeV1 = 16
    public static let headerSizeV2 = 20
    static let payloadFormatFloat32: UInt32 = 1
    /// Flush at most this often, so a power loss loses about that much. The
    /// Mac flushes every 512 KB (~2.7 s at 48 kHz); a time interval instead
    /// keeps a slow flush from capping how fast a backlog can be written,
    /// since a writer catching up writes a lot between flushes.
    static let defaultSyncInterval: Double = 2.5

    public let url: URL
    public let sampleRate: Double
    private let handle: FileHandle
    var syncInterval = PCMSidecar.defaultSyncInterval
    private var lastSyncAt: Double
    /// Flushes so far and the slowest, for the take's log line.
    public private(set) var syncCount = 0
    public private(set) var longestSync: Double = 0
    public private(set) var payloadBytes: Int64 = 0

    public static func url(for mainOutput: URL) -> URL {
        URL(fileURLWithPath: mainOutput.path + "." + pathExtension)
    }

    public static func mainOutputURL(for sidecar: URL) -> URL {
        sidecar.deletingPathExtension()
    }

    /// True when the file holds at least one sample past the header.
    public static func hasRecoverableContent(at sidecarURL: URL) -> Bool {
        fileSize(sidecarURL).map { $0 > Int64(headerSizeV2) } ?? false
    }

    static func fileSize(_ url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }

    /// Creates the sidecar next to `mainOutput` and writes its header.
    public init(mainOutput: URL, sampleRate: Double) throws {
        let url = PCMSidecar.url(for: mainOutput)
        guard FileManager.default.createFile(
            atPath: url.path, contents: Self.makeHeaderV2(sampleRate: sampleRate, channels: 1)
        ) else {
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
        self.sampleRate = sampleRate
        lastSyncAt = Platform.now()
    }

    /// Appends mono samples, from one thread at a time: the take's I/O
    /// queue (`TakeIO`).
    public func append(_ samples: UnsafeBufferPointer<Float>) throws {
        guard samples.count > 0 else { return }
        let data = Data(buffer: samples)
        try handle.write(contentsOf: data)
        payloadBytes += Int64(data.count)
        let now = Platform.now()
        if now - lastSyncAt >= syncInterval {
            try handle.synchronize()
            lastSyncAt = Platform.now()
            syncCount += 1
            longestSync = max(longestSync, lastSyncAt - now)
        }
    }

    /// Close and keep: the main file is not finished, so this is the copy.
    public func close() {
        try? handle.synchronize()
        try? handle.close()
    }

    /// Close and delete: the main file is finished, or the take was discarded.
    public func discard() {
        try? handle.close()
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Header

    struct ParsedHeader {
        let headerSize: Int
        let sampleRate: Double
        let channels: UInt32
        let dataSize: UInt32
    }

    public enum RecoveryError: LocalizedError {
        case badHeader
        case emptyPayload
        case tooLongForWAV

        public var errorDescription: String? {
            switch self {
            case .badHeader: return "The recovery file is missing or corrupt."
            case .emptyPayload: return "The recovery file contains no audio data."
            case .tooLongForWAV: return "The recording is longer than one WAV file can hold (4 GB)."
            }
        }
    }

    static func makeHeaderV2(sampleRate: Double, channels: UInt32) -> Data {
        var header = Data(magicV2)
        header.appendLE(sampleRate.bitPattern)
        header.appendLE(max(channels, 1))
        header.appendLE(payloadFormatFloat32)
        return header
    }

    static func parseHeader(at sidecarURL: URL) throws -> ParsedHeader {
        let input = try FileHandle(forReadingFrom: sidecarURL)
        defer { try? input.close() }
        guard let magic = try input.read(upToCount: 4), magic.count == 4 else {
            throw RecoveryError.badHeader
        }
        let headerSize: Int
        if magic.elementsEqual(magicV1) {
            headerSize = headerSizeV1
        } else if magic.elementsEqual(magicV2) {
            headerSize = headerSizeV2
        } else {
            throw RecoveryError.badHeader
        }
        guard let rest = try input.read(upToCount: headerSize - 4), rest.count == headerSize - 4 else {
            throw RecoveryError.badHeader
        }
        let header = [UInt8](magic) + [UInt8](rest)
        let sampleRate = Double(bitPattern: header.loadLE(UInt64.self, at: 4))
        // A torn header can leave garbage here; reject it rather than trap
        // converting it below.
        guard sampleRate.isFinite, sampleRate >= 1, sampleRate <= Double(UInt32.max) else {
            throw RecoveryError.badHeader
        }
        let channels = header.loadLE(UInt32.self, at: 12)
        guard channels >= 1, channels <= 64 else { throw RecoveryError.badHeader }

        let totalSize = fileSize(sidecarURL) ?? Int64(headerSize)
        let payloadSize = totalSize - Int64(headerSize)
        guard payloadSize >= 0 else { throw RecoveryError.badHeader }
        // RIFF sizes are 32-bit: past ~4 GiB (≈6 h at 48 kHz) a WAV can't
        // say how long it is. The sidecar stays on disk.
        guard payloadSize <= Int64(UInt32.max) - 36 else { throw RecoveryError.tooLongForWAV }
        // Whole samples only: a torn final write can leave a partial one.
        let dataSize = UInt32(payloadSize) / 4 * 4
        return ParsedHeader(headerSize: headerSize, sampleRate: sampleRate,
                            channels: channels, dataSize: dataSize)
    }

    // MARK: - Recovery

    /// Re-wraps the sidecar's samples into a 32-bit float WAV next to it,
    /// streaming 1 MB at a time. Returns the WAV's URL.
    public static func recoverToWAV(sidecarURL: URL) throws -> URL {
        let parsed = try parseHeader(at: sidecarURL)
        guard parsed.dataSize > 0 else { throw RecoveryError.emptyPayload }

        let input = try FileHandle(forReadingFrom: sidecarURL)
        defer { try? input.close() }
        try input.seek(toOffset: UInt64(parsed.headerSize))

        let outURL = recoveredWAVURL(for: sidecarURL)
        // Written under a temporary name and renamed once complete, so a quit
        // halfway never leaves a WAV whose header claims audio it lacks.
        // Launch cleanup removes a leftover one.
        let partial = outURL.deletingLastPathComponent().appendingPathComponent(".\(outURL.lastPathComponent).part")
        try? FileManager.default.removeItem(at: partial)
        let header = WAVFile.header(format: .float32, sampleRate: UInt32(parsed.sampleRate),
                                    channels: UInt16(parsed.channels), dataSize: parsed.dataSize)
        guard FileManager.default.createFile(atPath: partial.path, contents: header) else {
            throw RecordingError.cannotCreateFile(outURL.lastPathComponent)
        }
        do {
            let output = try FileHandle(forWritingTo: partial)
            do {
                try output.seekToEnd()
                var remaining = Int(parsed.dataSize)
                while remaining > 0, let chunk = try input.read(upToCount: min(1 << 20, remaining)), !chunk.isEmpty {
                    try output.write(contentsOf: chunk)
                    remaining -= chunk.count
                }
                try output.synchronize()
                try output.close()
            } catch {
                try? output.close()
                throw error
            }
            // Closed first: Windows won't rename an open file.
            try FileManager.default.moveItem(at: partial, to: outURL)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
        return outURL
    }

    /// `/dir/Name.m4a.pcmrec` → `/dir/Name (recovered).wav`, de-duplicated.
    static func recoveredWAVURL(for sidecarURL: URL) -> URL {
        let mainURL = mainOutputURL(for: sidecarURL)
        let dir = mainURL.deletingLastPathComponent()
        let stem = mainURL.deletingPathExtension().lastPathComponent
        var candidate = dir.appendingPathComponent("\(stem) (recovered).wav")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(stem) (recovered \(n)).wav")
            n += 1
        }
        return candidate
    }
}

// MARK: - WAV

/// RIFF/WAVE headers, and whether a file on disk is a finished recording.
public enum WAVFile {
    public enum Format {
        case pcm24
        case float32

        var formatTag: UInt16 { self == .float32 ? 3 : 1 }
        var bitsPerSample: UInt16 { self == .float32 ? 32 : 24 }
    }

    /// The canonical 44-byte header.
    public static func header(format: Format, sampleRate: UInt32, channels: UInt16, dataSize: UInt32) -> Data {
        let blockAlign = channels * (format.bitsPerSample / 8)
        var d = Data()
        d.append(contentsOf: Array("RIFF".utf8)); d.appendLE(36 &+ dataSize)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); d.appendLE(UInt32(16))
        d.appendLE(format.formatTag); d.appendLE(channels)
        d.appendLE(sampleRate); d.appendLE(sampleRate &* UInt32(blockAlign))
        d.appendLE(blockAlign); d.appendLE(format.bitsPerSample)
        d.append(contentsOf: Array("data".utf8)); d.appendLE(dataSize)
        return d
    }

    /// True when `url` is a WAV whose data chunk holds at least one frame.
    /// An unfinished take from `WAVWriter` records a data size of zero, so
    /// it reads as empty — the same test the Mac makes with AVAudioFile.
    public static func isFinished(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 12), head.count == 12,
              head.prefix(4).elementsEqual("RIFF".utf8), head.dropFirst(8).prefix(4).elementsEqual("WAVE".utf8)
        else { return false }
        var offset: UInt64 = 12
        var blockAlign: UInt32 = 0
        while true {
            guard (try? handle.seek(toOffset: offset)) != nil,
                  let chunk = try? handle.read(upToCount: 8), chunk.count == 8 else { return false }
            let bytes = [UInt8](chunk)
            let id = String(decoding: bytes[0..<4], as: UTF8.self)
            let size = bytes.loadLE(UInt32.self, at: 4)
            if id == "fmt ", let fmt = try? handle.read(upToCount: 16), fmt.count == 16 {
                blockAlign = UInt32([UInt8](fmt).loadLE(UInt16.self, at: 12))
            }
            if id == "data" {
                return blockAlign > 0 && size >= blockAlign
            }
            offset += 8 + UInt64(size) + UInt64(size & 1)
        }
    }
}

/// An MPEG-4 file is finished when its top level holds a `moov` box, which
/// a writer adds only when it closes the file.
public enum MP4File {
    public static func isFinished(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url),
              let total = PCMSidecar.fileSize(url) else { return false }
        defer { try? handle.close() }
        var offset: UInt64 = 0
        var sawMoov = false
        var sawMdat = false
        while offset + 8 <= UInt64(total) {
            guard (try? handle.seek(toOffset: offset)) != nil,
                  let head = try? handle.read(upToCount: 8), head.count == 8 else { return false }
            let bytes = [UInt8](head)
            var size = UInt64(bytes.loadBE(UInt32.self, at: 0))
            let type = String(decoding: bytes[4..<8], as: UTF8.self)
            if size == 1 {
                guard let ext = try? handle.read(upToCount: 8), ext.count == 8 else { return false }
                size = [UInt8](ext).loadBE(UInt64.self, at: 0)
            } else if size == 0 {
                size = UInt64(total) - offset
            }
            // A box can't run past the end of the file. A truncated file isn't
            // finished, and a corrupt size near 2^64 would overflow `offset`.
            guard size >= 8, size <= UInt64(total) - offset else { return false }
            if type == "moov" { sawMoov = true }
            if type == "mdat" { sawMdat = true }
            offset += size
        }
        return sawMoov && sawMdat
    }
}

/// Whether a take's main file is a finished recording, by its extension.
public func isFinishedRecording(at url: URL) -> Bool {
    switch url.pathExtension.lowercased() {
    case "wav": return WAVFile.isFinished(url)
    case "m4a", "mp4", "aac": return MP4File.isFinished(url)
    default: return false
    }
}

// MARK: - Little-endian helpers

extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}

extension Array where Element == UInt8 {
    func loadLE<T: FixedWidthInteger>(_: T.Type, at offset: Int) -> T {
        var value: T = 0
        Swift.withUnsafeMutableBytes(of: &value) { dst in
            for i in 0..<MemoryLayout<T>.size { dst[i] = self[offset + i] }
        }
        return T(littleEndian: value)
    }

    func loadBE<T: FixedWidthInteger>(_: T.Type, at offset: Int) -> T {
        var value: T = 0
        for i in 0..<MemoryLayout<T>.size { value = value << 8 | T(self[offset + i]) }
        return value
    }
}
