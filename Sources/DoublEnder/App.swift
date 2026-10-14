import CRaylib
import DoublEnderCore
import Foundation
#if os(Linux)
import Glibc
#endif

/// The window and the main loop.
final class App {
    let controller: RecorderController
    let renderer: Renderer
    let input = Input()
    let faceplate: FaceplateView
    let overlays: Overlays
    /// Development aid: see `UITour`.
    var tour: UITour?
    /// Another copy is running: this one only says so, then quits. It never
    /// launches the recorder, so it runs no crash recovery and saves no
    /// settings.
    var isDuplicateInstance = false
    private var exitRequested = false

    /// The grab point relative to the window origin, in screen pixels.
    private var dragGrab: (x: Int32, y: Int32)?
    private var lastDragTarget: (x: Int32, y: Int32)?

    init(controller: RecorderController, resources: URL) {
        self.controller = controller
        renderer = Renderer(resources: resources)
        faceplate = FaceplateView(renderer: renderer, input: input, controller: controller)
        overlays = Overlays(renderer: renderer, input: input, controller: controller, faceplate: faceplate)
    }

    func run() {
        SetTraceLogLevel(Int32(LOG_WARNING.rawValue))
        guard openWindow() else {
            controller.engine.shutdown()
            relaunchWithoutGLXVendorOverride()
            Log.error("Could not open a window: the graphics driver offered no usable OpenGL 3.3 configuration.")
            // A Windows release build has no console, so without this the
            // guest would see nothing at all.
            Platform.showErrorBox(
                title: AppInfo.name,
                message: "DoublEnder couldn't open its window: this computer's graphics driver doesn't offer OpenGL 3.3, which DoublEnder needs.\n\nUpdating the graphics driver usually fixes this. On a remote desktop or a virtual machine, run DoublEnder on the computer itself.")
            return
        }
        defer { CloseWindow() }
        // The close request is ours to answer: a take may be running.
        SetExitKey(Int32(KEY_NULL.rawValue))
        SetTargetFPS(60)
        let icon = LoadImage(renderer.resources.appendingPathComponent("Images/app_icon.png").path)
        SetWindowIcon(icon)
        UnloadImage(icon)

        if isDuplicateInstance {
            presentAlreadyRunning()
        } else {
            controller.launch()
        }

        while !controller.shouldQuit && !exitRequested {
            pace()
            if WindowShouldClose() { requestQuit() }
            MainQueue.drain()
            controller.tick()
            renderer.updatePixelScale()

            let dialog = controller.dialogs.current
            let layer: Input.Layer = dialog != nil ? .dialog : (faceplate.popover != nil ? .popover : .base)
            input.beginFrame(topLayer: layer)
            handleShortcuts(layer: layer)
            if controller.isCurrentlyRecording || controller.isStopping { faceplate.popover = nil }

            BeginDrawing()
            ClearBackground(isTransparent ? Theme.clear : Theme.rgb(0x2B2B2B))
            let time = GetTime()
            faceplate.draw(time: time)
            overlays.drawPopover()
            if let dialog { overlays.drawDialog(dialog, time: time) }
            tour?.capture(app: self)
            EndDrawing()

            handleWindowDrag(layer: layer)
            input.endFrame()
            tour?.step(app: self)
        }
        controller.engine.shutdown()
    }

    /// A see-through, antialiased window where the driver allows, else the
    /// best it does allow: some GLX setups have no framebuffer config that
    /// is both transparent and multisampled.
    private func openWindow() -> Bool {
        let base = FLAG_WINDOW_UNDECORATED.rawValue | FLAG_WINDOW_HIGHDPI.rawValue
            | FLAG_WINDOW_ALWAYS_RUN.rawValue | FLAG_VSYNC_HINT.rawValue
        let attempts = [
            base | FLAG_WINDOW_TRANSPARENT.rawValue | FLAG_MSAA_4X_HINT.rawValue,
            base | FLAG_WINDOW_TRANSPARENT.rawValue,
            base | FLAG_MSAA_4X_HINT.rawValue,
            base,
        ]
        // A failed attempt is expected on some drivers; don't log each one.
        SetTraceLogLevel(Int32(LOG_ERROR.rawValue))
        defer { SetTraceLogLevel(Int32(LOG_WARNING.rawValue)) }
        for flags in attempts {
            SetConfigFlags(UInt32(flags))
            InitWindow(Int32(Theme.windowWidth.rounded()), Int32(Theme.windowHeight.rounded()), AppInfo.name)
            if IsWindowReady() {
                isTransparent = flags & FLAG_WINDOW_TRANSPARENT.rawValue != 0
                return true
            }
        }
        return false
    }

