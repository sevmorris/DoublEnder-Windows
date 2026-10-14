/**********************************************************************************************
*
*   rglfw - raylib GLFW single file compilation
*
*   This file includes latest GLFW sources (https://github.com/glfw/glfw) to be compiled together
*   with raylib for all supported platforms, this way, no external dependencies are required.
*
*   LICENSE: zlib/libpng
*
*   Copyright (c) 2017-2024 Ramon Santamaria (@raysan5)
*
*   This software is provided "as-is", without any express or implied warranty. In no event
*   will the authors be held liable for any damages arising from the use of this software.
*
*   Permission is granted to anyone to use this software for any purpose, including commercial
*   applications, and to alter it and redistribute it freely, subject to the following restrictions:
*
*     1. The origin of this software must not be misrepresented; you must not claim that you
*     wrote the original software. If you use this software in a product, an acknowledgment
*     in the product documentation would be appreciated but is not required.
*
*     2. Altered source versions must be plainly marked as such, and must not be misrepresented
*     as being the original software.
*
*     3. This notice may not be removed or altered from any source distribution.
*
**********************************************************************************************/

//#define _GLFW_BUILD_DLL           // To build shared version
// Ref: http://www.glfw.org/docs/latest/compile.html#compile_manual

// Platform options:
// _GLFW_WIN32      to use the Win32 API
// _GLFW_X11        to use the X Window System
// _GLFW_WAYLAND    to use the Wayland API (experimental and incomplete)
// _GLFW_COCOA      to use the Cocoa frameworks
//
// On Linux, _GLFW_X11 and _GLFW_WAYLAND can be combined

//----------------------------------------------------------------------------------
// Feature Test Macros required for this module
//----------------------------------------------------------------------------------
#if (defined(__linux__) || defined(PLATFORM_WEB)) && (_POSIX_C_SOURCE < 199309L)
    #undef _POSIX_C_SOURCE
    #define _POSIX_C_SOURCE 199309L // Required for: CLOCK_MONOTONIC if compiled with c99 without gnu ext.
#endif
#if (defined(__linux__) || defined(PLATFORM_WEB)) && !defined(_GNU_SOURCE)
    #undef _GNU_SOURCE
    #define _GNU_SOURCE // Required for: ppoll if compiled with c99 without gnu ext.
#endif

#if defined(_WIN32) || defined(__CYGWIN__)
    #define _GLFW_WIN32
#endif
#if defined(__linux__)
    #if !defined(_GLFW_WAYLAND) && !defined(_GLFW_X11)
        #error "Cannot disable Wayland and X11 at the same time"
    #endif
#endif
#if defined(__FreeBSD__) || defined(__OpenBSD__) || defined(__NetBSD__) || defined(__DragonFly__)
    #define _GLFW_X11
#endif
#if defined(__APPLE__)
    #define _GLFW_COCOA
    #define _GLFW_USE_MENUBAR       // To create and populate the menu bar when the first window is created
    #define _GLFW_USE_RETINA        // To have windows use the full resolution of Retina displays
#endif
#if defined(__TINYC__)
    #define _WIN32_WINNT_WINXP      0x0501
#endif

// Common modules to all platforms
#include "external/glfw/src/init.c"
#include "external/glfw/src/platform.c"
#include "external/glfw/src/context.c"
#include "external/glfw/src/monitor.c"
#include "external/glfw/src/window.c"
#include "external/glfw/src/input.c"
#include "external/glfw/src/vulkan.c"

#if defined(_WIN32) || defined(__CYGWIN__)
    #include "external/glfw/src/win32_init.c"
    #include "external/glfw/src/win32_module.c"
    #include "external/glfw/src/win32_monitor.c"
    #include "external/glfw/src/win32_window.c"
    #include "external/glfw/src/win32_joystick.c"
    #include "external/glfw/src/win32_time.c"
    #include "external/glfw/src/win32_thread.c"
    #include "external/glfw/src/wgl_context.c"

    #include "external/glfw/src/egl_context.c"
    #include "external/glfw/src/osmesa_context.c"
#endif

