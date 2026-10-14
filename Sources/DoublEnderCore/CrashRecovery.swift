import Foundation

/// Launch-time crash recovery, following the Mac build's
/// `runCrashRecoveryIfNeeded` and `RecoveryModel` (THEORY_OF_OPERATION §7).
///
/// A sidecar on disk means its take never finished. Empty ones are tidied
/// away; each one holding audio gets the recovery dialog, one at a time.
public enum CrashRecovery {

    /// Scans `directory` and queues what the user needs to decide.
    public static func run(in directory: URL, dialogs: DialogQueue) {
        let fm = FileManager.default
        let contents: [URL]
        do {
            contents = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        } catch {
            let place = RecordingFiles.locationName(for: directory)
            dialogs.present(Dialog(
                icon: .warning, title: "COULDN'T CHECK FOR UNSAVED RECORDINGS",
                message: "DoublEnder couldn't check the \(place) for recordings from a previous session: \(error.localizedDescription). Check that the \(place) is accessible and relaunch to retry.",
                buttons: [.init("OK", isDefault: true)]))
            return
        }

        // An AAC encode or a recovery the app didn't live to finish. The
        // sidecar each was made from is still here and recovers below.
        for url in contents {
            let name = url.lastPathComponent
            if name.hasPrefix("."), name.hasSuffix(".m4a.part") || name.hasSuffix(".wav.part") {
                try? fm.removeItem(at: url)
            }
        }

        let sidecars = contents
            .filter { $0.pathExtension == PCMSidecar.pathExtension }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for sidecar in sidecars {
            if PCMSidecar.hasRecoverableContent(at: sidecar) {
                presentPrompt(for: sidecar, dialogs: dialogs)
            } else {
                cleanUpEmpty(sidecar)
            }
        }
    }

    /// A header-only sidecar: the take ended before any audio reached it.
    /// Its main file is kept if it is large enough to hold audio — the safe
    /// side, since it is the only copy — and deleted as a stub otherwise.
    static func cleanUpEmpty(_ sidecar: URL) {
        let fm = FileManager.default
        let main = PCMSidecar.mainOutputURL(for: sidecar)
        if let size = PCMSidecar.fileSize(main), size > PCMSidecar.mainFileValidThresholdBytes {
            Log.info("Removed an empty crash-recovery file beside a saved recording.")
        } else {
            try? fm.removeItem(at: main)
        }
        try? fm.removeItem(at: sidecar)
    }

    static func presentPrompt(for sidecar: URL, dialogs: DialogQueue) {
        let main = PCMSidecar.mainOutputURL(for: sidecar)
        let fileName = main.lastPathComponent
        let recover = Dialog.Button("RECOVER", isDefault: true) {
            recoverWithProgress(sidecar: sidecar, main: main, dialogs: dialogs)
        }
        let delete = Dialog.Button("DELETE") {
            try? FileManager.default.removeItem(at: sidecar)
            try? FileManager.default.removeItem(at: main)
        }

        // A finished main file next to a sidecar: the crash came between
        // finishing the file and deleting the sidecar.
        if isFinishedRecording(at: main) {
            let keep = Dialog.Button("KEEP SAVED", isDefault: true) {
                try? FileManager.default.removeItem(at: sidecar)
            }
            dialogs.present(Dialog(
                icon: .success, title: "SAVED RECORDING FOUND",
                message: "A recovery file was left behind, but the saved recording at this location is intact. Keeping it is the safe choice — recover only if you have reason to think the saved file is bad.",
                fileName: fileName,
                buttons: [keep, .init("RECOVER") { recover.action() }, delete]))
        } else {
            dialogs.present(Dialog(
                icon: .warning, title: "UNSAVED RECORDING",
                message: "A recording from a previous session was interrupted before it could be saved. DoublEnder can recover it as a WAV file.",
                fileName: fileName,
                buttons: [recover, delete]))
        }
    }

    static func recoverWithProgress(sidecar: URL, main: URL, dialogs: DialogQueue) {
        let working = Dialog(
            icon: .question, title: "RECOVERING RECORDING…",
            message: "Re-wrapping the audio into a WAV file. This can take a moment for a long recording.",
            buttons: [], showsSpinner: true)
        dialogs.present(working, first: true)
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = Result { try PCMSidecar.recoverToWAV(sidecarURL: sidecar) }
            if case .success = outcome {
                try? FileManager.default.removeItem(at: sidecar)
                try? FileManager.default.removeItem(at: main)
            }
            MainQueue.post {
                switch outcome {
                case .success(let url):
                    dialogs.replace(working.id, with: Dialog(
                        icon: .success, title: "RECOVERY COMPLETE",
                        message: "The recording was saved as:",
                        fileName: url.lastPathComponent,
                        buttons: [
                            .init("SHOW IN \(Platform.fileManagerName.uppercased())") { Platform.reveal(url) },
                            .init("CLOSE", isDefault: true),
                        ]))
                case .failure(let error):
                    dialogs.replace(working.id, with: Dialog(
                        icon: .warning, title: "RECOVERY FAILED",
                        message: "The recording could not be recovered: \(error.localizedDescription)\n\nThe recovery file has been left in place so nothing is lost.",
                        buttons: [.init("CLOSE", isDefault: true)]))
                }
            }
        }
    }
}
