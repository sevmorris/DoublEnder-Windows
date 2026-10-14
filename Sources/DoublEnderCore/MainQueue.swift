import Foundation

/// Work for the UI thread, run once per frame by the main loop.
///
/// raylib owns the main thread, so Dispatch's main queue (which needs
/// `dispatchMain` or a run loop) never drains on its own. Background
/// threads hand results back through this instead.
public enum MainQueue {
    private static let lock = NSLock()
    private static var pending: [() -> Void] = []

    public static func post(_ work: @escaping () -> Void) {
        lock.lock()
        pending.append(work)
        lock.unlock()
    }

    /// Runs everything posted so far, including work those items post.
    public static func drain() {
        while true {
            lock.lock()
            let batch = pending
            pending.removeAll()
            lock.unlock()
            if batch.isEmpty { return }
            for work in batch { work() }
        }
    }
}
