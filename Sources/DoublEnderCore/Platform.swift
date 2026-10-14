import Foundation

/// Everything that differs between Linux and Windows, in one place.
public enum Platform {

    #if os(Windows)
    public static let isWindows = true
    #else
    public static let isWindows = false
    #endif

    /// What the OS calls its file browser, for button labels and messages.
    public static var fileManagerName: String { isWindows ? "Explorer" : "Files" }

    // MARK: - Where recordings go

    /// The Desktop, as on the Mac: guests are told to look there.
    ///
    /// Windows asks the shell (Foundation uses the Known Folder API), which
    /// follows a Desktop that OneDrive has moved. Linux reads the XDG user
    /// directory, which is localised ("Schreibtisch", "Bureau"); a system
    /// with no Desktop folder at all gets the home folder rather than a new
    /// directory the user never asked for.
    public static var recordingsDirectory: URL {
        #if os(Windows)
        if let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first {
            return desktop
        }
        let profile = ProcessInfo.processInfo.environment["USERPROFILE"] ?? NSHomeDirectory()
        return URL(fileURLWithPath: profile).appendingPathComponent("Desktop")
        #else
        let home = URL(fileURLWithPath: NSHomeDirectory())
        if let xdg = xdgUserDirectory("DESKTOP"), isDirectory(xdg) {
            return xdg
        }
        let desktop = home.appendingPathComponent("Desktop")
        return isDirectory(desktop) ? desktop : home
        #endif
    }

    /// Where settings.json lives: %APPDATA%\DoublEnder or ~/.config/DoublEnder.
    public static var settingsDirectory: URL {
        let env = ProcessInfo.processInfo.environment
        #if os(Windows)
        let base = env["APPDATA"].map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("AppData/Roaming")
        #else
        let base = env["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config")
        #endif
        return base.appendingPathComponent(AppInfo.name)
    }

    /// `XDG_<name>_DIR` from ~/.config/user-dirs.dirs, with $HOME expanded.
    static func xdgUserDirectory(_ name: String) -> URL? {
        let env = ProcessInfo.processInfo.environment
        let configHome = env["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? NSHomeDirectory() + "/.config"
        guard let text = try? String(contentsOfFile: configHome + "/user-dirs.dirs", encoding: .utf8) else {
            return nil
        }
        return parseXDGUserDirs(text, key: "XDG_\(name)_DIR", home: NSHomeDirectory())
    }

    /// Parser for user-dirs.dirs lines such as `XDG_DESKTOP_DIR="$HOME/Desktop"`.
    public static func parseXDGUserDirs(_ text: String, key: String, home: String) -> URL? {
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), line.hasPrefix(key + "=") else { continue }
            var value = String(line.dropFirst(key.count + 1))
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            value = value.replacingOccurrences(of: "$HOME", with: home)
            guard value.hasPrefix("/") else { return nil }
            // "$HOME/" alone means the directory is disabled.
            if value.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ==
                home.trimmingCharacters(in: CharacterSet(charactersIn: "/")) {
                return nil
            }
            return URL(fileURLWithPath: value)
        }
        return nil
    }

    static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    // MARK: - Showing files

    /// Opens the file browser with `file` selected where the platform allows,
    /// else at its folder.
    public static func reveal(_ file: URL) {
        #if os(Windows)
        let windir = ProcessInfo.processInfo.environment["WINDIR"] ?? "C:\\Windows"
        run(windir + "\\explorer.exe", ["/select,", file.path])
        #else
        // The FileManager1 D-Bus interface selects the file in GNOME Files,
        // Dolphin, Nemo and others; xdg-open of the folder is the fallback.
        let uri = file.absoluteString
        if let dbus = findExecutable("dbus-send"),
           run(dbus, ["--session", "--print-reply", "--dest=org.freedesktop.FileManager1",
                      "--type=method_call", "/org/freedesktop/FileManager1",
                      "org.freedesktop.FileManager1.ShowItems",
                      "array:string:\(uri)", "string:"], wait: true) == 0 {
            return
        }
        if let open = findExecutable("xdg-open") {
            run(open, [file.deletingLastPathComponent().path])
        }
        #endif
    }

    /// Opens a web page in the default browser.
    public static func openURL(_ url: URL) {
        #if os(Windows)
        let windir = ProcessInfo.processInfo.environment["WINDIR"] ?? "C:\\Windows"
        run(windir + "\\explorer.exe", [url.absoluteString])
        #else
        if let open = findExecutable("xdg-open") { run(open, [url.absoluteString]) }
        #endif
    }

    @discardableResult
    static func run(_ executable: String, _ arguments: [String], wait: Bool = false) -> Int32? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        guard wait else { return 0 }
        process.waitUntilExit()
        return process.terminationStatus
    }

    // MARK: - Finding programs

    /// The folder holding this executable, where a release ships its
    /// resources and, on Windows, ffmpeg.exe.
    public static var executableDirectory: URL? {
        Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent()
    }

    /// `name` next to this executable, else on PATH.
    public static func findExecutable(_ name: String) -> String? {
        let fm = FileManager.default
        let fileName = isWindows && !name.lowercased().hasSuffix(".exe") ? name + ".exe" : name
        var candidates: [String] = []
        if let dir = executableDirectory {
            candidates.append(dir.appendingPathComponent(fileName).path)
        }
        let path = ProcessInfo.processInfo.environment["PATH"]
            ?? ProcessInfo.processInfo.environment["Path"] ?? ""
        for dir in path.split(separator: isWindows ? ";" : ":") where !dir.isEmpty {
            candidates.append(URL(fileURLWithPath: String(dir)).appendingPathComponent(fileName).path)
        }
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }

    // MARK: - Time

    /// Monotonic seconds, for timers and watchdogs.
    public static func now() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }
}
