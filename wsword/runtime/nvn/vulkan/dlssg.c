// (WSword) NVIDIA DLSS frame generation through Streamline (dlssg.h)
#include "dlssg.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#include "../../paths.h"
#include "../../settings.h"
#include "record.h"
#include "vk.h"

bool renderer_gpu_rtx40(void);  // (device.c)

bool dlssg_gpu_ok(void) { return renderer_gpu_rtx40(); }
// (RTX 50, Blackwell: PCI device ids 0x2900 and up - Ada's end below; device.c renderer_gpu_rtx40)
bool dlssg_gpu_mfg(void) { return renderer_gpu_rtx40() && g_vk.props.deviceID >= 0x2900; }

#ifdef _WIN32
#include <stdatomic.h>
#include <windows.h>
#include <vulkan/vulkan_win32.h>
#include <SDL3/SDL.h>

void *dlss_bridge_proc(const char *name);  // (dlss.c: wsword_dlss.dll's export, after its ABI check)

static struct {
    bool tried, loaded, supported;
    char why[400];
    PFN_wssl_init init;
    PFN_wssl_gipa gipa;
    PFN_wssl_gdpa gdpa;
    PFN_wssl_device_ready ready;
    PFN_wssl_marker marker;
    PFN_wssl_sleep sleep;
    PFN_wssl_frame frame;
    PFN_wssl_state state;
    PFN_wssl_off off;
    PFN_wssl_shutdown shutdown;
    PFN_vkGetInstanceProcAddr vk_gipa;
    PFN_vkGetDeviceProcAddr vk_gdpa;
    _Atomic int fails;      // (the recorder thread's wssl_frame: three in a row turn it off)
    _Atomic int stopped;
    char stop_why[400];
    uint32_t max_frames;    // (wssl_state, once it says)
    uint64_t frames_on;     // frames given with frame generation on (the status line)
} g;

static const char *dir_utf8(void) {
    static char p[1100];
    if (!p[0]) snprintf(p, sizeof p, "%s\\streamline", rt_exe_dir());
    return p;
}

const char *dlssg_dll_path(void) {
    static char p[1100];
    if (!p[0]) snprintf(p, sizeof p, "%s\\nvngx_dlssg.dll", dir_utf8());
    return p;
}

bool dlssg_dll_present(void) {
    struct stat st;
    return stat(dlssg_dll_path(), &st) == 0;
}

static void sl_line(const char *line) {
    static _Atomic int n;
    int k = atomic_fetch_add_explicit(&n, 1, memory_order_relaxed);
    if (k < 2000 || getenv("SAVAGEWIND_DLSSG_LOG")) LOG("%s", line);
}

// A copy of nvngx_dlssg.dll put next to WSword.exe goes into streamline\ (where Streamline looks for it)
static void adopt_dll(void) {
    char loose[1100];
    snprintf(loose, sizeof loose, "%s\\nvngx_dlssg.dll", rt_exe_dir());
    struct stat st;
    if (dlssg_dll_present() || stat(loose, &st) != 0) return;
    wchar_t a[1100], b[1100];
    MultiByteToWideChar(CP_UTF8, 0, loose, -1, a, 1100);
    MultiByteToWideChar(CP_UTF8, 0, dlssg_dll_path(), -1, b, 1100);
    if (CopyFileW(a, b, TRUE)) LOG("[dlssg] nvngx_dlssg.dll next to WSword.exe copied into streamline\\\n");
}

// (WSword) A start that didn't get past NVIDIA's code: this file is made as Streamline starts and removed once the
// window's swapchain is made through it (dlssg_start_ok). Found at the next start, WSword closed in there - frame
// generation is turned off (and saved), so WSword starts again; choosing it again tries again.
static const char *start_marker(void) {
    static char p[1200];
    if (!p[0]) snprintf(p, sizeof p, "%s/dlssg-starting", rt_data_root());
    return p;
}

void dlssg_start_ok(void) {
    static bool done;
    if (done || !g.loaded) return;
    done = true;
    remove(start_marker());
}

