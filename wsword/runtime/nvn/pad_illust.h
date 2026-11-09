// (WSword) The controls screen's controller picture, the player's own (System > Controls: Layout/Common.sblarc
// PaAllControllerTipsNN_00 - "Basic Controls", the horse, the sand seal). A folder controls/ in the data folder with
//   front.png   576x288, grey + alpha: the controller from the front (the game's Nt_NNillust_00)
//   top.png     576x100, grey + alpha: from the top, the shoulder buttons (Nt_NNillust_01)
//   PaAllControllerTipsNN_00.bflyt   the screen's layout, its label lines led to that picture's buttons
// replaces the game's (the handheld Switch) there and nowhere else. Without the folder, the game's.
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define PAD_ILLUST_DIR "controls"
#define PAD_ILLUST_LAYOUT "blyt/PaAllControllerTipsNN_00.bflyt"

// The player's layout for the screen (malloc'd, *n its size), NULL without one
uint8_t *pad_illust_layout(size_t *n);
// A texture going up (nvn/vulkan/textures.c: RG8, level 0, deswizzled): true if it was one of the game's two
// controller pictures and the player's replaced it
bool pad_illust_apply(uint32_t format, uint32_t w, uint32_t h, uint8_t *lin, uint32_t row);
