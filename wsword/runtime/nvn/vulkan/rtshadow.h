// (WSword) Ray-traced sun shadows and ambient occlusion (rtshadow.c): Settings > Video > Ray-Tracing, on GPUs with hardware ray
// tracing (g_vk.rt: acceleration structures, ray queries, transform feedback, push descriptors).
//
// What the game does (the ray tracing report, Ctrl+F9, of 0.3.7-pc.1 on an RTX 4070 SUPER): each frame it draws the
// sun's shadow casters into three cascades (an 896 x 896 x 3 depth array, RS_SHADOW: ~1400 draws, ~1M triangles),
// each cascade with the light's camera in its context buffer (c3, as the world camera's: an orthographic or warped
// view-projection, the light's view rotation); then three full-screen draws make the deferred sun shadow mask - the
// red channel of a half-resolution RGBA8 target (green and blue hold other terms) - from the cascades, with depth
// compares, over the half-resolution depth; the deferred lighting reads that mask.
//
// What WSword does with it on: the caster draws run a variant of their vertex shader (ShaderKey xfb) whose clip
// position also goes to a capture buffer by transform feedback (the maps are drawn as before: everything else reading
// them is unchanged); at the mask pass's end those positions are taken back to the world through each cascade's
// inverse view-projection, built into one bottom-level acceleration structure per cascade (each draw a geometry:
// opaque, or - its fragment shader discards: leaves, grass - not), with a top-level one over them (instance mask: the
// cascade), and each pixel of the half-resolution depth traces rays toward the sun (a cone, 4 rays) against the
// geometry of the finest cascade it is in - the one the game's map would use for it. A ray that meets an opaque
// triangle is shadowed; alpha-tested foliage (leaves, grass, bushes) blocks it where its cut-out is solid - where the
// game's own map of that cascade, drawn with the cut-outs, has a surface there (foliage within 30 cm of the pixel
// passes: the grass it stands in); one that meets nothing is lit. The mask's red channel is then rewritten from that (a 3x3
// depth-aware filter), its other channels kept. Where the game's map has no cascade, and the sky, keep its value.
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "vk.h"

#ifdef __cplusplus
extern "C" {
#endif

// The setting on and ray tracing ready (the first call sets it up)
bool rts_on(void);
// A shadow caster draw (a triangle list into a cascade, nverts vertices with its instances): true when its vertices
// go to the capture buffer - the draw then goes between rts_capture_begin and rts_capture_end, with the xfb program
// map / layer: the cascade's depth array and its layer (alpha-tested foliage's cut-outs are read from the game's map)
bool rts_capture_begin(VkCommandBuffer cb, const float *c3, uint64_t c3_size, bool foliage, uint32_t nverts, TexBackend *map,
                       uint32_t layer);
// A caster draw that couldn't be captured (its variant still compiling, a topology without triangles): the game's
// shadows are kept as well this frame (rts_mask.frag's min), so nothing it casts goes missing
void rts_capture_missed(const float *c3, uint64_t c3_size);
void rts_capture_end(VkCommandBuffer cb);
// A draw of the deferred sun shadow mask: its target (the red channel the sun's), the half-resolution depth, and the
// world camera's context buffer (its fragment c3)
void rts_mask_seen(TexBackend *mask, TexBackend *depth, const float *world_c3, uint64_t c3_size);
bool rts_mask_pending(void);
// At the mask pass's end: the ray tracing recorded into cb; *out: what exec.c's compose pass (rts_mask.frag) draws
typedef struct {
    TexBackend *mask, *vis, *copy;
    VkImageView depth_view;
    float pc[8];
} RtsCompose;
// scene_depth: the full-resolution depth the world camera (the one given as the mask's) drew into this frame
bool rts_run(VkCommandBuffer cb, TexBackend *(*scene_depth)(const float *world_c3), RtsCompose *out);
// (0.3.13) This frame's ambient occlusion (the rays' result's .b, at the mask's size) and the scene depth beside it:
// false when there is none this frame. pc: [0] the strength, [1..3] the distance (rts_mask.frag's dist)
bool rts_ao(VkImageView *vis, VkImageView *depth, float pc[4]);
// (0.3.19) Ray-traced reflections on water. rts_gbuf_seen: a draw into the game's G-buffer (rt0: the material ids, rt3:
// the world normals), the last one of the frame kept. rts_refl at the composited scene (color: its copy, sampled):
// *out the reflections (RGBA16F at the G-buffer's size: .rgb, .a their weight) for rt_refl.frag. False: none this frame.
void rts_gbuf_seen(TexBackend *mat, TexBackend *nrm);
bool rts_refl_on(void);
bool rts_refl(VkCommandBuffer cb, VkImageView color, VkImageView *out);
// The GPU has hardware ray tracing (the device was made with it)
bool rts_available(void);
// Settings > Video: its state in words
void rts_status(char *out, size_t n);
// The ray tracing report (Ctrl+F9): this frame's capture in WSword.log
void rts_report(void);

#ifdef __cplusplus
}
#endif