bool dlssg_start(void) {
    if (g.tried) return g.loaded;
    g.tried = true;
    if (g_settings.dlssg <= 0) { remove(start_marker()); return false; }
    if (getenv("SAVAGEWIND_NO_DLSSG")) { snprintf(g.why, sizeof g.why, "turned off (SAVAGEWIND_NO_DLSSG)"); return false; }
    {
        struct stat sb;
        if (stat(start_marker(), &sb) == 0) {
            remove(start_marker());
            g_settings.dlssg = 0;
            settings_save();
            snprintf(g.why, sizeof g.why, "WSword closed while NVIDIA DLSS frame generation was starting last time, so it "
                     "was turned off. Choose it again to try again (WSword.prev.log has what happened).");
            LOG("[dlssg] not started: WSword closed while it was starting last time - turned off\n");
            return false;
        }
        FILE *f = fopen(start_marker(), "wb");
        if (f) fputs("NVIDIA DLSS frame generation starting\n", f), fclose(f);
    }
    adopt_dll();
    if (!dlssg_dll_present()) {
        snprintf(g.why, sizeof g.why, "add your nvngx_dlssg.dll - start screen > Settings > Files > NVIDIA DLSS frame generation");
        LOG("[dlssg] not started: no %s\n", dlssg_dll_path());
        return false;
    }
#define P(f, n) (g.f = (__typeof__(g.f))dlss_bridge_proc(n))
    if (!P(init, "wssl_init") || !P(gipa, "wssl_gipa") || !P(gdpa, "wssl_gdpa") || !P(ready, "wssl_device_ready") ||
        !P(marker, "wssl_marker") || !P(sleep, "wssl_sleep") || !P(frame, "wssl_frame") || !P(state, "wssl_state") ||
        !P(off, "wssl_off") || !P(shutdown, "wssl_shutdown")) {
#undef P
        snprintf(g.why, sizeof g.why, "wsword_dlss.dll is missing or from another WSword");
        LOG("[dlssg] not started: %s\n", g.why);
        return false;
    }
    wchar_t dir[1100];
    MultiByteToWideChar(CP_UTF8, 0, dir_utf8(), -1, dir, 1100);
    extern const char *rt_version(void);
    WsSlInit in = {.dir = dir, .engine_version = rt_version(), .log = sl_line};
    uint64_t t0 = SDL_GetTicksNS();
    if (g.init(&in, g.why, sizeof g.why)) { LOG("[dlssg] not started: %s\n", g.why); return false; }
    g.vk_gipa = g.gipa();
    g.vk_gdpa = g.gdpa();
    if (!g.vk_gipa || !g.vk_gdpa) {
        snprintf(g.why, sizeof g.why, "Streamline gave no Vulkan functions");
        LOG("[dlssg] not started: %s\n", g.why);
        return false;
    }
    g.loaded = true;
    LOG("[dlssg] Streamline started (%.0f ms): the instance, device and swapchain through it\n", (SDL_GetTicksNS() - t0) / 1e6);
    return true;
}

bool dlssg_loaded(void) { return g.loaded; }
void dlssg_abandon(const char *why) {
    if (!g.loaded) return;
    g.loaded = false;
    snprintf(g.why, sizeof g.why, "%s", why);
    LOG("[dlssg] left out: %s\n", why);
}
PFN_vkGetInstanceProcAddr dlssg_gipa(void) { return g.loaded ? g.vk_gipa : NULL; }
PFN_vkGetDeviceProcAddr dlssg_gdpa(void) { return g.loaded ? g.vk_gdpa : NULL; }

bool dlssg_create_surface(struct SDL_Window *w, VkInstance inst, VkSurfaceKHR *out) {
    if (!g.loaded) return false;
    PFN_vkCreateWin32SurfaceKHR f = (PFN_vkCreateWin32SurfaceKHR)g.vk_gipa(inst, "vkCreateWin32SurfaceKHR");
    HWND hwnd = (HWND)SDL_GetPointerProperty(SDL_GetWindowProperties(w), SDL_PROP_WINDOW_WIN32_HWND_POINTER, NULL);
    if (!f || !hwnd) { LOG("[dlssg] no Win32 surface through Streamline: SDL's\n"); return false; }
    VkWin32SurfaceCreateInfoKHR ci = {.sType = VK_STRUCTURE_TYPE_WIN32_SURFACE_CREATE_INFO_KHR,
                                      .hinstance = GetModuleHandleW(NULL), .hwnd = hwnd};
    VkResult r = f(inst, &ci, NULL, out);
    if (r != VK_SUCCESS) { LOG("[dlssg] vkCreateWin32SurfaceKHR through Streamline: %d - SDL's\n", r); return false; }
    return true;
}

void dlssg_device_ready(VkPhysicalDevice phys) {
    if (!g.loaded) return;
    char why[400] = "";
    g.supported = g.ready(phys, why, sizeof why) == 1;
    if (!g.supported) snprintf(g.why, sizeof g.why, "%s", why);
    LOG("[dlssg] DLSS frame generation %s%s%s\n", g.supported ? "available on " : "unavailable: ",
        g.supported ? g_vk.props.deviceName : why, g.supported && !dlssg_gpu_mfg() ? " (2x)" : "");
}

bool dlssg_running(void) {
    return g.loaded && g.supported && g_settings.dlssg > 0 && !atomic_load_explicit(&g.stopped, memory_order_acquire);
}

int dlssg_frames(void) {
    int want = g_settings.dlssg < 1 ? 1 : g_settings.dlssg > 3 ? 3 : g_settings.dlssg;
    if (!g.max_frames && g.state) {
        WsSlState st;
        if (!g.state(&st) && st.max_frames) {
            g.max_frames = st.max_frames;
            LOG("[dlssg] this GPU makes up to %u frames between two (%ux)\n", st.max_frames, st.max_frames + 1);
        }
    }
    uint32_t max = g.max_frames ? g.max_frames : dlssg_gpu_mfg() ? 3 : 1;
    return want > (int)max ? (int)max : want;
}

