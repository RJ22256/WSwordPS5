// The controls screen's controller drawing (nvn/pad_illust.h)
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "pad_illust.h"
#include "../imageload.h"
#include "../rt.h"

#define FMT_RG8 0x0D

static uint64_t fnv1a(const uint8_t *p, size_t n, size_t stride, size_t rows) {
    uint64_t h = 0xcbf29ce484222325ull;
    for (size_t y = 0; y < rows; y++)
        for (size_t i = 0; i < n; i++) h = (h ^ p[y * stride + i]) * 0x100000001b3ull;
    return h;
}

int pad_illust_layout(uint8_t *b, size_t n) {
#ifdef __PROSPERO__
    if (n != k_pad_layout_size || fnv1a(b, n, n, 1) != k_pad_layout_hash || n < 0x14) return 0;
    size_t hs = b[6] | b[7] << 8;
    int done = 0;
    for (size_t o = hs; o + 0x54 <= n;) {
        uint32_t sz;
        memcpy(&sz, b + o + 4, 4);
        if (sz < 8 || o + sz > n) break;
        if (!memcmp(b + o, "pan1", 4) || !memcmp(b + o, "pic1", 4) || !memcmp(b + o, "txt1", 4) ||
            !memcmp(b + o, "wnd1", 4)) {
            for (size_t i = 0; i < k_pad_nedits; i++) {
                const PadPaneEdit *e = &k_pad_edits[i];
                if (strncmp((const char *)b + o + 0x0C, e->name, 24)) continue;
                memcpy(b + o + 0x2C, &e->tx, 4);
                memcpy(b + o + 0x30, &e->ty, 4);
                memcpy(b + o + 0x40, &e->rz, 4);
                memcpy(b + o + 0x44, &e->sx, 4);
                memcpy(b + o + 0x48, &e->sy, 4);
                memcpy(b + o + 0x4C, &e->w, 4);
                done++;
                break;
            }
        }
        o += sz;
    }
    return done;
#else
    (void)b, (void)n;
    return 0;
#endif
}

bool pad_illust_apply(uint32_t format, uint32_t w, uint32_t h, uint8_t *lin, uint32_t row) {
#ifdef __PROSPERO__
    if (format != FMT_RG8 || w != 576 || (h != 288 && h != 100) || row < w * 2) return false;
    int k = h == 288 ? 0 : 1;
    uint64_t hash = fnv1a(lin, (size_t)w * 2, row, h);
    if (hash != k_pad_tex_hash[k]) {
        static int nlog;
        if (nlog++ < 4) LOG("[pad] a %ux%u RG8 texture, not the controls drawing (%016llx)\n", w, h, (unsigned long long)hash);
        return false;
    }
    int iw, ih;
    uint8_t *px = rt_image_from_memory(k ? k_pad_top_png : k_pad_front_png, k ? k_pad_top_png_size : k_pad_front_png_size,
                                       &iw, &ih, 2);
    if (!px || iw != (int)w || ih != (int)h) {
        rt_image_free(px);
        LOG("[pad] controls drawing %d: not decoded, the game's stays\n", k);
        return false;
    }
    for (uint32_t y = 0; y < h; y++) memcpy(lin + (uint64_t)y * row, px + (uint64_t)y * w * 2, (size_t)w * 2);
    rt_image_free(px);
    LOG("[pad] controls drawing %d (%ux%u): the two-grip pad's\n", k, w, h);
    return true;
#else
    (void)format, (void)w, (void)h, (void)lin, (void)row;
    return false;
#endif
}
