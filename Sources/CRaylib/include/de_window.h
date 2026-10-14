// DoublEnder additions to raylib's desktop platform (see the end of rglfw.c).
#ifndef DE_WINDOW_H
#define DE_WINDOW_H

// The pointer's position in screen pixels, the units SetWindowPosition and
// GetWindowPosition use. Returns 0 if the system can't say.
int DE_GetCursorScreenPosition(int *x, int *y);

// Asks the window manager to move the window with the pointer, as a drag
// of a title bar does. Call while the left button is down. Returns 0 if
// the platform has no way to do this.
int DE_BeginWindowMove(void);

#endif