#if defined(__linux__)
    #include "external/glfw/src/posix_module.c"
    #include "external/glfw/src/posix_thread.c"
    #include "external/glfw/src/posix_time.c"
    #include "external/glfw/src/posix_poll.c"
    #include "external/glfw/src/linux_joystick.c"
    #include "external/glfw/src/xkb_unicode.c"

    #include "external/glfw/src/egl_context.c"
    #include "external/glfw/src/osmesa_context.c"

    #if defined(_GLFW_WAYLAND)
        #include "external/glfw/src/wl_init.c"
        #include "external/glfw/src/wl_monitor.c"
        #include "external/glfw/src/wl_window.c"
    #endif
    #if defined(_GLFW_X11)
        #include "external/glfw/src/x11_init.c"
        #include "external/glfw/src/x11_monitor.c"
        #include "external/glfw/src/x11_window.c"
        #include "external/glfw/src/glx_context.c"
    #endif
#endif

#if defined(__FreeBSD__) || defined(__OpenBSD__) || defined( __NetBSD__) || defined(__DragonFly__)
    #include "external/glfw/src/posix_module.c"
    #include "external/glfw/src/posix_thread.c"
    #include "external/glfw/src/posix_time.c"
    #include "external/glfw/src/posix_poll.c"
    #include "external/glfw/src/null_joystick.c"
    #include "external/glfw/src/xkb_unicode.c"

    #include "external/glfw/src/x11_init.c"
    #include "external/glfw/src/x11_monitor.c"
    #include "external/glfw/src/x11_window.c"
    #include "external/glfw/src/glx_context.c"

    #include "external/glfw/src/egl_context.c"
    #include "external/glfw/src/osmesa_context.c"
#endif

#if defined(__APPLE__)
    #include "external/glfw/src/posix_module.c"
    #include "external/glfw/src/posix_thread.c"
    #include "external/glfw/src/cocoa_init.m"
    #include "external/glfw/src/cocoa_joystick.m"
    #include "external/glfw/src/cocoa_monitor.m"
    #include "external/glfw/src/cocoa_window.m"
    #include "external/glfw/src/cocoa_time.c"
    #include "external/glfw/src/nsgl_context.m"

    #include "external/glfw/src/egl_context.c"
    #include "external/glfw/src/osmesa_context.c"
#endif

//----------------------------------------------------------------------------------
// DoublEnder patch: the pointer's position on screen, read from the system.
//
// Moving a borderless window by dragging it needs the pointer in screen
// coordinates. Deriving that from the window position plus the in-window
// pointer position feeds back on itself: while the window moves, the two
// update at different times, and the window shakes. The system knows where
// the pointer is regardless of the window.
//----------------------------------------------------------------------------------
#include "include/de_window.h"

int DE_GetCursorScreenPosition(int *x, int *y)
{
#if defined(_WIN32) || defined(__CYGWIN__)
    POINT point;
    if (!GetCursorPos(&point)) return 0;
    *x = point.x;
    *y = point.y;
    return 1;
#elif defined(_GLFW_X11)
    if (_glfw.x11.display == NULL) return 0;
    Window root, child;
    int rootX, rootY, windowX, windowY;
    unsigned int mask;
    if (!XQueryPointer(_glfw.x11.display, _glfw.x11.root, &root, &child,
                       &rootX, &rootY, &windowX, &windowY, &mask)) return 0;
    *x = rootX;
    *y = rootY;
    return 1;
#else
    (void)x; (void)y;
    return 0;
#endif
}

