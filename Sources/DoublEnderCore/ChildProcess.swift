import CPlatform
import Foundation

/// A child process on pipes, for ffmpeg. Foundation's `Process` would do on
/// Linux, but on Windows it gives a console program such as ffmpeg.exe a
/// console window of its own; `de_child_start` starts it with none.
final class ChildProcess {
    private let child: OpaquePointer
    private var waited = false
    private var exitStatus: Int32 = -1

    enum Failure: Error {
        case cannotStart(String)
    }

    init(_ executable: String, _ arguments: [String]) throws {
        let strings = [executable] + arguments
        let buffers: [UnsafeMutablePointer<CChar>] = strings.map { string in
            let utf8 = Array(string.utf8CString)
            let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: utf8.count)
            buffer.initialize(from: utf8, count: utf8.count)
            return buffer
        }
        defer { buffers.forEach { $0.deallocate() } }
        let argv: [UnsafePointer<CChar>?] = buffers.map { UnsafePointer($0) }
        guard let child = de_child_start(argv, Int32(argv.count)) else {
            throw Failure.cannotStart(executable)
        }
        self.child = child
    }

    deinit {
        if !waited {
            de_child_kill(child)
            _ = de_child_wait(child)
        }
        de_child_free(child)
    }

    /// Writes all of `bytes` to stdin; false once the child has stopped
    /// reading. One writing thread at a time.
    func write(_ bytes: UnsafeRawBufferPointer) -> Bool {
        guard let base = bytes.baseAddress, bytes.count > 0 else { return true }
        return de_child_write(child, base, bytes.count) == 0
    }

    /// The child reads end of file.
    func closeInput() {
        de_child_close_input(child)
    }

    /// Reads stdout or stderr until the child closes it, a chunk at a time.
    func read(_ which: Int32, chunk: (Data) -> Void) {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let got = buffer.withUnsafeMutableBytes { de_child_read(child, which, $0.baseAddress, $0.count) }
            if got <= 0 { return }
            chunk(Data(buffer[0..<Int(got)]))
        }
    }

    /// Reads all of stdout or stderr.
    func readAll(_ which: Int32) -> Data {
        var all = Data()
        read(which) { all.append($0) }
        return all
    }

    /// Waits for the child to exit: its exit status, or -1 if a signal ended
    /// it (on Windows, `kill` makes it exit 1).
    @discardableResult
    func wait() -> Int32 {
        if !waited {
            exitStatus = de_child_wait(child)
            waited = true
        }
        return exitStatus
    }

    func kill() {
        de_child_kill(child)
    }

    /// The command line Windows is given for these arguments, quoted so the
    /// child's C runtime splits it back into exactly them.
    static func windowsCommandLine(_ arguments: [String]) -> String {
        let buffers: [UnsafeMutablePointer<CChar>] = arguments.map { string in
            let utf8 = Array(string.utf8CString)
            let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: utf8.count)
            buffer.initialize(from: utf8, count: utf8.count)
            return buffer
        }
        defer { buffers.forEach { $0.deallocate() } }
        let argv: [UnsafePointer<CChar>?] = buffers.map { UnsafePointer($0) }
        let length = de_windows_command_line(argv, Int32(argv.count), nil, 0)
        var out = [CChar](repeating: 0, count: length + 1)
        _ = de_windows_command_line(argv, Int32(argv.count), &out, out.count)
        return String(cString: out)
    }
}

/// Reads one of a child's pipes to its end on a background thread, so a
/// child writing to two pipes never stalls on the one nobody is reading.
final class PipeDrain {
    private var data = Data()
    private let done = DispatchSemaphore(value: 0)

    init(_ process: ChildProcess, _ which: Int32) {
        DispatchQueue.global(qos: .utility).async { [self] in
            data = process.readAll(which)
            done.signal()
        }
    }

    func wait() -> Data {
        done.wait()
        return data
    }
}
