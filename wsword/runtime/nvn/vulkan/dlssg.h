// (WSword) NVIDIA DLSS frame generation (Video > Frame generation > NVIDIA DLSS 2x / 3x / 4x), through NVIDIA's
// Streamline (wsword_dlss.dll's wssl_*, dlss_bridge.h): its signed sl.interposer.dll and plugins in WSword's streamline
// folder, with the player's own nvngx_dlssg.dll. Streamline goes in when the process starts with the setting on: the
// Vulkan instance, the window's surface, the device and the swapchain are made with its functions and presents go
// through it (device.c). The frame's inputs - its depth, motion vectors and the image without its HUD, as the window
// shows the game's image - come from frame generation's own (exec.c vk_fg_generate, vk_dlssg_prepare); DLSS makes the
// frames between at the present. Windows only (stubs elsewhere).
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <vulkan/vulkan.h>

#include "dlss_bridge.h"

#ifdef __cplusplus
extern "C" {
#endif

struct SDL_Window;

// Before the Vulkan instance: Streamline in, if the setting asks for it and its files are there. false: not (why:
// dlssg_status).
bool dlssg_start(void);
// Streamline is in: the instance, surface, device and swapchain go through its functions
bool dlssg_loaded(void);
// (WSword) Streamline got through the device and the swapchain: this start won't be taken for a crash in there
void dlssg_start_ok(void);
// Streamline's instance failed: left out for the run (the instance made without it)
void dlssg_abandon(const char *why);
PFN_vkGetInstanceProcAddr dlssg_gipa(void);
PFN_vkGetDeviceProcAddr dlssg_gdpa(void);
// The window's surface through Streamline's vkCreateWin32SurfaceKHR. false: not made (SDL's then).
bool dlssg_create_surface(struct SDL_Window *w, VkInstance inst, VkSurfaceKHR *out);
// After the device: can frame generation run on this GPU, Windows and driver (dlssg_status says why not)
void dlssg_device_ready(VkPhysicalDevice phys);
// Frame generation runs this session: Streamline in, supported, and the setting on
bool dlssg_running(void);
// The frames made between two of the game's: the setting, within what the GPU can (1: 2x)
int dlssg_frames(void);
// The latency markers (WSSL_M_*) and Reflex's sleep (then the simulation start) of frame `frame`
void dlssg_marker(int marker, uint32_t frame);
void dlssg_sleep(uint32_t frame);
// The frame's constants, inputs and options, queued on the recorder thread (record.h rec_call) in order with f->cb's
// commands (outside any rendering)
void dlssg_frame(const WsSlFrame *f);
// Off at once, before the swapchain is made again (recorder idle)
void dlssg_off(void);
// Video > Frame generation's line: what DLSS frame generation does, or why it doesn't
void dlssg_status(char *out, size_t n);
// nvngx_dlssg.dll: where it goes (streamline\ next to WSword.exe) and whether it is there
const char *dlssg_dll_path(void);
bool dlssg_dll_present(void);
// An NVIDIA RTX 40 or newer (DLSS frame generation's GPUs), and RTX 50 (3x and 4x)
bool dlssg_gpu_ok(void);
bool dlssg_gpu_mfg(void);

#ifdef __cplusplus
}
#endif
