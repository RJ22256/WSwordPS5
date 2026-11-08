// (WSword) The player's own ReShade (https://reshade.me, crosire's; none ships with WSword), loaded by WSword itself:
// Settings > Video > ReShade. Its ReShade64.dll - added on the start screen (Settings > Files > ReShade), from the DLL
// or ReShade's setup program, which carries it - goes into the reshade folder next to WSword.exe, and from the next
// start WSword makes its Vulkan instance with it as a layer (a manifest written there, the folder on the loader's
// layer path: no installer, nothing in the registry). Its files - ReShade.ini, its log, presets, shaders, add-ons - are
// in that folder too (or next to WSword.exe, when a ReShade.ini is already there from ReShade's installer).
// Its effects get the game's depth from WSword (exec.c vk_reshade_depth: the 3D scene's depth placed as the window
// shows the game's image, encoded for ReShade's default depth settings - linear depth in metres / 1000), bound through
// the bridge's ReShade add-on (wsword_dlss.dll wsrs_*; ReShade's own Generic Depth add-on turned off in its ReShade.ini
// then), unless Settings > Video > ReShade depth asks for ReShade's own detection. Windows only (stubs elsewhere).
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <vulkan/vulkan.h>

#ifdef __cplusplus
extern "C" {
#endif

// Before the Vulkan instance: ReShade's layer made ready if the setting asks for it and its DLL is there - its name
// into names[0] (1), or 0 (why: reshade_status)
int reshade_instance_layers(const char **names, int max);
// The instance was made with the layer (false: without it, after it failed)
void reshade_instance_made(bool with_layer);
// ReShade is loaded in this run (device.c: presents on the game's queue and thread then)
bool reshade_loaded(void);
// Its effects get WSword's depth (vk_reshade_depth each present)
bool reshade_depth_active(void);
// The depth view for its effects from this present on
void reshade_set_depth(VkImageView view);
// (0.3.12) With frame generation: ReShade's effects drawn by WSword, once a frame, before the HUD and frame generation
// (exec.c rs_pre_apply), on an image (VkImageView handles: a UNORM view, its sRGB one) with a depth view of its size; on
// the recorder thread. The frame's presents then draw none until reshade_frame_end (after its last present).
bool reshade_can_draw(void);
bool reshade_draw(uint64_t rtv, uint64_t rtv_srgb, uint64_t depth);
void reshade_frame_end(void);
// Settings and the start screen: where its DLL goes, whether it's there, its state in words
const char *reshade_dir(void);
const char *reshade_dll_path(void);
bool reshade_dll_present(void);
void reshade_status(char *out, size_t n);
// The start screen's Settings > Files > ReShade: ReShade64.dll from `src` (the DLL itself, or ReShade's setup program,
// whose archive has it) into the reshade folder. false: not (why in msg); true: msg says what was added.
bool reshade_import(const char *src, char *msg, size_t n);

#ifdef __cplusplus
}
#endif
