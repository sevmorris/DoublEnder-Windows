// DoublEnder additions to raylib's desktop platform (see the end of rglfw.c,
// and de_blend.c).
#ifndef DE_WINDOW_H
#define DE_WINDOW_H

// The pointer's position in screen pixels, the units SetWindowPosition and
// GetWindowPosition use. Returns 0 if the system can't say.
int DE_GetCursorScreenPosition(int *x, int *y);

// Asks the window manager to move the window with the pointer, as a drag
// of a title bar does. Call while the left button is down. Returns 0 if
// the platform has no way to do this.
int DE_BeginWindowMove(void);

// The raylib key code of the key that types `letter` (a-z) in the current
// keyboard layout, for Ctrl shortcuts; the US position if no key types it.
// Returns 0 for anything but a letter.
int DE_ShortcutKey(int letter);

// Alpha blending for a transparent window: colour as raylib's default, alpha
// as "over", so opaque pixels stay opaque (see de_blend.c). Call after
// BeginDrawing; it costs nothing once set.
void DE_UseOverBlending(void);

#endif
