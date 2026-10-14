# DoublEnder for Windows and Linux

The DoublEnder Local recorder, rebuilt as a Swift package that runs on Windows and Linux. It has the same faceplate and one-button flow as the Mac app. Its crash-recovery sidecar uses the same file format, so a `.pcmrec` file can be recovered on any of the three systems. The Mac app in `../DoublEnder` is untouched; this folder is self-contained.

| | Status |
|---|---|
| Linux | Built and tested on Arch Linux (KDE Plasma on Wayland, PipeWire, AMD graphics): records WAV and AAC, crash recovery, UI. |
| Windows | Written for Windows but **not yet built on Windows.** `.github/workflows/cross-platform.yml` builds, tests and packages it on a Windows runner. |

## Building

You need Swift 6.0 or later. Neither bundled C library needs development packages for audio or OpenGL: miniaudio loads PipeWire/PulseAudio/ALSA (Linux) or WASAPI (Windows) when it runs, and GLFW loads X11 and OpenGL when it runs.

### Linux

1. Install Swift with [swiftly](https://www.swift.org/install/linux/). On a distribution swiftly doesn't list (Arch, for example), `swiftly init --platform ubuntu24.04` works. The toolchain may then look for `libncurses.so.6` and `libxml2.so.2` by their Ubuntu names; on Arch those come from `ncurses` (`libncursesw.so.6`) and `libxml2-legacy`.
2. Install the X11 headers GLFW compiles against:
   - Debian/Ubuntu: `libx11-dev libxrandr-dev libxinerama-dev libxcursor-dev libxi-dev libxext-dev`
   - Fedora: `libX11-devel libXrandr-devel libXinerama-devel libXcursor-devel libXi-devel libXext-devel`
   - Arch: already included with `libx11` and friends.
3. Optional: install `ffmpeg`, which enables AAC/M4A (see below).

```sh
swift build
swift run DoublEnder
swift test
scripts/package-linux.sh       # dist/DoublEnder-<version>-linux-<arch>.tar.gz
```

The package is one statically linked binary plus `Resources/`. It runs on any distribution whose glibc is at least as new as the build machine's, so build releases on an older distribution; the CI uses Ubuntu 24.04.

### Windows

1. Install Swift: `winget install --id Swift.Toolchain` (it brings the Visual Studio build tools it needs; see [swift.org/install/windows](https://www.swift.org/install/windows/)).
2. In a new terminal:

```powershell
swift build
swift run DoublEnder
swift test
pwsh scripts/package-windows.ps1 -Ffmpeg C:\path\to\ffmpeg.exe   # dist\DoublEnder-<version>-windows-x64.zip
```

The zip contains `DoublEnder.exe`, `Resources\`, the Swift runtime DLLs, the Visual C++ runtime, and `ffmpeg.exe` if you passed one. Guests unzip it and double-click the exe. A release build is a GUI program (no console window).

## Layout

| Target | What it is |
|---|---|
| `CMiniaudio` | [miniaudio](https://miniaud.io) 0.11.25 and `de_audio.c`, a small capture layer. The real-time callback copies native-format frames into a lock-free ring buffer and never enters Swift. |
| `CRaylib` | [raylib](https://www.raylib.com) 5.5 with its bundled GLFW, for the window and drawing. |
| `DoublEnderCore` | Everything except drawing: `AudioEngine` (devices, the pump thread, watchdogs), `TakeWriter` (24-bit WAV, the sidecar, AAC), `PCMSidecar`, `CrashRecovery`, and `RecorderController`, which ports `RecorderViewModel`. |
| `DoublEnder` | The faceplate UI and main loop, plus command-line diagnostics. |

Names, messages and behaviour follow `../docs/THEORY_OF_OPERATION.md` wherever the platforms allow:

- The four watchdogs: first buffer (5 s), data flow (3 s), the 1-second input-health poll, and dropped audio.
- The disconnect latch: the first failure path wins.
- The disk checks: fail closed at 50 MB (AAC) or 200 MB (WAV), polled every 5 s while recording.
- The mono mix: the Mac's measured AVAssetWriter weights, applied to miniaudio's channel map.
- The DEP2 sidecar, synced every 512 KB, and launch-time crash recovery with the same dialogs and the same 8 KB rule.

## Differences from the Mac app

- **AAC needs ffmpeg.** Linux and Windows have no built-in AAC encoder Swift can call. An AAC take records only to the Float32 sidecar while it runs. When it stops, ffmpeg encodes 256 kbps mono at 48 kHz, with the notes in the description tag, into a temporary file that is renamed into place. A take is therefore crash-safe from its first sample. If encoding fails, the sidecar is recovered to a WAV on the spot. Without ffmpeg (next to the app or on `PATH`), the format picker offers WAV only.
- **WAV** is written as on the Mac: 24-bit mono at the device's native rate. The header sizes stay at zero until the take finishes, so a crashed WAV reads as empty and recovery uses the sidecar.
- **Popovers and dialogs** are drawn inside the window, because raylib can't open the Mac's floating panels.
- **Window controls:** the borderless window has small minimise and close buttons in the plate's top-right corner. Ctrl+Q / Ctrl+W quit through the same "Recording in progress" prompt as ⌘Q.
- **Moving the window:** dragging empty parts of the faceplate asks the window manager to run the move, as a title-bar drag does (`_NET_WM_MOVERESIZE` on X11, a caption click on Windows). Moving it from the app jittered on scaled Wayland desktops, where the app's X11 coordinates and the compositor's don't agree.
- **Default input:** each launch starts on the system's default input, not the built-in mic. A newly connected microphone triggers the "Microphone detected — switch?" offer. The Mac only offers USB devices, but Linux and Windows don't say reliably which devices are USB.
- **Loopback inputs** (PulseAudio "Monitor of …" sources, Windows "Stereo Mix") are hidden, as the Mac hides virtual devices.
- **Where takes go:** the Desktop. On Windows that comes from the shell, so it follows OneDrive. On Linux it comes from `XDG_DESKTOP_DIR`, or the home folder if there's no Desktop.
- **Settings** live in `%APPDATA%\DoublEnder\settings.json` or `~/.config/DoublEnder/settings.json`. The filename prefix is still cleared at every launch.
- **The save confirmation** has a "Show in Explorer/Files" button, standing in for the Mac's notification with "Reveal in Finder".
- **Not ported yet:** the Cloud variant (upload, heartbeat), the update checker, the Help window, and system notifications.

## Patches to the vendored libraries

All are marked `DoublEnder patch`:

- `CRaylib/config.h`: raudio is off (miniaudio is used directly), and so are F12 screenshots and Ctrl+F12 GIF capture.
- `CRaylib/rcore.c`, `platforms/rcore_desktop_glfw.c`: a failed window creation returns instead of crashing, so the app can retry with fewer features. Some GLX setups have no framebuffer that is both transparent and multisampled.
- `CRaylib/external/glfw/src/x11_window.c`: two waits for X server replies now give up on wall-clock time. As shipped, they spin forever when other events are queued and the reply never comes. XWayland under KDE Plasma never sends `VisibilityNotify`, so window creation hung.

`CRaylib/rglfw.c` also gains `DE_BeginWindowMove` and `DE_GetCursorScreenPosition` (declared in `include/de_window.h`), which reach GLFW's internals for the window drag.

The app also recovers from a session-wide `__GLX_VENDOR_LIBRARY_NAME=nvidia` (set by optimus-manager and some PRIME setups). When that GPU isn't usable, no OpenGL context can be created, so the app restarts itself once without the variable.

## Diagnostics

```sh
DoublEnder --list-devices          # inputs, what the default one delivers, ffmpeg, Desktop path
DoublEnder --test-record 5 [--wav] # record 5 s without a window and report the file
```

For development, `--recordings-dir DIR` saves takes somewhere other than the Desktop. `--ui-tour DIR` steps through the main screens and saves a screenshot of each. On Windows these print only from a debug build: a release build has no console.

## Known gaps

- Windows has not been run. Check first: capture through WASAPI, the microphone privacy switch (it should show the "Microphone access is turned off" error), the Desktop path under OneDrive, high-DPI scaling, and the transparent window corners.
- On Windows, ffmpeg is started through Foundation's `Process`, which doesn't pass `CREATE_NO_WINDOW`. A console window will probably flash while an AAC take is encoded. Encoding through Media Foundation would fix that and remove the need to ship ffmpeg.
- Linux runs under X11, or XWayland on Wayland desktops. Native Wayland would need GLFW's generated protocol sources.
- Releases are unsigned. Windows SmartScreen will warn on first run until the exe is code-signed.
