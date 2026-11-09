// The controls screen's controller picture, the player's own (nvn/pad_illust.h)
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "pad_illust.h"
#include "../imageload.h"
#include "../rt.h"

#define FMT_RG8 0x0D
// The game's two pictures as they go up (1.8.2, RG8 deswizzled): FNV-1a of their rows
static const uint64_t k_hash[2] = {0x8b42a6ff21f5dea4ull, 0x6e2b71b7ed623592ull};

static uint64_t fnv1a_rows(const uint8_t *p, size_t n, size_t stride, size_t rows) {
    uint64_t h = 0xcbf29ce484222325ull;
    for (size_t y = 0; y < rows; y++)
        for (size_t i = 0; i < n; i++) h = (h ^ p[y * stride + i]) * 0x100000001b3ull;
    return h;
}

uint8_t *pad_illust_layout(size_t *n) {
    FILE *f = fopen(PAD_ILLUST_DIR "/PaAllControllerTipsNN_00.bflyt", "rb");
    if (!f) return NULL;
    uint8_t *b = NULL;
    long sz = fseek(f, 0, SEEK_END) == 0 ? ftell(f) : -1;
    if (sz >= 0x20 && sz < (16 << 20) && fseek(f, 0, SEEK_SET) == 0 && (b = malloc((size_t)sz)) &&
        fread(b, 1, (size_t)sz, f) == (size_t)sz && !memcmp(b, "FLYT", 4) && b[4] == 0xFF && b[5] == 0xFE) {
        *n = (size_t)sz;
    } else {
        LOG("[controls] %s/PaAllControllerTipsNN_00.bflyt: not a Switch layout, the game's stays\n", PAD_ILLUST_DIR);
        free(b);
        b = NULL;
    }
    fclose(f);
    return b;
}

bool pad_illust_apply(uint32_t format, uint32_t w, uint32_t h, uint8_t *lin, uint32_t row) {
    if (format != FMT_RG8 || w != 576 || (h != 288 && h != 100) || row < w * 2) return false;
    int k = h == 288 ? 0 : 1;
    static int have = -1;  // (the folder: looked for once)
    if (have < 0) {
        FILE *f = fopen(PAD_ILLUST_DIR "/front.png", "rb");
        have = f != NULL;
        if (f) fclose(f);
    }
    if (!have) return false;
    uint64_t hash = fnv1a_rows(lin, (size_t)w * 2, row, h);
    if (k_hash[k] && hash != k_hash[k]) {
        static int nlog;
        if (nlog++ < 4) LOG("[controls] a %ux%u RG8 texture, not the controller picture (%016llx)\n", w, h, (unsigned long long)hash);
        return false;
    }
    const char *path = k ? PAD_ILLUST_DIR "/top.png" : PAD_ILLUST_DIR "/front.png";
    int iw, ih;
    uint8_t *px = rt_image_load(path, &iw, &ih, 2);
    if (!px || iw != (int)w || ih != (int)h) {
        LOG("[controls] %s: %s, the game's picture stays\n", path, px ? "not the picture's size" : "not readable");
        rt_image_free(px);
        return false;
    }
    for (uint32_t y = 0; y < h; y++) memcpy(lin + (uint64_t)y * row, px + (uint64_t)y * w * 2, (size_t)w * 2);
    rt_image_free(px);
    LOG("[controls] %s: the controls screen's controller picture\n", path);
    return true;
}
