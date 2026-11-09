// (the PS5) The game's controls screen (Layout/Common.sblarc PaAllControllerTipsNN_00: "Basic Controls", the horse,
// the sand seal) shows a drawing of the handheld Switch, with lines from each label to its button. On the console it
// shows a drawing of a two-grip pad of our own (tools/pad_illust: d-pad and face buttons up top, the sticks below
// in the middle, the touch pad between): its two textures replaced as they go up (pad_illust_apply), and the labels'
// lines led to the new places in the layout (pad_illust_layout: services/fs.c, with the HUD letters).
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct { char name[24]; float tx, ty, rz, sx, sy, w; } PadPaneEdit;
extern const uint64_t k_pad_layout_hash;
extern const size_t k_pad_layout_size;
extern const uint64_t k_pad_tex_hash[2];
extern const PadPaneEdit k_pad_edits[];
extern const size_t k_pad_nedits;
extern const uint8_t k_pad_front_png[], k_pad_top_png[];
extern const size_t k_pad_front_png_size, k_pad_top_png_size;

// The layout (FLYT, as read from the archive), edited in place; the count of panes changed, 0 if it isn't the one
// the edits were made for (another game version: it stays the game's)
int pad_illust_layout(uint8_t *flyt, size_t n);
// A texture going up (nvn/vulkan/textures.c: RG8, level 0, deswizzled): true if it was one of the drawings, replaced
bool pad_illust_apply(uint32_t format, uint32_t w, uint32_t h, uint8_t *lin, uint32_t row);
