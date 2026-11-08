// (WSword) NVIDIA DLSS through a bridge DLL of its own: wsword_dlss.dll (tools/dlss_bridge/wsword_dlss.cpp), built
// with MSVC against NVIDIA's DLSS SDK (its NGX library is MSVC's: this MinGW-built runtime can't link it), loaded by
// vulkan/dlss.c. Plain C across it: Vulkan handles, numbers, strings. The DLSS model itself, nvngx_dlss.dll, is the
// player's own - next to WSword.exe (or in its dlss folder), where NGX looks for it; it doesn't ship with WSword.
#pragma once
#include <stdint.h>
#include <wchar.h>
#include <vulkan/vulkan.h>

#ifdef __cplusplus
extern "C" {
#endif

#define WSDLSS_ABI 3  // (wsdlss_abi: the bridge and the runtime agree on these structures)

typedef struct {
    VkInstance instance;
    VkPhysicalDevice phys;
    VkDevice dev;
    PFN_vkGetInstanceProcAddr gipa;
    PFN_vkGetDeviceProcAddr gdpa;
    const wchar_t *data_path;       // NGX's own files (its logs)
    const wchar_t *dll_paths[4];    // more folders to look for nvngx_dlss.dll in (NULL: none; the exe's folder always)
    const char *engine_version;     // WSword's version
    void (*log)(const char *line);  // NGX's messages, into WSword.log (NULL: none)
    void (*device_idle)(void);      // before a feature is let go: nothing of the queue in flight (vk_fg_wait_idle)
} WsDlssInit;

typedef struct {
    VkImage image;
    VkImageView view;
    VkFormat format;
    uint32_t width, height;
} WsDlssImage;

enum { WSDLSS_Q_ULTRA_QUALITY, WSDLSS_Q_QUALITY, WSDLSS_Q_BALANCED, WSDLSS_Q_PERFORMANCE, WSDLSS_Q_ULTRA_PERFORMANCE,
       WSDLSS_Q_DLAA };
// The DLSS model (NGX's render presets, nvsdk_ngx_defs.h NVSDK_NGX_DLSS_Hint_Render_Preset): 0 NVIDIA's default for the
// mode (with a 310.5+ nvngx_dlss.dll: K for DLAA / Quality / Balanced, M for Performance, L for Ultra Performance), E the
// CNN (the fastest), K the transformer, L / M the second transformer (heavier, made for RTX 40 and newer)
enum { WSDLSS_PRESET_DEFAULT = 0, WSDLSS_PRESET_E = 5, WSDLSS_PRESET_K = 11, WSDLSS_PRESET_L = 12, WSDLSS_PRESET_M = 13 };

typedef struct {
    VkCommandBuffer cb;              // recording; DLSS's work goes into it (every image in VK_IMAGE_LAYOUT_GENERAL)
    WsDlssImage color, depth, motion;  // at the render size: the scene (LDR), its depth (R32F, not inverted), the
                                       // motion vectors (RG16F, render pixels to where each was, with mv_scale)
    WsDlssImage output;              // at the output size, a storage image
    float jitter[2];                 // this frame's jitter, render pixels (x right, y down)
    float mv_scale[2];               // the motion vectors' scale to render pixels
    float dt_ms;
    int reset;                       // no usable history (a cut, the first frame)
    int quality;                     // WSDLSS_Q_*: the feature's mode (the render size is the caller's)
    int preset;                      // WSDLSS_PRESET_*: the model the feature is made with
} WsDlssEval;

typedef int (*PFN_wsdlss_abi)(void);
// The Vulkan instance / device extensions DLSS needs (NGX's own answer), as names into out[max]; the count, -1 if NGX
// couldn't say. The instance's before the instance is made; the device's before the device is.
typedef int (*PFN_wsdlss_instance_extensions)(const wchar_t *data_path, char (*out)[VK_MAX_EXTENSION_NAME_SIZE], int max);
typedef int (*PFN_wsdlss_device_extensions)(VkInstance instance, VkPhysicalDevice phys, const wchar_t *data_path,
                                            char (*out)[VK_MAX_EXTENSION_NAME_SIZE], int max);
// NGX on the device, and DLSS's availability on this GPU and driver. 0, or -1 with the reason in err.
typedef int (*PFN_wsdlss_init)(const WsDlssInit *in, char *err, int n);
// DLSS into e->cb: the feature made first when there is none (its creation recorded into e->cb too). 0, or -1 with the
// reason in err. A feature made for other sizes, mode or model is an error: the caller lets it go first
// (wsdlss_release_feature). Called on the thread that records e->cb, which may not be the one that called init.
typedef int (*PFN_wsdlss_evaluate)(const WsDlssEval *e, char *err, int n);
// The feature let go (device_idle first), so the next evaluate makes it again
typedef void (*PFN_wsdlss_release_feature)(void);
// The feature let go and NGX shut down (the device idle first: the caller's)
typedef void (*PFN_wsdlss_shutdown)(void);


// ---- (ABI 3) NVIDIA DLSS frame generation, through NVIDIA's Streamline SDK (https://github.com/NVIDIA-RTX/Streamline,
// MIT; its signed sl.interposer.dll and plugins in WSword's streamline folder, with the player's own nvngx_dlssg.dll).
// Streamline in its "manual hooking" mode: WSword makes its Vulkan instance, device, window surface and swapchain with
// the interposer's functions (wssl_gipa / wssl_gdpa) and presents through it; DLSS frame generation makes the frames
// between two of the game's at its present.
typedef struct {
    const wchar_t *dir;             // the folder of sl.interposer.dll, the sl.*.dll plugins and nvngx_dlssg.dll
    const char *engine_version;     // WSword's version
    void (*log)(const char *line);  // Streamline's messages, into WSword.log
} WsSlInit;

typedef struct {
    VkImage image;
    VkImageView view;
    VkFormat format;
    uint32_t width, height;
    VkImageUsageFlags usage;
} WsSlImage;  // (in VK_IMAGE_LAYOUT_GENERAL)

typedef struct {
    uint32_t frame;                    // the frame's index (its markers' too)
    VkCommandBuffer cb;                // recording, for the queue that presents it
    int on;                            // frames made at its present (0: none - the menus; the inputs let go)
    int frames;                        // the frames made between two of the game's (1: 2x)
    WsSlImage depth, motion, hudless;  // the game's rectangle as the window shows it (rect): depth R32F, motion vectors
                                       // RG16F (the uv offset to where each pixel was, times mv_scale), the image
                                       // without its HUD
    uint32_t rect[4];                  // that rectangle in the window's image: left, top, width, height
    uint32_t back_w, back_h;           // the window's image
    VkFormat back_format;
    uint32_t back_count;
    float view_to_clip[16], clip_to_view[16], clip_to_prev_clip[16], prev_clip_to_clip[16];  // row-major, row vectors
    float mv_scale[2];
    float cam_pos[3], cam_up[3], cam_right[3], cam_fwd[3];
    float cam_near, cam_far, cam_fov, cam_aspect;  // (fov: vertical, radians)
    int reset;                         // a cut: no history
} WsSlFrame;

typedef struct {
    int status;           // DLSSGStatus bits (0: fine)
    uint32_t max_frames;  // the most frames it can make between two (1: 2x only)
    uint32_t presented;   // frames presented since the last call
    uint32_t min_size;    // the window's smallest side it works at
} WsSlState;

enum { WSSL_M_SIM_START, WSSL_M_SIM_END, WSSL_M_RENDER_START, WSSL_M_RENDER_END, WSSL_M_PRESENT_START, WSSL_M_PRESENT_END };

// Streamline started (before the Vulkan instance: its interposer's signature checked, then slInit). 0, or -1 and why.
typedef int (*PFN_wssl_init)(const WsSlInit *in, char *err, int n);
// The interposer's vkGetInstanceProcAddr / vkGetDeviceProcAddr: its proxies for what it hooks, vulkan-1's for the rest
typedef PFN_vkGetInstanceProcAddr (*PFN_wssl_gipa)(void);
typedef PFN_vkGetDeviceProcAddr (*PFN_wssl_gdpa)(void);
// After the device (made with the interposer's vkCreateDevice): DLSS frame generation on this GPU, Windows and driver
// (1), or why not (0, err; the feature unloaded: a plain swapchain). Reflex on.
typedef int (*PFN_wssl_device_ready)(VkPhysicalDevice phys, char *err, int n);
// A latency marker (WSSL_M_*), and Reflex's sleep (then the frame's simulation start), for the frame index given
typedef void (*PFN_wssl_marker)(int marker, uint32_t frame);
typedef void (*PFN_wssl_sleep)(uint32_t frame);
// The frame's constants, inputs and options, before its present (on the thread that records f->cb). 0, or -1 and why.
typedef int (*PFN_wssl_frame)(const WsSlFrame *f, char *err, int n);
typedef int (*PFN_wssl_state)(WsSlState *s);
// Frame generation off at once (before the swapchain is made again), and Streamline shut down (before the device goes)
typedef void (*PFN_wssl_off)(void);
typedef void (*PFN_wssl_shutdown)(void);

// (WSword) ReShade (tools/dlss_bridge/wsword_reshade.cpp; vulkan/reshade.c): the player's own ReShade, loaded as a
// Vulkan layer, given the game's depth for its effects - the bridge registered with it as an add-on (ReShade's add-on
// API, third_party/reshade), binding a view of WSword's depth image to the DEPTH semantic when ReShade's effects begin.
// Found by name (dlss_bridge_proc): an older bridge without them leaves ReShade to its own depth.
// wsrs_attach: once ReShade's module is loaded (after the instance is made); 1 registered, 0 not (why: in `why`).
typedef int (*PFN_wsrs_attach)(void (*log)(const char *line), char *why, int why_size);
// The view ReShade's effects get as DEPTH from the next present on (0: none); an R32F image's, the window's size, in
// VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL when the effects run
typedef void (*PFN_wsrs_depth)(uint64_t view);
// (0.3.12) ReShade's effects drawn by WSword, once a frame, before the HUD and frame generation: on an image (rtv: a
// UNORM view, rtv_srgb: its sRGB one, in VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, WSword's work before it submitted)
// with `depth` as DEPTH (as wsrs_depth's, the image's size), on the recorder thread; that frame's presents then draw
// none, until wsrs_frame_end (after its last present). 1 drawn, 0 not (no effect runtime yet: ReShade's at present then)
typedef int (*PFN_wsrs_effects)(uint64_t rtv, uint64_t rtv_srgb, uint64_t depth);
typedef void (*PFN_wsrs_frame_end)(void);

#ifdef __cplusplus
}
#endif