void dlssg_marker(int m, uint32_t frame) {
    if (g.loaded) g.marker(m, frame);
}

void dlssg_sleep(uint32_t frame) {
    if (g.loaded) g.sleep(frame);
}

static void frame_run(const void *p) {
    const WsSlFrame *f = p;
    char err[400];
    if (atomic_load_explicit(&g.stopped, memory_order_relaxed)) return;
    if (g.frame(f, err, sizeof err)) {
        int k = atomic_fetch_add(&g.fails, 1) + 1;
        if (k <= 8) LOG("[dlssg] frame %u: %s\n", f->frame, err);
        if (k >= 3) {
            snprintf(g.stop_why, sizeof g.stop_why, "%s", err);
            atomic_store_explicit(&g.stopped, 1, memory_order_release);
            g.off();
            LOG("[dlssg] off for this run: %s\n", err);
        }
    } else {
        atomic_store(&g.fails, 0);
    }
}

void dlssg_frame(const WsSlFrame *f) {
    if (!dlssg_running()) return;
    if (f->on) g.frames_on++;
    {   // (now and then: what the GPU's frame generation reports)
        static uint64_t n;
        if (f->on && n++ % 1800 == 120 && g.state) {
            WsSlState st;
            if (!g.state(&st))
                LOG("[dlssg] %dx, status %d%s, %u frames presented since the last look, up to %u made between two\n",
                    f->frames + 1, st.status, st.status ? " (not fine: Streamline's DLSSGStatus bits)" : " (fine)",
                    st.presented, st.max_frames);
        }
    }
    rec_call(frame_run, f, sizeof *f);
}

void dlssg_off(void) {
    if (g.loaded && g.supported) g.off();
}

void dlssg_status(char *out, size_t n) {
    if (g_settings.dlssg <= 0 && !g.loaded) {
        snprintf(out, n, "NVIDIA DLSS frame generation: on NVIDIA RTX 40 and newer, with your own nvngx_dlssg.dll%s.",
                 dlssg_dll_present() ? " (added)" : " - add it on the start screen: Settings > Files > NVIDIA DLSS frame generation");
    } else if (!dlssg_gpu_ok() && g_vk.phys) {
        snprintf(out, n, "NVIDIA DLSS frame generation needs an NVIDIA RTX 40 or newer.");
    } else if (g_settings.dlssg > 0 && !g.loaded) {
        if (g.why[0] && g.tried) snprintf(out, n, "NVIDIA DLSS frame generation didn't start: %s.", g.why);
        else snprintf(out, n, "NVIDIA DLSS frame generation starts when WSword starts: restart WSword.");
    } else if (!g.supported) {
        snprintf(out, n, "NVIDIA DLSS frame generation can't run: %s.", g.why);
    } else if (atomic_load(&g.stopped)) {
        snprintf(out, n, "NVIDIA DLSS frame generation stopped: %s.", g.stop_why);
    } else if (g_settings.dlssg <= 0) {
        snprintf(out, n, "NVIDIA DLSS frame generation is loaded; restart WSword to leave it out completely.");
    } else {
        int k = dlssg_frames();
        snprintf(out, n, "NVIDIA DLSS frame generation: %dx%s. The game draws %s of the frame rate; paused in the menus. "
                 "VSync On works as Fast with it (NVIDIA's frame generation has no VSync on Vulkan).", k + 1,
                 g_settings.dlssg > k ? " (the most this GPU makes)" : "", k == 1 ? "half" : k == 2 ? "a third" : "a quarter");
    }
}

#else  // (no DLSS: Linux, macOS)
bool dlssg_start(void) { return false; }
bool dlssg_loaded(void) { return false; }
void dlssg_start_ok(void) {}
void dlssg_abandon(const char *why) { (void)why; }
PFN_vkGetInstanceProcAddr dlssg_gipa(void) { return NULL; }
PFN_vkGetDeviceProcAddr dlssg_gdpa(void) { return NULL; }
bool dlssg_create_surface(struct SDL_Window *w, VkInstance inst, VkSurfaceKHR *out) { (void)w, (void)inst, (void)out; return false; }
void dlssg_device_ready(VkPhysicalDevice phys) { (void)phys; }
bool dlssg_running(void) { return false; }
int dlssg_frames(void) { return 1; }
void dlssg_marker(int m, uint32_t frame) { (void)m, (void)frame; }
void dlssg_sleep(uint32_t frame) { (void)frame; }
void dlssg_frame(const WsSlFrame *f) { (void)f; }
void dlssg_off(void) {}
void dlssg_status(char *out, size_t n) { snprintf(out, n, "NVIDIA DLSS frame generation is for Windows and NVIDIA RTX 40 and newer."); }
const char *dlssg_dll_path(void) { return ""; }
bool dlssg_dll_present(void) { return false; }
#endif
