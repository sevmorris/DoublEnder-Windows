// swift-tools-version: 6.0
//
// DoublEnder for Windows and Linux.
//
// The Mac app (sevmorris/DoublEnder, built with Xcode) stays as it is. This package
// rebuilds the same recorder on Swift's Linux and Windows toolchains:
//
//   CMiniaudio      miniaudio (vendored, public domain / MIT-0) plus a small
//                   C capture shim — the real-time callback never enters Swift.
//   CRaylib         raylib 5.5 (vendored, zlib) for the window and drawing.
//   CPlatform       a few OS calls in C: the single-instance lock, and on
//                   Windows a message box and bringing a window forward.
//   DoublEnderCore  everything that isn't pixels: capture engine, WAV and
//                   crash-recovery sidecar writers, the recorder state machine.
//   DoublEnder      the faceplate UI and the main loop.
//
// Neither C library needs system packages to build: miniaudio loads
// PulseAudio / ALSA / WASAPI at runtime, and raylib's GLFW loads X11 and
// OpenGL at runtime on Linux.

import PackageDescription

let package = Package(
    name: "DoublEnder",
    products: [
        .executable(name: "DoublEnder", targets: ["DoublEnder"]),
    ],
    targets: [
        .target(
            name: "CMiniaudio",
            path: "Sources/CMiniaudio",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedLibrary("dl", .when(platforms: [.linux])),
                .linkedLibrary("pthread", .when(platforms: [.linux])),
                .linkedLibrary("m", .when(platforms: [.linux])),
                .linkedLibrary("ole32", .when(platforms: [.windows])),
            ]
        ),
        .target(
            name: "CRaylib",
            path: "Sources/CRaylib",
            // rcore.c and rglfw.c #include these directly; compiling them on
            // their own would duplicate every symbol.
            exclude: ["external", "platforms"],
            publicHeadersPath: "include",
            cSettings: [
                // The bundled GLFW's own header, for platforms/rcore_desktop_glfw.c's
                // #include "GLFW/glfw3.h". Without it a system GLFW (Arch's glfw
                // package, say) could stand in silently, and elsewhere it's missing.
                .headerSearchPath("external/glfw/include"),
                .define("PLATFORM_DESKTOP_GLFW"),
                .define("GRAPHICS_API_OPENGL_33"),
                .define("_GNU_SOURCE", .when(platforms: [.linux])),
                // X11 (and XWayland on Wayland desktops); native Wayland would
                // need generated protocol headers.
                .define("_GLFW_X11", .when(platforms: [.linux])),
                .define("_CRT_SECURE_NO_WARNINGS", .when(platforms: [.windows])),
            ],
            linkerSettings: [
                .linkedLibrary("dl", .when(platforms: [.linux])),
                .linkedLibrary("pthread", .when(platforms: [.linux])),
                .linkedLibrary("m", .when(platforms: [.linux])),
                .linkedLibrary("opengl32", .when(platforms: [.windows])),
                .linkedLibrary("gdi32", .when(platforms: [.windows])),
                .linkedLibrary("winmm", .when(platforms: [.windows])),
                .linkedLibrary("user32", .when(platforms: [.windows])),
                .linkedLibrary("shell32", .when(platforms: [.windows])),
            ]
        ),
        .target(
            name: "CPlatform",
            path: "Sources/CPlatform",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedLibrary("user32", .when(platforms: [.windows])),
            ]
        ),
        .target(
            name: "DoublEnderCore",
            dependencies: ["CMiniaudio", "CPlatform"],
            path: "Sources/DoublEnderCore"
        ),
        .executableTarget(
            name: "DoublEnder",
            dependencies: ["DoublEnderCore", "CRaylib"],
            path: "Sources/DoublEnder",
            resources: [.copy("Resources")],
            linkerSettings: [
                // A GUI app on Windows: no console window behind the faceplate.
                .unsafeFlags(["-Xlinker", "/SUBSYSTEM:WINDOWS", "-Xlinker", "/ENTRY:mainCRTStartup"],
                             .when(platforms: [.windows], configuration: .release)),
            ]
        ),
        .testTarget(
            name: "DoublEnderCoreTests",
            dependencies: ["DoublEnderCore"],
            path: "Tests/DoublEnderCoreTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
