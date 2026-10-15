# DoublEnder for Windows and Linux

The DoublEnder Local recorder, rebuilt as a Swift package that runs on Windows and Linux. It has the same faceplate and one-button flow as the Mac app. Its crash-recovery sidecar uses the same file format, so a `.pcmrec` file can be recovered on any of the three systems. The Mac app lives in [sevmorris/DoublEnder](https://github.com/sevmorris/DoublEnder); this repository holds only the port.

| | Status |
|---|---|
| Linux | Built and tested on Arch Linux (KDE Plasma on Wayland, PipeWire, AMD graphics): records WAV and AAC, crash recovery, UI. CI builds, tests and packages it on Ubuntu 24.04. |
| Windows | Records on a Windows 10 laptop with a USB microphone, after two fixes from its first run there: capture no longer waits on the disk, and only the window's corners are transparent. CI (`.github/workflows/ci.yml`) builds, tests and packages it on Windows Server 2025. Still to check by hand: see Known gaps. |

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

The package is one statically linked binary plus `Resources/`. It runs on any distribution whose glibc is at least as new as the build machine's, so build releases on an older distribution; the CI uses Ubuntu 24.04. Its `install.sh` (from `packaging/`) copies the app to `~/.local/share/DoublEnder` and adds an applications-menu launcher, whose `StartupWMClass` gives the window its icon in the dock; `install.sh --uninstall` removes both. Not every file manager runs a bare binary on double-click.

### Windows

1. Install Swift: `winget install --id Swift.Toolchain` (it brings the Visual Studio build tools it needs; see [swift.org/install/windows](https://www.swift.org/install/windows/)).
2. To package it, install Inno Setup 6: `winget install JRSoftware.InnoSetup`.
3. In a new terminal:

```powershell
swift build
swift run DoublEnder
swift test
pwsh scripts/package-windows.ps1 -Ffmpeg build\ffmpeg-windows\ffmpeg.exe   # dist\DoublEnder-Setup.exe
```

The package script stages `DoublEnder.exe`, `Resources\`, the Swift runtime DLLs, the Visual C++ runtime, and `ffmpeg.exe` with its licence and source note if you passed one, in `dist\DoublEnder-<version>-windows-x64`. It then compiles that folder into `DoublEnder-Setup.exe` with Inno Setup (`packaging/DoublEnder.iss`). That one file is what guests download. It installs for the current user only, into `%LOCALAPPDATA%\Programs\DoublEnder`, so it never asks for an administrator. It adds Start menu and Desktop shortcuts and an entry in Settings > Apps to uninstall it. Setup and the uninstaller wait while DoublEnder is running (they check its single-instance mutex) instead of replacing files under a recording. Settings, the log and the recordings are never the installer's, so upgrades and uninstalls leave them alone. CI installs every build silently on the runner, checks the files and the installed `ffmpeg.exe`, and uninstalls it again. A release build is a GUI program (no console window).

A single portable `.exe` would need the Swift runtime linked into it. On Windows, Swift can do that only in experimental toolchains so far, and the exe would still need the Visual C++ runtime and `ffmpeg.exe` beside it.

`ffmpeg.exe` comes from `scripts/build-ffmpeg-windows.sh`, never from `PATH`: a 5 MB LGPL build of the FFmpeg source pinned in `Vendor/ffmpeg-manifest.env`, with only what the AAC encode needs. It cross-compiles with mingw-w64 and nasm (apt on Ubuntu or WSL, Homebrew on a Mac) into `build/ffmpeg-windows`, along with `ffmpeg-LICENSE.txt` and `ffmpeg-SOURCE.txt`, which the package script requires beside it. The same toolchain rebuilds it byte for byte. CI builds it (cached until the recipe or the pin changes), runs the AAC test through it on Windows, and packages it. `--native` builds the same components for the machine you're on, to try a change to the encode command.

## Releases

Windows and Linux builds are published on this repository's Releases page, never on the Mac app's. The Mac app's update checker and its download links read `sevmorris/DoublEnder`'s latest release, and its `release.sh` prunes every `v…` release there, so a Windows release in that repository would be offered to every Mac and then deleted by the next Mac release.

To release, set the version in `Sources/DoublEnderCore/VersionFormatting.swift`, write `release-notes/v<version>.md`, merge both to `main`, then tag that commit and push the tag:

```sh
git tag v2.6.0x && git push origin v2.6.0x
```

`.github/workflows/release.yml` first checks that the tag is the app's version, that the commit is on `main`, and that the notes exist. Then it builds with CI's own jobs and opens a **draft** release with `DoublEnder-Setup.exe`, `DoublEnder-linux-x86_64.tar.gz`, the symbols zip and `SHA256SUMS.txt`. Nothing is public until the draft is published by hand. Once SignPath is set up (see Code signing policy), the workflow submits the installer for signing before drafting, and waits for the request to be approved in SignPath; it needs the repository variables `SIGNPATH_ORGANIZATION_ID`, `SIGNPATH_PROJECT_SLUG` and `SIGNPATH_SIGNING_POLICY_SLUG` and the secret `SIGNPATH_API_TOKEN`. Every release page links to the code signing policy. The guests' files keep the same names in every release, so `https://github.com/sevmorris/DoublEnder-Windows/releases/latest/download/DoublEnder-Setup.exe` always downloads the newest. Each release carries its build's symbols zip (below), since a dump from that build can only be read with them.

## Code signing policy

Free code signing provided by [SignPath.io](https://about.signpath.io/), certificate by [SignPath Foundation](https://signpath.org/). This has been applied for; until it is in place, releases are unsigned.

What is signed: `DoublEnder-Setup.exe`, the Windows installer, built from this repository by `.github/workflows/release.yml` on GitHub Actions and submitted to SignPath by that workflow. Nothing built anywhere else is signed. Each signing request is approved by hand in SignPath before a release is published. The installer carries third-party programs unsigned: the Swift runtime, the Visual C++ runtime, and `ffmpeg.exe`, which CI builds from the FFmpeg source pinned in `Vendor/ffmpeg-manifest.env`. SignPath's settings for it are in `packaging/signpath-artifact-configuration.xml`.

Team roles:

- Committers and reviewers: [Seven Morris](https://github.com/sevmorris)
- Approvers: [Seven Morris](https://github.com/sevmorris)

Privacy policy: This program will not transfer any information to other networked systems unless specifically requested by the user or the person installing or operating it. DoublEnder makes no network connections at all; recordings, settings and the log stay on the computer.

## Layout

| Target | What it is |
|---|---|
| `CMiniaudio` | [miniaudio](https://miniaud.io) 0.11.25 and `de_audio.c`, a small capture layer. The real-time callback copies native-format frames into a lock-free ring buffer and never enters Swift. `de_audio_win.c` finds which bus (USB, Bluetooth) a Windows input is on. |
| `CRaylib` | [raylib](https://www.raylib.com) 5.5 with its bundled GLFW, for the window and drawing, and DoublEnder's additions to it (see below). |
| `CPlatform` | `de_platform.c`: the single-instance lock, and on Windows a message box and bringing a window forward. `de_child.c`: starting ffmpeg on pipes, with no console window on Windows. |
| `DoublEnderCore` | Everything except drawing: `AudioEngine` (devices, the pump thread, watchdogs), `TakeIO` (the take's disk writes, off the pump), `TakeWriter` (24-bit WAV, the sidecar, AAC), `LiveEncoder` (AAC as it records), `PCMSidecar`, `CrashRecovery`, `InstanceLock`, `Log`, and `RecorderController`, which ports `RecorderViewModel`. |
| `DoublEnder` | The faceplate UI and main loop, plus command-line diagnostics. |

Names, messages and behaviour follow the Mac app's [Theory of Operation](https://github.com/sevmorris/DoublEnder/blob/main/docs/THEORY_OF_OPERATION.md) wherever the platforms allow:

- The four watchdogs: first buffer (5 s), data flow (3 s), the 1-second input-health poll, and dropped audio.
- The disconnect latch: the first failure path wins.
- The disk checks: fail closed at 200 MB (WAV) or, for AAC, at 50 MB plus room for the whole M4A (about 2 MB per recorded minute), in case it has to be encoded again from the sidecar after STOP, polled every 5 s while recording.
- The mono mix: the Mac's measured AVAssetWriter weights, applied to miniaudio's channel map.
- The DEP2 sidecar and launch-time crash recovery, with the same dialogs and the same 8 KB rule. The sidecar is synced every 2.5 s rather than every 512 KB (§3's ~2.7 s at 48 kHz): by time, so a slow sync never limits how fast a backlog is written.
- Capture never waits on the disk, as on the Mac: the pump hands each block to `TakeIO`, which writes the WAV and the sidecar in order on its own queue, holding a slow disk's backlog in memory. The port first wrote on the pump, and on an older Windows laptop the sidecar's syncs held it up long enough to overflow the 10 s ring and fail the take with "Audio was dropped". The log has a line per take: the input format, dropped frames, the longest wait between ring reads, the slowest write and sync, and the largest backlog.

## Differences from the Mac app

- **AAC needs ffmpeg.** Linux and Windows have no built-in AAC encoder Swift can call. ffmpeg encodes an AAC take while it records, as AVAssetWriter does on the Mac: 256 kbps mono at 48 kHz, with the notes in the description tag, into a temporary file that is renamed into place when the take stops, so STOP waits only for its last few blocks. The Float32 sidecar is written beside it, so a take is crash-safe from its first sample. If ffmpeg won't start, stops reading, or leaves an unfinished file, the take is encoded from the sidecar after STOP instead, with "SAVING… N%" on the faceplate (about 3 minutes for a 35-minute take on an older laptop). If that fails too, the sidecar is recovered to a WAV on the spot. The log's line for each take says which way it was saved. Without ffmpeg (next to the app or on `PATH`), the format picker offers WAV only. The Windows installer carries its own minimal build (see Building); Linux uses the system's.
- **WAV** is written as on the Mac: 24-bit mono at the device's native rate. The header sizes stay at zero until the take finishes, so a crashed WAV reads as empty and recovery uses the sidecar.
- **Popovers and dialogs** are drawn inside the window, because raylib can't open the Mac's floating panels.
- **Window controls:** the borderless window has small minimise and close buttons in the plate's top-right corner. Ctrl+Q / Ctrl+W quit through the same "Recording in progress" prompt as ⌘Q, and Ctrl+M minimises. Shortcuts follow the key's label in the current layout, so Ctrl+A on a French keyboard doesn't quit.
- **One copy at a time:** the Mac gets this from LaunchServices; here the app holds a lock (a named mutex on Windows, an `flock` in `$XDG_RUNTIME_DIR` on Linux). A second copy's crash recovery would otherwise treat the first copy's take in progress as abandoned. Launched again on Windows, the app brings the running window forward; on Linux it says it is already open.
- **Moving the window:** dragging empty parts of the faceplate asks the window manager to run the move, as a title-bar drag does (`_NET_WM_MOVERESIZE` on X11, a caption click on Windows). Moving it from the app jittered on scaled Wayland desktops, where the app's X11 coordinates and the compositor's don't agree.
- **Default input:** each launch starts on the system's default input, not the built-in mic. A newly connected microphone triggers the "Microphone detected — switch?" offer, unless it is Bluetooth: earbuds connect on their own mid-call, and their mic is call quality. The Mac offers USB devices only; here anything but Bluetooth is offered, so audio interfaces on other buses are too. The bus comes from the controller's Plug and Play instance ID on Windows (`de_audio_win.c`, as Chromium does it) and from the PulseAudio/PipeWire source name on Linux. `--list-devices` shows it.
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
- `CRaylib/external/sdefl.h`: clang, which defines `_MSC_VER` on Windows, takes the `__builtin_clzl` path rather than `_BitScanReverse`, which it rejects without `<intrin.h>`. `sinfl.h` already does the same.

`CRaylib/rglfw.c` also gains `DE_BeginWindowMove` and `DE_GetCursorScreenPosition` (declared in `include/de_window.h`), which reach GLFW's internals for the window drag, and `DE_ShortcutKey`, which finds the key that types a letter in the current keyboard layout. `CRaylib/de_blend.c` adds `DE_UseOverBlending`, which the main loop calls each frame: raylib's default blending treats alpha like colour, so anything translucent drawn over the screen (its vignette, a dialog's dimming) left that part of the transparent window partly see-through on Windows. It blends alpha as "over" instead, so only the corners show the desktop.

The app also recovers from a session-wide `__GLX_VENDOR_LIBRARY_NAME=nvidia` (set by optimus-manager and some PRIME setups). When that GPU isn't usable, no OpenGL context can be created, so the app restarts itself once without the variable.

## Diagnostics

```sh
DoublEnder --list-devices          # inputs, what the default one delivers, ffmpeg, Desktop path
DoublEnder --test-record 5 [--wav] # record 5 s without a window and report the file
```

For development, `--recordings-dir DIR` saves takes somewhere other than the Desktop. `--ui-tour DIR` steps through the main screens and saves a screenshot of each. On Windows these print only from a debug build: a release build has no console. The diagnostics never run crash recovery, so they are safe beside a running recorder.

The app logs to `%LOCALAPPDATA%\DoublEnder\DoublEnder.log` or `~/.local/state/DoublEnder/DoublEnder.log` (`$XDG_STATE_HOME`), moved aside to `DoublEnder.previous.log` once it passes 1 MB: the file to ask a guest for when something went wrong. It holds errors and device names, never audio or notes. A Windows release build logs only there; elsewhere the log also goes to stderr.

If no OpenGL 3.3 window can be opened, the app says so in a system dialog rather than exiting silently: a message box on Windows, zenity or kdialog on Linux.

Every Windows build is made with debug information, and `package-windows.ps1` puts its `DoublEnder.pdb` in `dist\DoublEnder-<version>-windows-x64-symbols.zip`, never in the installer; CI uploads it as the `DoublEnder-windows-symbols` artifact. With it, a crash or hang dump from that exact build reads down to function names: in WinDbg, `.sympath+ <folder with DoublEnder.pdb>` then `.reload`. A PDB from any other build doesn't match, so keep each one with its build.

## Known gaps

- Windows has been run on one Windows 10 laptop with a USB microphone, which records through WASAPI. Still to check: the microphone privacy switch (it should show the "Microphone access is turned off" error), Bluetooth earbuds (not offered as a new microphone), a second launch (it should bring the first window forward), the Desktop path under OneDrive, high-DPI scaling, and that only the window's corners are transparent.
- AAC on Windows still needs ffmpeg. Media Foundation's AAC encoder would do without it, but it tops out at 192 kbps (and takes 16-bit input), below the Mac's 256 kbps.
- Linux runs under X11, or XWayland on Wayland desktops. Native Wayland would need GLFW's generated protocol sources.
- Releases are unsigned until SignPath signing is in place (see Code signing policy). Until then, Windows SmartScreen warns when `DoublEnder-Setup.exe` is run ("Windows protected your PC": More info, then Run anyway), and Microsoft Defender's machine-learning detection has quarantined it as `Trojan:Win32/Bearfoos.B!ml`, a false positive. The installed app hasn't been flagged.
