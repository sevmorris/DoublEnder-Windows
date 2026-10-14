import CPlatform
import Foundation

/// One recorder at a time. A second copy's launch-time crash recovery
/// would take the first copy's take in progress for an abandoned one, and
/// RECOVER or DELETE would destroy it. On the Mac, LaunchServices keeps the
/// app single-instance; here the app holds this lock while it runs.
///
/// A named mutex on Windows, an flock on a file elsewhere. Either way the
/// system releases it when the process ends, crash included.
public final class InstanceLock {
    public enum Outcome {
        case acquired(InstanceLock)
        /// Another copy is running.
        case alreadyRunning
        /// The lock couldn't be checked (an unwritable directory, say). The
        /// app runs anyway rather than not at all.
        case unavailable
    }

    private var token: UnsafeMutableRawPointer?

    private init(token: UnsafeMutableRawPointer?) {
        self.token = token
    }

    deinit {
        release()
    }

    public func release() {
        de_instance_unlock(token)
        token = nil
    }

    /// `name` names the Windows mutex and the lock file; tests pass their own.
    public static func acquire(name: String = AppInfo.name,
                               directory: URL = Platform.instanceLockDirectory) -> Outcome {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("\(name).lock").path
        var token: UnsafeMutableRawPointer?
        // "Local\" scopes the mutex to this login session, as the lock file
        // is scoped to this user.
        switch de_instance_lock("Local\\\(name).instance", path, &token) {
        case DE_INSTANCE_ACQUIRED:
            return .acquired(InstanceLock(token: token))
        case DE_INSTANCE_TAKEN:
            return .alreadyRunning
        default:
            return .unavailable
        }
    }
}
