// Builds the game code library (runtime/gamelib.h) on the player's machine, from their own game files: the generator
// (tools/gen.py; shipped frozen as swgen/) turns exefs/main and exefs/sdk into C, the bundled compiler (zig/) builds
// that into <game_dir>/swgame.*. The C and the objects are deleted afterwards.
#pragma once
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    // now and then, from the calling thread: how far the whole build is (0..1) and what it's doing
    void (*progress)(double fraction, const char *step);
    int jobs;  // compiler processes at once (>= 1)
    // (WSword) the PS5's game code (WSword Configuration's PS5 export): built for the console - its CPU, its libc's
    // headers (gamelib-src/ps5-include), an ELF shared object - into <data root>/PS5/swgame.so for its title
    bool ps5;
} GameBuildOpts;

// Where the PS5 export puts the console's game code (and its .id): <data root>/PS5
#define GAMEBUILD_PS5_DIR "PS5"
// The console's game code id (the PS5 target's flags): what WSword for the PS5 of the same version loads
const char *gamebuild_ps5_id(void);

// Builds it (a few minutes). false: why says what went wrong (details in the log).
bool gamebuild_run(const char *game_dir, const GameBuildOpts *opts, char *why, size_t why_size);
// The generator and the compiler are there (shipped builds; a source checkout with tools/venv and clang).
bool gamebuild_available(void);

#ifdef __cplusplus
}
#endif
