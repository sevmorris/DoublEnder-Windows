import Foundation

/// User-selectable output format, as on the Mac.
public enum OutputFormat: String, CaseIterable, Codable {
    case aac
    case wav

    public var fileExtension: String {
        switch self {
        case .aac: return "m4a"
        case .wav: return "wav"
        }
    }

    public var displayName: String {
        switch self {
        case .aac: return "AAC / M4A (256 kbps)"
        case .wav: return "WAV (Uncompressed)"
        }
    }

    public var settingsDescription: String {
        switch self {
        case .aac: return "Recorded as mono, 256 kbps. Smaller file size, transparent quality for voice."
        case .wav: return "Uncompressed 24-bit PCM at the hardware's native sample rate. Professional quality, universally compatible."
        }
    }
}

/// Settings that outlive a launch, kept in one small JSON file
/// (`Platform.settingsDirectory`). Stands in for the Mac build's
/// UserDefaults, whose persistence is not dependable on every Swift
/// platform.
public final class SettingsStore {
    private struct Stored: Codable {
        var filenameBase: String?
        var outputFormat: OutputFormat?
        /// Device UID → first-seen time (seconds since 1970), for the
        /// launch-time "use the mic you just plugged in" offer.
        var deviceFirstSeen: [String: Double]?
    }

    private let fileURL: URL?
    private var stored: Stored

    /// `directory` nil keeps everything in memory, for tests.
    public init(directory: URL? = Platform.settingsDirectory) {
        fileURL = directory?.appendingPathComponent("settings.json")
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(Stored.self, from: data) {
            stored = decoded
        } else {
            stored = Stored()
        }
    }

    public var filenameBase: String {
        get { stored.filenameBase ?? "" }
        set { stored.filenameBase = newValue.isEmpty ? nil : newValue; save() }
    }

    public var outputFormat: OutputFormat? {
        get { stored.outputFormat }
        set { stored.outputFormat = newValue; save() }
    }

    public var deviceFirstSeen: [String: Double] {
        get { stored.deviceFirstSeen ?? [:] }
        set { stored.deviceFirstSeen = newValue; save() }
    }

    private func save() {
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(stored)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Log.error("Settings not saved: \(error)")
        }
    }
}

/// Minimal stderr logging. Never logs audio, notes or file contents.
public enum Log {
    public static func info(_ message: @autoclosure () -> String) {
        write("info", message())
    }

    public static func error(_ message: @autoclosure () -> String) {
        write("error", message())
    }

    private static func write(_ level: String, _ message: String) {
        FileHandle.standardError.write(Data("[DoublEnder] \(level): \(message)\n".utf8))
    }
}
