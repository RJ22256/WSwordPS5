// (WSword) Slow Time - a WSword ability (runtime/ability.c): L3 + R3 slows the world to a third for a few seconds.
#pragma once
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

bool ability_enabled(void);
void ability_set_enabled(bool on);
void ability_trigger(void);
bool ability_running(void);
float ability_progress(void);   // 0: not running, else 0..1 through it
float ability_cooldown(void);   // the cooldown left, 0..1
float ability_time_scale(bool blocked);   // hle/framepace.c: the game's time step times this
uint64_t ability_input(uint64_t buttons);  // hle/input.c: L3 + R3 triggers it; the buttons for the game

#ifdef __cplusplus
}
#endif