    /// libglvnd's `__GLX_VENDOR_LIBRARY_NAME` sends every X11 app to one
    /// vendor's OpenGL. Hybrid-graphics tools (optimus-manager, PRIME
    /// setups) export it as "nvidia" for the whole session, and when that
    /// GPU isn't usable — driver not loaded, card passed through to a VM —
    /// no context can be made at all. Restart once without it, so libglvnd
    /// picks the driver of the screen the window is actually on.
    private func relaunchWithoutGLXVendorOverride() {
        #if os(Linux)
        let env = ProcessInfo.processInfo.environment
        guard let vendor = env["__GLX_VENDOR_LIBRARY_NAME"], env["DOUBLENDER_GLX_RETRY"] == nil else { return }
        Log.info("No OpenGL context with __GLX_VENDOR_LIBRARY_NAME=\(vendor); restarting without it.")
        unsetenv("__GLX_VENDOR_LIBRARY_NAME")
        setenv("DOUBLENDER_GLX_RETRY", "1", 1)
        // The executable's real path, not /proc/self/exe: the new process
        // takes its name from the path, and should still be "DoublEnder".
        let path = Bundle.main.executableURL?.resolvingSymlinksInPath().path ?? "/proc/self/exe"
        execv(path, UnsafePointer(CommandLine.unsafeArgv))
        #endif
    }

    /// Without a transparent framebuffer the plate's rounded corners show
    /// whatever the window is cleared to.
    private var isTransparent = true

    private var targetFPS: Int32 = 60

    /// Full frame rate only while the guest is looking: for most of a
    /// session the window sits behind the call, on a laptop whose fan the
    /// mic can hear. The audio never waits on the frame rate.
    private func pace() {
        let fps: Int32 = IsWindowMinimized() ? 5 : (IsWindowFocused() ? 60 : 30)
        guard fps != targetFPS else { return }
        targetFPS = fps
        SetTargetFPS(fps)
    }

    private func requestQuit() {
        if isDuplicateInstance {
            exitRequested = true
        } else {
            controller.requestQuit()
        }
    }

    private func presentAlreadyRunning() {
        controller.dialogs.present(Dialog(
            icon: .warning, title: "ALREADY OPEN",
            message: "DoublEnder is already running. Look for its window; it may be minimised.",
            buttons: [.init("OK", isDefault: true) { [weak self] in self?.exitRequested = true }]))
    }

    private func handleShortcuts(layer: Input.Layer) {
        // Ctrl+Q and Ctrl+W, as ⌘Q and ⌘W on the Mac.
        if input.shortcut("q") || input.shortcut("w") { requestQuit() }
        if input.shortcut("m") { MinimizeWindow() }
    }

    /// Dragging anywhere that isn't a control moves the window, as the
    /// Mac's WindowDragArea does: there is no title bar to hold.
    ///
    /// The window manager runs the move, as for a title-bar drag
    /// (`DE_BeginWindowMove`), so screen coordinates and display scaling are
    /// its business and snapping works. Where that isn't available the
    /// window follows the pointer's position on screen, read from the system.
    private func handleWindowDrag(layer: Input.Layer) {
        var x: Int32 = 0, y: Int32 = 0
        if input.pressed && !input.pressClaimed && layer != .popover && input.focusedField == nil {
            if DE_BeginWindowMove() != 0 { return }
            if DE_GetCursorScreenPosition(&x, &y) != 0 {
                let window = GetWindowPosition()
                dragGrab = (x - Int32(window.x), y - Int32(window.y))
                lastDragTarget = nil
            }
        }
        guard let grab = dragGrab else { return }
        guard input.down else { dragGrab = nil; return }
        guard DE_GetCursorScreenPosition(&x, &y) != 0 else { return }
        let target = (x: x - grab.x, y: y - grab.y)
        if let last = lastDragTarget, last == target { return }
        SetWindowPosition(target.x, target.y)
        lastDragTarget = target
    }

    /// Saves the frame just drawn as a PNG.
    func screenshot(to path: String) {
        // Draws are batched until EndDrawing; starting a scissor flushes the
        // batch, so the capture holds the whole frame.
        BeginScissorMode(0, 0, GetScreenWidth(), GetScreenHeight())
        EndScissorMode()
        let image = LoadImageFromScreen()
        _ = ExportImage(image, path)
        UnloadImage(image)
    }
}
