// (the PS5) The DualSense's own (ps5/wsword/sdl/sdl_ps5.c ps5_pad_*): the light bar by Link's hearts, the adaptive
// triggers while playing, the touch pad's swipes in the pause menu. Each frame from the input (hle/input.c).
#ifdef __PROSPERO__
#include <math.h>
#include <stdbool.h>
#include <stdint.h>

#include "../framepace.h"
#include "../hle.h"

void ps5_pad_light(uint8_t r, uint8_t g, uint8_t b);
void ps5_pad_triggers(int mode);
void ps5_pad_swipes(bool on);
bool game_flag_s32(const char *name, int32_t *out, int *slot);  // runtime/services/test_warp.c
bool menu_is_open(void);  // runtime/ui/menu.mm: WSword's own menu

void dualsense_frame(void) {
    uint64_t now = plat_now_ns();
    bool menu = framepace_menu_ui(), title = framepace_title_ui(), loading = framepace_loading_ui();
    bool ours = menu_is_open();
    ps5_pad_swipes(menu && !ours);
    ps5_pad_triggers(!menu && !title && !loading && !ours ? 1 : 0);
    // The light bar: the console's blue in menus; in play, by the hearts - green above half, amber above a quarter,
    // red below, and a red pulse at one heart or less
    static uint64_t next_read;
    static int32_t life = -1, max = -1;
    static int slot_life = -1, slot_max = -1;
    if (now >= next_read) {
        next_read = now + 100000000u;  // (ten times a second)
        int32_t l, m;
        bool ok = game_flag_s32("CurrentHart", &l, &slot_life) && game_flag_s32("MaxHartValue", &m, &slot_max);
        // (the game data keeps CurrentHart at 99999 while Link is about - the save's "full" - so it's live only when
        //  it's a real count no bigger than the maximum: else the console's blue)
        if (ok && m > 0 && l >= 0 && l <= m && m <= 160) {
            if (life < 0) LOG("[dualsense] hearts %d/%d quarters: the light bar follows them\n", l, m);
            life = l, max = m;
        } else {
            static bool told;
            if (ok && !told) told = true, LOG("[dualsense] hearts read %d/%d: not a live count, the light bar stays blue\n", l, m);
            life = -1;
        }
    }
    uint8_t r = 0, g = 64, b = 255;
    if (!menu && !title && !loading && life >= 0 && max > 0) {
        float f = (float)life / (float)max;
        if (life <= 4) {
            float k = 0.55f + 0.45f * sinf((float)(now % 1000000000u) * 6.2831853e-9f);
            r = (uint8_t)(255 * k), g = 0, b = 0;
        } else if (f <= 0.25f) r = 255, g = 20, b = 0;
        else if (f <= 0.5f) r = 255, g = 140, b = 0;
        else r = 0, g = 220, b = 70;
    }
    ps5_pad_light(r, g, b);
}
#endif
