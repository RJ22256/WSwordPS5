// (WSword) Virtual amiibo (runtime/amiibo.c): every amiibo there is, tapped from WSword's amiibo bar instead of an NFC
// reader. The game's nn::nfp calls (nfp:user, services/nfp.c) see one reader on player 1's controller; while the
// game looks for a figure (the amiibo rune: StartDetection) the bar (ui/amiibo_bar.mm) is up over the game, and the
// figure chosen there is the one the game finds: its public id (the character, its variant and series - from
// AmiiboAPI's list, amiibo_list.inc), a serial number of its own, and the game's saved data for it (its
// "application area", e.g. Wolf Link's hearts) in amiibo/<id>.bin. No figure's dump, no keys.
//
// The game's once-a-day rule goes by the figure's serial number: with "One scan a day per figure" on (the default)
// each amiibo always has the same one, so the game counts it; off, every tap gives a new one.
#pragma once
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct { uint64_t id; const char *name; uint8_t group; } AmiiboDef;

int amiibo_count(void);
const AmiiboDef *amiibo_at(int i);   // (in the bar's order: Breath of the Wild's figures, the Zelda series, ...)
int amiibo_index(uint64_t id);       // -1: none
const char *amiibo_group_name(int g);

// The game is looking for a figure: from its StartDetection until a figure is tapped or it stops looking
bool amiibo_waiting(void);
void amiibo_tap(uint64_t id);        // the figure the game finds (its activate event)

// The player's choices (amiibo/amiibo.ini)
bool amiibo_favourite(uint64_t id);
void amiibo_set_favourite(uint64_t id, bool on);
int amiibo_favourites(uint64_t *out, int max);   // in the order they were added; how many
void amiibo_clear_favourites(void);
bool amiibo_daily(void);
void amiibo_set_daily(bool on);
bool amiibo_used_today(uint64_t id);   // tapped today (the game's once a day: only while the rule is on)
uint64_t amiibo_last(void);            // the last figure tapped (0: none)

// hle/input.c fill_state: while the bar is up it takes A, X, the d-pad and the right stick from the game (B still
// goes to it: B leaves the game's amiibo mode, and the bar with it). The bar reads them (amiibo_bar_input_*).
void amiibo_bar_filter(uint64_t *buttons, int32_t *rx, int32_t *ry);
uint64_t amiibo_bar_input_held(void);
uint64_t amiibo_bar_input_pressed(void);   // pressed since the last call (presses shorter than a frame kept)
int32_t amiibo_bar_input_rx(void);
bool amiibo_bar_up(void);   // ui/amiibo_bar.mm: the bar is drawn (amiibo_waiting, and WSword's menu closed)

#ifdef __cplusplus
}
#endif
