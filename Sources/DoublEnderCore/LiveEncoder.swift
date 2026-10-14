import CPlatform
import Foundation

/// Encodes an AAC take while it records, as the Mac's AVAssetWriter does.
/// ffmpeg reads the take's mono Float32 stream on stdin and writes the M4A
/// under its temporary name, so STOP waits only for its last few blocks. An
/// encode after STOP runs at roughly 12× real time on an older laptop: three
/// minutes of "SAVING…" for a 35-minute take, ten for two hours.
///
/// The sidecar is still written beside it, and stays the take's safe copy:
/// if ffmpeg won't start, stops reading, fails, or leaves an unfinished
/// file, `finish` says so and the take is encoded from the sidecar instead.
final class LiveEncoder {
    let partial: URL
    private let child: ChildProcess
    private let errors: PipeDrain
    /// Writes to ffmpeg, in order, off the take's own I/O queue: a stalled
    /// encoder can delay its own input, never the sidecar.
    private let queue = DispatchQueue(label: "DoublEnder.live-encoder", qos: .userInitiated)
    // Queue only.
    private var failed = false
    private var framesSent: Int64 = 0
    /// Frames handed to `write` that ffmpeg hasn't taken yet. An encoder that
    /// stalls without dying would otherwise hold the rest of the take in
    /// memory, about 690 MB an hour; past `maxBacklogFrames` it is given up
    /// on, and the sidecar has the take.
    private let maxBacklog: Double
    private let maxBacklogFrames: Int
    private let stateLock = NSLock()
    private var backlogFrames = 0      // stateLock
    private var stopping = false       // stateLock: abandoned or cancelled
    private(set) var fellBehind = false  // stateLock (tests read it after)

    /// `maxBacklog` in seconds of audio.
    init(ffmpeg: String, sampleRate: Double, notes: String, output: URL, maxBacklog: Double = 60) throws {
        self.maxBacklog = maxBacklog
        maxBacklogFrames = Int(max(1, sampleRate * maxBacklog))
        partial = AACEncoder.partialURL(for: output)
        try? FileManager.default.removeItem(at: partial)
        let arguments = [
            "-hide_banner", "-loglevel", "error", "-nostats", "-y",
            "-f", "f32le", "-ar", String(Int(sampleRate.rounded())), "-ac", "1", "-i", "pipe:0",
        ] + AACEncoder.outputArguments(notes: notes, to: partial)
        child = try ChildProcess(ffmpeg, arguments)
        errors = PipeDrain(child, DE_CHILD_STDERR)
    }

    /// Copies `samples` and passes them on in order. Never waits on ffmpeg.
    func write(_ samples: UnsafeBufferPointer<Float>) {
        stateLock.lock()
        if stopping {
            stateLock.unlock()
            return
        }
        if backlogFrames + samples.count > maxBacklogFrames {
            stopping = true
            fellBehind = true
            stateLock.unlock()
            Log.error("The live AAC encoder fell more than \(String(format: "%g", maxBacklog)) s behind; "
                      + "the take will be encoded from its sidecar")
            child.kill()  // a write blocked on it returns, and the queue empties
            return
        }
        backlogFrames += samples.count
        stateLock.unlock()

        let block = Array(samples)
        queue.async { [self] in
            defer {
                stateLock.lock(); backlogFrames -= block.count; stateLock.unlock()
            }
            guard !failed, !isStopping else { return }
            if block.withUnsafeBytes({ child.write($0) }) {
                framesSent += Int64(block.count)
            } else {
                failed = true
                if !isStopping {
                    Log.error("The live AAC encoder stopped taking audio; the take will be encoded from its sidecar")
                }
            }
        }
    }

    private var isStopping: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return stopping
    }

    /// Ends ffmpeg's input and waits for it to finish the file. True when
    /// the M4A at `partial` is finished and was sent all `expectedFrames`;
    /// otherwise false, with `partial` removed. Gives up after `timeout`.
    func finish(expectedFrames: Int64, timeout: Double = 120) -> Bool {
        let outcome = Outcome()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let sentAll = queue.sync { () -> Bool in
                child.closeInput()
                return !failed && framesSent == expectedFrames
            }
            let status = child.wait()
            let message = String(decoding: errors.wait(), as: UTF8.self)
            if status != 0 {
                Log.error("The live AAC encoder failed (\(AACEncoder.lastLine(of: message) ?? "exit \(status)"))")
            }
            outcome.finished = sentAll && status == 0 && MP4File.isFinished(partial)
            outcome.done.signal()
        }
        if outcome.done.wait(timeout: .now() + timeout) == .timedOut {
            Log.error("The live AAC encoder didn't finish within \(Int(timeout)) s; encoding from the sidecar")
            // Its writes then fail at once, so the queue empties and the
            // wait above returns.
            child.kill()
            outcome.done.wait()
            outcome.finished = false
        }
        if !outcome.finished {
            try? FileManager.default.removeItem(at: partial)
        }
        return outcome.finished
    }

    /// Stops ffmpeg and removes its file: the take was discarded.
    func cancel() {
        stateLock.lock(); stopping = true; stateLock.unlock()
        child.kill()
        queue.sync { child.closeInput() }
        child.wait()
        _ = errors.wait()
        try? FileManager.default.removeItem(at: partial)
    }

    /// Tests: ffmpeg dies partway through a take.
    func killForTesting() {
        child.kill()
    }

    private final class Outcome {
        var finished = false
        let done = DispatchSemaphore(value: 0)
    }
}
