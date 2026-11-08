// (WSword, from 0.2.8) Game mods: folders in mods/ in the data folder, each with a romfs/ tree laid out as emulators
// take them (Ryujinx, Yuzu, Eden: <mod>/romfs/<the game's own paths>). Their files replace the game's, and files the
// game doesn't have are added (services/fs.c, as its overlay folder). Every mod found is on unless turned off on the
// Mods page (ui/mods_tab.mm; settings mods_off). The DLC's files: a mod's romfs/aoc/0010/ (as on the Wii U), or a
// mod folder named for the DLC's title (01007EF00011F001, as BCML and Relics of the Past ship them), whose romfs is
// the DLC's own. A mods/<name>.link (a text file: a folder's path) is a mod used where it is, as 0.2.8 kept them.
// Read when the game opens its files: a change applies at the game's next start.
#pragma once
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define MODS_MAX 64
typedef struct {
    char name[96];  // its folder's name
    bool on;
    bool dlc;       // named for the DLC's title: the DLC's own files
} ModInfo;

// The mods in mods/ (sorted by name: the first one with a file wins), up to max
int mods_list(ModInfo *out, int max);
// Turns one on or off (settings mods_off; settings_save after)
void mods_set(const char *name, bool on);
// The folders whose files go over the game's image (dlc false) or the DLC's (true), in their order (the first one
// with a file wins): the romfs folders of the mods that are on. Their count (up to max).
int mods_roots(bool dlc, char (*out)[1100], int max);
// The mod's own note - a .txt in its folder (README.txt...) - its first `cap` bytes. "" if it has none.
const char *mods_note(const char *name, char *buf, size_t cap);

#ifdef __cplusplus
}
#endif
