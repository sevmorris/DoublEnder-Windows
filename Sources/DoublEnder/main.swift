import DoublEnderCore
import Foundation

/// Bundled art and fonts: next to the executable in a release, else the
/// SwiftPM resource bundle of a development build.
func resourcesDirectory() -> URL {
    let fm = FileManager.default
    if let dir = Platform.executableDirectory {
        for candidate in ["DoublEnder_DoublEnder.resources/Resources", "Resources"] {
            let url = dir.appendingPathComponent(candidate)
            if fm.fileExists(atPath: url.appendingPathComponent("Images/faceplate.png").path) { return url }
        }
    }
    return Bundle.module.url(forResource: "Resources", withExtension: nil)!
}

let usage = """
    Usage: DoublEnder [option]

      (no option)              open the recorder
      --list-devices           print the inputs and what the default one delivers
      --test-record SECONDS    record from the default input without a window
          [--wav]              …as WAV instead of AAC
      --version                print the version

    Development:
      --recordings-dir DIR     save takes in DIR instead of the Desktop
      --ui-tour DIR            step through the UI, saving screenshots to DIR
    """

var arguments = Array(CommandLine.arguments.dropFirst())

func takeValue(after flag: String) -> String? {
    guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
    let value = arguments[i + 1]
    arguments.removeSubrange(i...(i + 1))
    return value
}

let recordingsDirectory = takeValue(after: "--recordings-dir")
    .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? Platform.recordingsDirectory
let tourDirectory = takeValue(after: "--ui-tour")

if arguments.contains("--help") || arguments.contains("-h") {
    print(usage)
    exit(0)
}
if arguments.contains("--version") {
    print("\(AppInfo.name) \(AppInfo.version)")
    exit(0)
}
if arguments.contains("--list-devices") {
    exit(Diagnostics.listDevices())
}
if let secondsText = takeValue(after: "--test-record") {
    guard let seconds = Double(secondsText), seconds > 0 else {
        print(usage)
        exit(2)
    }
    let format: OutputFormat = arguments.contains("--wav") || !AACEncoder.isAvailable ? .wav : .aac
    exit(Diagnostics.testRecord(seconds: seconds, format: format, directory: recordingsDirectory))
}

let controller = RecorderController(recordingsDirectory: recordingsDirectory)
let app = App(controller: controller, resources: resourcesDirectory())
if let tourDirectory {
    app.tour = UITour(directory: URL(fileURLWithPath: tourDirectory, isDirectory: true))
}
app.run()
