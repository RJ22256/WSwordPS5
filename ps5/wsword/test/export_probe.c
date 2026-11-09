// The PS5 export's compile, link and load, off the console (.github/workflows/export-probe.yml): game-code-like C built
// the way WSword Configuration builds the console's game code (runtime/gamebuild.c), then loaded with
// runtime/elfload.c on Linux, its imports bound to the host's own functions.
#include "cpu.h"
#include "simd.h"
#include <setjmp.h>
#include "gamelib.h"
// (what the generated layout.c defines: tools/gamelib_entry.c names them)
const GameLibModule game_modules[1];
const uint32_t game_module_count = 0;
const char game_version[] = "probe";
const GameLibSite game_sites[1];
const uint32_t game_site_count = 0;
extern int rt_probe_host(int);
static int ctor_ran;
__attribute__((constructor)) static void ctor(void) { ctor_ran = 1; }
static const char *const names[] = {"zero", "one", "two"};
__attribute__((visibility("default"))) double probe_entry(double x, int i) {
    char b[8];
    memcpy(b, names[i], 4);
    float s = sqrtf((float)x);  // (inlined as sqrtss: the target isn't freestanding)
    return sin(x) + s + rt_probe_host(i) + ctor_ran + b[0] + (simd_getround() == FE_TONEAREST) + g_fnprof;
}
__attribute__((visibility("default"))) int probe_jmp(void) {  // (setjmp named, not called: the host's jmp_buf differs)
    return (int)sizeof(jmp_buf);
}
