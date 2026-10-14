import Foundation

/// Fail-closed free-space check before and during a take. Thresholds and
/// wording follow the Mac build's `DiskSpaceChecker`.
public enum DiskSpaceChecker {

    /// An AAC take writes the Float32 crash-recovery stream beside its M4A,
    /// so it needs ~11.5 MB/min while it records; at 50 MB that is still
    /// minutes of warning before the disk watch stops it.
    private static let minimumFreeBytesAAC: Int64 = 50 * 1024 * 1024
    /// WAV writes the 24-bit file and the Float32 sidecar side by side.
    private static let minimumFreeBytesWAV: Int64 = 200 * 1024 * 1024
    /// What ffmpeg writes per recorded second of AAC: 256 kbps, plus 5%
    /// for the container.
    static let encodedAACBytesPerSecond: Double = 256_000 / 8 * 1.05

    /// The free space a take needs to keep going. An AAC take must also
    /// leave room for its whole M4A, so its floor rises with
    /// `recordedSeconds`: the live encode writes it as the take records, but
    /// if that fails it is encoded again from the sidecar after STOP. While
    /// the live encode runs, its file is counted twice, on the safe side. A
    /// WAV is finished in place.
    public static func minimumFreeBytes(for format: OutputFormat, recordedSeconds: Double = 0) -> Int64 {
        switch format {
        case .aac: return minimumFreeBytesAAC + Int64(max(0, recordedSeconds) * encodedAACBytesPerSecond)
        case .wav: return minimumFreeBytesWAV
        }
    }

    /// nil when there is room; otherwise the message for the user.
    public static func recordingBlockedReason(for directory: URL, format: OutputFormat,
                                              recordedSeconds: Double = 0) -> String? {
        let place = RecordingFiles.locationName(for: directory)
        let required = minimumFreeBytes(for: format, recordedSeconds: recordedSeconds)
        guard let free = availableBytes(at: directory) else {
            return "Could not verify available disk space. Free up space on the \(place) and try again."
        }
        guard free < required else { return nil }
        let mb = max(1, free / (1024 * 1024))
        let requiredMB = max(1, required / (1024 * 1024))
        return "Not enough disk space on \(place) (\(mb) MB free). Free at least \(requiredMB) MB before recording."
    }

    public static func availableBytes(at url: URL) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfFileSystem(forPath: url.path),
              let free = attributes[.systemFreeSize] as? NSNumber else {
            return nil
        }
        return free.int64Value
    }
}

/// Naming and placing recordings.
public enum RecordingFiles {

    /// "Desktop", or whatever the folder is called ("Schreibtisch").
    public static func locationName(for directory: URL) -> String {
        if directory.path == NSHomeDirectory() { return "home folder" }
        return directory.lastPathComponent
    }

    /// `<prefix>_<yyyy-MM-dd_HH-mm-ss-SSS>.<ext>` in `directory`, with `_2`,
    /// `_3`… if taken. en_US_POSIX keeps the digits Western and the clock
    /// 24-hour whatever the user's locale.
    public static func makeRecordingURL(
        in directory: URL, prefix rawPrefix: String, format: OutputFormat, date: Date = Date()
    ) -> URL {
        let ext = format.fileExtension
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss-SSS"
        let prefix = sanitizedPrefix(rawPrefix)
        let base = prefix.isEmpty ? AppInfo.defaultRecordingPrefix : prefix
        let timestamp = formatter.string(from: date)
        var candidate = directory.appendingPathComponent("\(base)_\(timestamp).\(ext)")
        var n = 2
        while exists(candidate) {
            candidate = directory.appendingPathComponent("\(base)_\(timestamp)_\(n).\(ext)")
            n += 1
        }
        return candidate
    }

    /// A take's file exists if its main file or its sidecar does: an AAC
    /// take has only the sidecar until it stops.
    static func exists(_ url: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: url.path) || fm.fileExists(atPath: PCMSidecar.url(for: url).path)
    }

    /// The filename prefix with characters no filesystem accepts replaced.
    /// The Mac build applies the same rules to a whole recording name.
    /// Windows refuses more than macOS does, so the port applies them to
    /// the Settings prefix as well.
    public static func sanitizedPrefix(_ raw: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var result = String(String.UnicodeScalarView(
            trimmed.unicodeScalars.map { illegal.contains($0) ? UnicodeScalar("_") : $0 }
        ))
        while result.contains("__") {
            result = result.replacingOccurrences(of: "__", with: "_")
        }
        while result.hasPrefix(".") {
            result.removeFirst()
        }
        // Windows drops trailing dots and spaces from names.
        while result.hasSuffix(".") || result.hasSuffix(" ") {
            result.removeLast()
        }
        if result.count > 64 {
            result = String(result.prefix(64))
        }
        return result
    }
}

extension Double {
    /// `HH:MM:SS` for the counter.
    public var hhmmss: String {
        let total = Int(self)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }
}
