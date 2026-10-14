import Foundation

/// What `TakeIO` writes to: a take's files (`TakeWriter`), or a test's stand-in.
protocol TakeSink: AnyObject {
    func write(_ samples: UnsafeBufferPointer<Float>) throws
    /// The crash-recovery copy stopped taking writes.
    var sidecarFailed: Bool { get }
}

extension TakeWriter: TakeSink {}

/// A take's disk writes, kept off the thread that drains the capture ring.
///
/// The Mac build never blocks capture on file I/O: AVAssetWriter buffers
/// the main file, and the sidecar writes on its own queue with pending
/// writes held in memory (THEORY_OF_OPERATION §3). The port first wrote the
/// WAV, the sidecar and its syncs on the pump itself. On Windows a sync
/// (FlushFileBuffers, which also flushes the drive's cache) can take
/// seconds on a busy disk, so the ring overflowed and takes failed with
/// "Audio was dropped". Now the pump copies each block here and goes back
/// to draining; the writes run in order on one serial queue, and a slow
/// disk only grows the backlog in memory. As on the Mac, nothing bounds it.
final class TakeIO<Sink: TakeSink> {
    let sink: Sink
    private let queue: DispatchQueue

    // Pump thread only.
    /// Frames handed over so far: the watchdogs' "has audio arrived?".
    private(set) var framesEnqueued: Int64 = 0
    /// The longest the ring went unread during the take, for the log.
    private(set) var longestDrainGap: Double = 0

    // Written on the queue, read anywhere, under `lock`.
    private let lock = NSLock()
    private var pendingFrames = 0
    private var maxPendingFrames = 0
    private var firstError: Error?
    private var lastWriteAt: Double = 0
    private var longestWrite: Double = 0
    private var sidecarHasFailed = false

    init(sink: Sink, queue: DispatchQueue) {
        self.sink = sink
        self.queue = queue
    }

    /// Pump thread. Copies the samples and returns without touching the disk.
    func enqueue(_ samples: UnsafeBufferPointer<Float>) {
        guard samples.count > 0 else { return }
        let chunk = Array(samples)
        framesEnqueued += Int64(chunk.count)
        lock.lock()
        pendingFrames += chunk.count
        maxPendingFrames = max(maxPendingFrames, pendingFrames)
        lock.unlock()
        queue.async { [self] in
            let start = Platform.now()
            var failure: Error?
            do {
                try chunk.withUnsafeBufferPointer { try sink.write($0) }
            } catch {
                failure = error
            }
            let end = Platform.now()
            let sidecarFailed = sink.sidecarFailed
            lock.lock()
            pendingFrames -= chunk.count
            longestWrite = max(longestWrite, end - start)
            if let failure {
                if firstError == nil { firstError = failure }
            } else {
                lastWriteAt = end
            }
            sidecarHasFailed = sidecarFailed
            lock.unlock()
        }
    }

    /// Pump thread: the ring was just read, `gap` seconds after the last read.
    func noteDrain(gap: Double) {
        longestDrainGap = max(longestDrainGap, gap)
    }

    /// The first write that failed, if any. The take can't continue.
    var error: Error? { locked { firstError } }

    /// When a write last reached the files (`Platform.now()` time; 0 if never).
    var lastWrite: Double { locked { lastWriteAt } }

    /// Captured but not yet written.
    var backlogFrames: Int { locked { pendingFrames } }

    var sidecarFailed: Bool { locked { sidecarHasFailed } }

    /// Waits for every write enqueued so far. Never on the pump.
    func drain() {
        queue.sync {}
    }

    /// For the log, after `drain`: what the disk side went through.
    var ioSummary: (longestWrite: Double, largestBacklogFrames: Int) {
        locked { (longestWrite, maxPendingFrames) }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
