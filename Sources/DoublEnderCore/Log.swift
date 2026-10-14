import Foundation

/// Logging to stderr and, once the app calls `startFile(in:)`, to
/// `DoublEnder.log` (see `Platform.logDirectory`), which a producer can ask a
/// guest for. Never logs audio, notes or file contents. Safe from any thread.
///
/// A Windows release build is a GUI program with no console. Foundation's
/// `FileHandle.standardError` there wraps an invalid handle, and its
/// `write(_:)` is `try!`, so the first log line would end the app. That
/// build logs to the file only, and stderr is always written through the
/// throwing API.
public enum Log {
    /// A log past this size is moved aside when the app starts.
    static let maxFileBytes: Int64 = 1024 * 1024

    private static let lock = NSLock()
    private static var file: FileHandle?
    private static let timestamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    public static func info(_ message: @autoclosure () -> String) {
        write("info", message())
    }

    public static func error(_ message: @autoclosure () -> String) {
        write("error", message())
    }

    /// Appends to `DoublEnder.log` in `directory` from now on, first moving
    /// a log over 1 MB aside to `DoublEnder.previous.log`. Only the running
    /// recorder calls this; tests and the diagnostics don't.
    public static func startFile(in directory: URL) {
        let fm = FileManager.default
        let url = directory.appendingPathComponent("\(AppInfo.name).log")
        let previous = directory.appendingPathComponent("\(AppInfo.name).previous.log")
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            if let size = PCMSidecar.fileSize(url), size > maxFileBytes {
                try? fm.removeItem(at: previous)
                try fm.moveItem(at: url, to: previous)
            }
            if !fm.fileExists(atPath: url.path), !fm.createFile(atPath: url.path, contents: nil) {
                throw RecordingError.cannotCreateFile(url.lastPathComponent)
            }
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            lock.lock()
            try? file?.close()
            file = handle
            lock.unlock()
        } catch {
            Log.error("No log file: \(error.localizedDescription)")
            return
        }
        Log.info("\(AppInfo.name) \(AppInfo.version) started")
    }

    /// Closes the log file. For tests.
    static func stopFile() {
        lock.lock()
        defer { lock.unlock() }
        try? file?.close()
        file = nil
    }

    private static func write(_ level: String, _ message: String) {
        lock.lock()
        defer { lock.unlock() }
        #if !os(Windows) || DEBUG
        try? FileHandle.standardError.write(contentsOf: Data("[DoublEnder] \(level): \(message)\n".utf8))
        #endif
        if let file {
            let line = "\(timestamp.string(from: Date())) \(level): \(message)\n"
            try? file.write(contentsOf: Data(line.utf8))
        }
    }
}