//----------------------------------------------------------------------------------
// DoublEnder patch: hand a drag of the borderless window to the window manager.
//
// Moving the window from the app means agreeing with the window manager on
// screen coordinates, and on scaled Wayland desktops (XWayland) the two can
// disagree. Toolkits with custom title bars ask the window manager to run the
// move instead, as a title-bar drag would: _NET_WM_MOVERESIZE on X11, a
// caption-click on Windows. Window snapping then works as well.
//
// The window manager takes the pointer until the button comes up, so the
// release never reaches GLFW; it is reported here so raylib doesn't think the
// button is still held.
//----------------------------------------------------------------------------------
int DE_BeginWindowMove(void)
{
    _GLFWwindow *window = _glfw.windowListHead;
    if (window == NULL) return 0;

#if defined(_WIN32) || defined(__CYGWIN__)
    POINT point;
    if (!GetCursorPos(&point)) return 0;
    ReleaseCapture();
    // Runs the system's move loop until the button is released.
    SendMessageW(window->win32.handle, WM_NCLBUTTONDOWN, HTCAPTION, MAKELPARAM(point.x, point.y));
    _glfwInputMouseClick(window, GLFW_MOUSE_BUTTON_LEFT, GLFW_RELEASE, 0);
    return 1;
#elif defined(_GLFW_X11)
    if (_glfw.x11.display == NULL) return 0;
    Window root, child;
    int rootX, rootY, windowX, windowY;
    unsigned int mask;
    if (!XQueryPointer(_glfw.x11.display, _glfw.x11.root, &root, &child,
                       &rootX, &rootY, &windowX, &windowY, &mask)) return 0;

    // The press gave this client an implicit pointer grab; the window
    // manager needs it to start the move.
    XUngrabPointer(_glfw.x11.display, CurrentTime);

    XEvent event = { 0 };
    event.xclient.type = ClientMessage;
    event.xclient.window = window->x11.handle;
    event.xclient.message_type = XInternAtom(_glfw.x11.display, "_NET_WM_MOVERESIZE", False);
    event.xclient.format = 32;
    event.xclient.data.l[0] = rootX;
    event.xclient.data.l[1] = rootY;
    event.xclient.data.l[2] = 8;    // _NET_WM_MOVERESIZE_MOVE
    event.xclient.data.l[3] = 1;    // Button1
    event.xclient.data.l[4] = 1;    // source: a normal application
    XSendEvent(_glfw.x11.display, _glfw.x11.root, False,
               SubstructureRedirectMask | SubstructureNotifyMask, &event);
    XFlush(_glfw.x11.display);

    _glfwInputMouseClick(window, GLFW_MOUSE_BUTTON_LEFT, GLFW_RELEASE, 0);
    return 1;
#else
    return 0;
#endif
}

//----------------------------------------------------------------------------------
// DoublEnder patch: the key that types a letter in the current layout.
//
// raylib's key codes are physical positions named after the US layout, so on
// AZERTY KEY_Q is the key labelled A, and Ctrl+A would quit. Shortcuts follow
// the label, as in other apps: this asks GLFW what each letter and
// punctuation key types now, and falls back to the US position when no key
// types the letter (Cyrillic and Greek layouts, as other apps do).
//----------------------------------------------------------------------------------
int DE_ShortcutKey(int letter)
{
    static const int punctuation[] = {
        GLFW_KEY_APOSTROPHE, GLFW_KEY_COMMA, GLFW_KEY_MINUS, GLFW_KEY_PERIOD, GLFW_KEY_SLASH,
        GLFW_KEY_SEMICOLON, GLFW_KEY_EQUAL, GLFW_KEY_LEFT_BRACKET, GLFW_KEY_BACKSLASH,
        GLFW_KEY_RIGHT_BRACKET, GLFW_KEY_GRAVE_ACCENT
    };
    const int punctuationCount = (int)(sizeof(punctuation)/sizeof(punctuation[0]));

    if (letter >= 'A' && letter <= 'Z') letter += 'a' - 'A';
    if (letter < 'a' || letter > 'z') return 0;
    const int usKey = GLFW_KEY_A + (letter - 'a');
    if (!_glfw.initialized) return usKey;

    for (int i = 0; i < 26 + punctuationCount; i++)
    {
        const int key = (i < 26)? GLFW_KEY_A + i : punctuation[i - 26];
        // A key this keyboard lacks has no scancode; asking its name would
        // raise a GLFW error, which raylib logs.
        if (glfwGetKeyScancode(key) < 0) continue;
        const char *name = glfwGetKeyName(key, 0);
        if ((name != NULL) && (name[0] != '\0') && (name[1] == '\0') &&
            ((name[0] == letter) || (name[0] == letter - ('a' - 'A')))) return key;
    }
    return usKey;
}
