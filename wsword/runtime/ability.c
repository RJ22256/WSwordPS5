// (WSword) Slow Time: a WSword ability - the whole world slows to a third of its speed for a few seconds, Link with
// it, as the game's own slow motion when aiming in mid-air, but at will. Pressed with both sticks (L3 + R3) together;
// then a cooldown. The game's clock is the runtime's already (hle/framepace.c rt_vfr_update tells the game how long
// each frame took): while the ability runs it tells it a shorter time - every part of the game that moves by the
// clock (Havok, animation, AI, the time of day, stamina) slows together. Never in the menus or the cutscenes.
// Its switch: abilities.ini next to the game's files (on by default). The look and sound: ui/ability_fx.mm.
#include <math.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "ability.h"
#include "platform.h"

enum { DURATION_MS = 7000, RAMP_MS = 350, COOLDOWN_MS = 20000 };
#define SLOW_SCALE 0.33f

static _Atomic uint64_t g_start_ms, g_ready_ms;   // (0: never)
static atomic_bool g_loaded, g_enabled = true;

static uint64_t now_ms(void) { return plat_now_ns() / 1000000ull; }

static void load(void) {
    if (atomic_exchange(&g_loaded, true)) return;
    FILE *f = fopen("abilities.ini", "r");
    if (!f) return;
    char line[128];
    int v;
    while (fgets(line, sizeof line, f))
        if (sscanf(line, " slow_time = %d", &v) == 1) g_enabled = v != 0;
    fclose(f);
}

bool ability_enabled(void) { load(); return g_enabled; }
void ability_set_enabled(bool on) {
    load();
    g_enabled = on;
    FILE *f = fopen("abilities.ini", "w");
    if (f) fprintf(f, "# WSword's abilities\nslow_time = %d\n", on ? 1 : 0), fclose(f);
}

void ability_trigger(void) {
    load();
    if (!g_enabled) return;
    uint64_t t = now_ms();
    if (t < g_ready_ms) return;   // (cooling down)
    g_start_ms = t;
    g_ready_ms = t + DURATION_MS + COOLDOWN_MS;
    fprintf(stderr, "[ability] Slow Time\n");
}

// 0 not running, else how far through it is (0..1)
float ability_progress(void) {
    uint64_t s = g_start_ms, t = now_ms();
    if (!s || t >= s + DURATION_MS) return 0;
    return (float)(t - s) / DURATION_MS + 1e-6f;
}
// the cooldown left, 0..1 (1: just used)
float ability_cooldown(void) {
    uint64_t r = g_ready_ms, t = now_ms();
    if (!r || t >= r) return 0;
    return (float)(r - t) / (DURATION_MS + COOLDOWN_MS);
}
bool ability_running(void) { return ability_progress() > 0; }

// hle/framepace.c: the game's time step times this (1: as it is). blocked: a menu, a cutscene or the pause - the world
// runs normally there (and the ability waits it out)
float ability_time_scale(bool blocked) {
    if (blocked) return 1;
    uint64_t s = g_start_ms, t = now_ms();
    if (!s || t >= s + DURATION_MS) return 1;
    float in = (float)(t - s), out = (float)(s + DURATION_MS - t);
    float k = fminf(1.0f, fminf(in, out) / RAMP_MS);   // (eased in and out: no jolt)
    k = k * k * (3 - 2 * k);
    return 1 - (1 - SLOW_SCALE) * k;
}

// hle/input.c: both sticks pressed together (L3 + R3) - their bits, just pressed. Returns the buttons for the game
// (the pair taken while it's held: the game neither crouches nor zooms for it)
uint64_t ability_input(uint64_t buttons) {
    enum { L3 = 1u << 4, R3 = 1u << 5 };
    static bool was;
    bool both = (buttons & (L3 | R3)) == (L3 | R3);
    if (both && !was) ability_trigger();
    was = both;
    return both ? buttons & ~(uint64_t)(L3 | R3) : buttons;
}
