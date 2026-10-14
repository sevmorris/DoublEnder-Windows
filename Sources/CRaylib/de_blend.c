// DoublEnder addition: blending that keeps a transparent window's opaque
// pixels opaque.
//
// The window has a transparent framebuffer so the plate's rounded corners
// show the desktop, and the compositor (DWM on Windows) honours every
// pixel's alpha. raylib's BLEND_ALPHA blends alpha like colour:
// dst.a = src.a * src.a + dst.a * (1 - src.a). Anything translucent drawn
// over something opaque leaves the pixel partly see-through: the screen's
// vignette and scanlines over its dark surface made the screen's background
// up to 25% transparent, and a dialog's dimming did the same to the plate.
// This blends colour exactly as before but alpha as "over",
// dst.a = src.a + dst.a * (1 - src.a), so a covered pixel stays covered and
// what is drawn on the cleared corners comes out premultiplied, as the
// compositor expects.
#include "rlgl.h"
#include "include/de_window.h"

void DE_UseOverBlending(void)
{
    rlSetBlendFactorsSeparate(RL_SRC_ALPHA, RL_ONE_MINUS_SRC_ALPHA, RL_ONE, RL_ONE_MINUS_SRC_ALPHA,
                              RL_FUNC_ADD, RL_FUNC_ADD);
    rlSetBlendMode(RL_BLEND_CUSTOM_SEPARATE);
}
