// (WSword) NVIDIA DLSS through wsword_dlss.dll (dlss.h, dlss_bridge.h)
#include "dlss.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#include "../../paths.h"
#include "vk.h"

bool renderer_gpu_rtx(void);  // (device.c)
void vk_fg_wait_idle(void);   // (device.c: the presents, the recorder and the device idle)

#ifdef _WIN32
#include <stdatomic.h>
#include <windows.h>

#include "record.h"
#include "../../settings.h"

bool renderer_gpu_rtx40(void);  // (device.c: Ada or newer)

#define TS_SLOTS 8  // (DLSS's GPU time: a pair of timestamps a frame, read back TS_SLOTS frames later)

static struct {
    bool tried, loaded, dev_ext, inited, failed;
    HMODULE h;
    PFN_wsdlss_instance_extensions inst_ext;
    PFN_wsdlss_device_extensions dev_exts;
    PFN_wsdlss_init init;
    PFN_wsdlss_evaluate evaluate;
    PFN_wsdlss_release_feature release;
    PFN_wsdlss_shutdown shutdown;
    char err[400];
    // (T) the feature as last asked for: made again when one of these changes
    bool made;
    uint32_t rw, rh, ow, oh;
    int quality, preset;
    // (the recorder thread) failures in a row; then r_failed, with the reason in r_err, for T to read
    int r_fails;
    _Atomic int r_failed;
    char r_err[400];
    // (T) DLSS's GPU time
    VkQueryPool qp;
    bool ts;
    float ns_per_tick, gpu_ms;
    uint64_t ts_seq, ts_used[TS_SLOTS], ts_n;
    double ts_sum;
    // (T) the fallback blit's format checks
    VkFormat blit_src, blit_dst;
    bool blit_ok;
} d;

static const wchar_t *wide(const char *s, wchar_t *out, int n) {
    if (!MultiByteToWideChar(CP_UTF8, 0, s, -1, out, n)) out[0] = 0;
    return out;
}

static void load(void) {
    if (d.tried) return;
    d.tried = true;
    char p[1100];
    wchar_t w[1100];
    snprintf(p, sizeof p, "%s\\wsword_dlss.dll", rt_exe_dir());
    d.h = LoadLibraryW(wide(p, w, 1100));
    if (!d.h) { snprintf(d.err, sizeof d.err, "wsword_dlss.dll is missing next to WSword.exe"); return; }
    PFN_wsdlss_abi abi = (PFN_wsdlss_abi)(void *)GetProcAddress(d.h, "wsdlss_abi");
    d.inst_ext = (PFN_wsdlss_instance_extensions)(void *)GetProcAddress(d.h, "wsdlss_instance_extensions");
    d.dev_exts = (PFN_wsdlss_device_extensions)(void *)GetProcAddress(d.h, "wsdlss_device_extensions");
    d.init = (PFN_wsdlss_init)(void *)GetProcAddress(d.h, "wsdlss_init");
    d.evaluate = (PFN_wsdlss_evaluate)(void *)GetProcAddress(d.h, "wsdlss_evaluate");
    d.release = (PFN_wsdlss_release_feature)(void *)GetProcAddress(d.h, "wsdlss_release_feature");
    d.shutdown = (PFN_wsdlss_shutdown)(void *)GetProcAddress(d.h, "wsdlss_shutdown");
    if (!abi || abi() != WSDLSS_ABI || !d.inst_ext || !d.dev_exts || !d.init || !d.evaluate || !d.release || !d.shutdown) {
        snprintf(d.err, sizeof d.err, "wsword_dlss.dll is from another WSword");
        FreeLibrary(d.h);
        d.h = NULL;
        return;
    }
    d.loaded = true;
    LOG("[dlss] wsword_dlss.dll loaded\n");
}

// (dlssg.c) an export of the bridge, once it loaded and its ABI matched (NULL otherwise)
void *dlss_bridge_proc(const char *name) {
    load();
    return d.loaded ? (void *)GetProcAddress(d.h, name) : NULL;
}

static const wchar_t *data_path(void) {
    static wchar_t w[1100];
    if (!w[0]) wide(rt_exe_dir(), w, 1100);
    return w;
}

// (SAVAGEWIND_NO_DLSS=1: the bridge left alone - no DLSS, nothing of NGX at startup)
bool dlss_bridge_loaded(void) {
    static int off = -1;
    if (off < 0) off = getenv("SAVAGEWIND_NO_DLSS") != NULL;
    if (off) return false;
    load();
    return d.loaded;
}

int dlss_instance_extensions(char (*out)[VK_MAX_EXTENSION_NAME_SIZE], int max) {
    if (!dlss_bridge_loaded()) return 0;
    int n = d.inst_ext(data_path(), out, max);
    if (n < 0) LOG("[dlss] NGX named no instance extensions\n");
    return n < 0 ? 0 : n;
}

int dlss_device_extensions(VkInstance instance, VkPhysicalDevice phys, char (*out)[VK_MAX_EXTENSION_NAME_SIZE], int max) {
    if (!dlss_bridge_loaded()) return 0;
    int n = d.dev_exts(instance, phys, data_path(), out, max);
    if (n < 0) LOG("[dlss] NGX named no device extensions\n");
    return n < 0 ? 0 : n;
}

void dlss_device_ready(bool extensions_on) { d.dev_ext = extensions_on; }

const char *dlss_dll_path(void) {
    static char p[1100];
    if (!p[0]) snprintf(p, sizeof p, "%s\\nvngx_dlss.dll", rt_exe_dir());
    return p;
}

// (looked for at most twice a second: dlss_available runs many times a frame - with DLSS on, at every camera the game
// makes (output_scale.c rt_jitter_on) - and a file lookup each time cost the game's thread)
bool dlss_dll_present(void) {
    static _Atomic uint64_t at;
    static _Atomic int have;
    uint64_t now = GetTickCount64(), was = atomic_load_explicit(&at, memory_order_relaxed);
    if (!was || now - was >= 500) {
        char p[1100];
        struct stat st;
        snprintf(p, sizeof p, "%s\\dlss\\nvngx_dlss.dll", rt_exe_dir());
        atomic_store_explicit(&have, stat(dlss_dll_path(), &st) == 0 || stat(p, &st) == 0, memory_order_relaxed);
        atomic_store_explicit(&at, now ? now : 1, memory_order_relaxed);
    }
    return atomic_load_explicit(&have, memory_order_relaxed);
}

// A failure: NGX not starting (d.err), or DLSS failing on the recorder thread three frames in a row (d.r_err): DLSS off
// for the run, its reason on the Video page
static bool failed_now(void) { return d.failed || atomic_load_explicit(&d.r_failed, memory_order_acquire); }
static const char *fail_reason(void) { return d.failed ? d.err : d.r_err; }

bool dlss_available(void) {
    return renderer_gpu_rtx() && dlss_bridge_loaded() && d.dev_ext && !failed_now() && dlss_dll_present();
}

// Video > DLSS model: the preset the feature is made with (dlss_bridge.h WSDLSS_PRESET_*). Automatic: NVIDIA's own
// choice per mode on RTX 40 and newer; on RTX 20 / 30 the transformer K for every mode - NVIDIA's newer models, which a
// 310.5+ nvngx_dlss.dll uses for Performance (M) and Ultra Performance (L), cost there 2-5x K's (NVIDIA's DLSS guide:
// RTX 3060 at 1440p, K 2.4 ms, M 5.1 ms, L 6.5 ms; the CNN, E, 1.0 ms), more than rendering smaller saves.
static int dlss_preset(int quality) {
    switch (g_settings.dlss_model) {
    case DLSS_MODEL_CNN: return WSDLSS_PRESET_E;
    case DLSS_MODEL_TRANSFORMER: return WSDLSS_PRESET_K;
    case DLSS_MODEL_TRANSFORMER2: return quality == WSDLSS_Q_ULTRA_PERFORMANCE ? WSDLSS_PRESET_L : WSDLSS_PRESET_M;
    default: return renderer_gpu_rtx40() ? WSDLSS_PRESET_DEFAULT : WSDLSS_PRESET_K;
    }
}

static const char *preset_name(int p) {
    return p == WSDLSS_PRESET_E ? "CNN (E)" : p == WSDLSS_PRESET_K ? "transformer (K)" : p == WSDLSS_PRESET_L ? "transformer 2 (L)"
         : p == WSDLSS_PRESET_M ? "transformer 2 (M)" : "NVIDIA's default";
}

const char *dlss_model_in_use(void) { return d.made ? preset_name(d.preset) : ""; }

float dlss_gpu_ms(void) { return d.gpu_ms; }

void dlss_status(char *out, size_t n) {
    if (!renderer_gpu_rtx()) snprintf(out, n, "DLSS needs an NVIDIA RTX graphics card.");
    else if (!dlss_bridge_loaded()) snprintf(out, n, "DLSS: %s.", d.err);
    else if (!d.dev_ext) snprintf(out, n, "DLSS: this driver lacks what DLSS needs - update the NVIDIA driver.");
    else if (failed_now()) snprintf(out, n, "DLSS stopped: %s.", fail_reason());
    else if (!dlss_dll_present())
        snprintf(out, n, "DLSS: add your nvngx_dlss.dll - start screen > Settings > Files > NVIDIA DLSS, or put it next to "
                 "WSword.exe.");
    else if (d.made && d.gpu_ms > 0)
        snprintf(out, n, "DLSS is running: %s, %.2f ms of GPU time a frame.", preset_name(d.preset), d.gpu_ms);
    else snprintf(out, n, "DLSS is ready.%s", d.inited ? " Running." : "");
}

// NGX's messages into WSword.log: the first 200 (all of them with SAVAGEWIND_DLSS_LOG)
static void ngx_line(const char *line) {
    static _Atomic int n;
    static int all = -1;
    if (all < 0) all = getenv("SAVAGEWIND_DLSS_LOG") != NULL;
    int k = atomic_fetch_add_explicit(&n, 1, memory_order_relaxed);
    if (all || k < 200) LOG("%s", line);
    else if (k == 200) LOG("[dlss] (NGX's further messages: SAVAGEWIND_DLSS_LOG=1)\n");
}

// ---- on the recorder thread (record.h rec_call): DLSS into the frame's command buffer, in order with the commands
// around it. A failure shows the scene scaled plainly that frame (a blit into DLSS's output); three in a row turn DLSS
// off (r_failed: T takes it at the next frame and goes back to rendering at the window's size).
typedef struct {
    WsDlssEval e;
    VkQueryPool qp;
    uint32_t q0;
    int ts, blit;
} EvalPkt;

static void fallback(const EvalPkt *k) {
    if (!k->blit) return;
    const WsDlssEval *e = &k->e;
    VkImageBlit r = {.srcSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1}, .srcOffsets = {{0, 0, 0}, {(int32_t)e->color.width, (int32_t)e->color.height, 1}},
                     .dstSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1}, .dstOffsets = {{0, 0, 0}, {(int32_t)e->output.width, (int32_t)e->output.height, 1}}};
    vkCmdBlitImage(e->cb, e->color.image, VK_IMAGE_LAYOUT_GENERAL, e->output.image, VK_IMAGE_LAYOUT_GENERAL, 1, &r, VK_FILTER_LINEAR);
}

static void eval_run(const void *p) {
    const EvalPkt *k = p;
    VkCommandBuffer cb = k->e.cb;
    if (atomic_load_explicit(&d.r_failed, memory_order_relaxed)) { fallback(k); return; }
    if (k->ts) {
        vkCmdResetQueryPool(cb, k->qp, k->q0, 2);
        vkCmdWriteTimestamp2(cb, VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT, k->qp, k->q0);
    }
    char err[400];
    if (d.evaluate(&k->e, err, sizeof err)) {
        fallback(k);
        if (d.r_fails++ < 8) LOG("[dlss] %s (%ux%u -> %ux%u)\n", err, k->e.color.width, k->e.color.height, k->e.output.width,
                                 k->e.output.height);
        if (d.r_fails >= 3) {  // (a failure that stays: DLSS off for this run, its reason on the Video page)
            snprintf(d.r_err, sizeof d.r_err, "%s", err);
            atomic_store_explicit(&d.r_failed, 1, memory_order_release);
        }
    } else {
        d.r_fails = 0;
    }
    if (k->ts) vkCmdWriteTimestamp2(cb, VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT, k->qp, k->q0 + 1);
}

// (T) the timestamps' pool, if the queue has them
static void timing_init(void) {
    uint32_t nq = 0;
    vkGetPhysicalDeviceQueueFamilyProperties(g_vk.phys, &nq, NULL);
    VkQueueFamilyProperties qf[16];
    if (nq > 16) nq = 16;
    vkGetPhysicalDeviceQueueFamilyProperties(g_vk.phys, &nq, qf);
    if (g_vk.qfam >= nq || !qf[g_vk.qfam].timestampValidBits || g_vk.props.limits.timestampPeriod <= 0) return;
    VkQueryPoolCreateInfo qi = {.sType = VK_STRUCTURE_TYPE_QUERY_POOL_CREATE_INFO, .queryType = VK_QUERY_TYPE_TIMESTAMP,
                                .queryCount = 2 * TS_SLOTS};
    if (vkCreateQueryPool(g_vk.dev, &qi, NULL, &d.qp) != VK_SUCCESS) return;
    d.ns_per_tick = g_vk.props.limits.timestampPeriod;
    d.ts = true;
}

// (T) the slot's timestamps from TS_SLOTS frames ago, if they are there (never waited for), into the average; the
// slot for this frame
static uint32_t timing_slot(void) {
    uint32_t s = (uint32_t)(d.ts_seq % TS_SLOTS);
    if (d.ts_used[s]) {
        uint64_t v[4];  // (each: the value, then its availability)
        if (vkGetQueryPoolResults(g_vk.dev, d.qp, 2 * s, 2, sizeof v, v, 2 * sizeof(uint64_t),
                                  VK_QUERY_RESULT_64_BIT | VK_QUERY_RESULT_WITH_AVAILABILITY_BIT) >= 0 && v[1] && v[3] && v[2] > v[0]) {
            double ms = (double)(v[2] - v[0]) * d.ns_per_tick / 1e6;
            d.gpu_ms = d.gpu_ms > 0 ? (float)(d.gpu_ms * 0.95 + ms * 0.05) : (float)ms;
            d.ts_sum += ms;
            if (++d.ts_n % 1800 == 0) {  // (about every 30 s at 60 fps)
                LOG("[dlss] GPU time %.2f ms a frame (the last %u), %s, %ux%u -> %ux%u\n", d.ts_sum / 1800, 1800u,
                    preset_name(d.preset), d.rw, d.rh, d.ow, d.oh);
                d.ts_sum = 0;
            }
        }
    }
    d.ts_used[s] = 1;
    d.ts_seq++;
    return s;
}

bool dlss_dispatch(WsDlssEval *e) {
    if (!dlss_available()) {
        static bool told;
        if (failed_now() && d.inited && !told) told = true, LOG("[dlss] off for this run: %s\n", fail_reason());
        return false;
    }
    if (!d.inited) {
        rec_drain();  // (once: NGX starts on the device with nothing of the recorder's in flight)
        static wchar_t paths[2][1100];
        char p[1100];
        snprintf(p, sizeof p, "%s\\dlss", rt_exe_dir());
        wide(p, paths[0], 1100);
        wide(rt_data_root(), paths[1], 1100);
        extern const char *rt_version(void);
        WsDlssInit in = {.instance = g_vk.inst, .phys = g_vk.phys, .dev = g_vk.dev, .gipa = vkGetInstanceProcAddr,
                         .gdpa = vkGetDeviceProcAddr, .data_path = data_path(), .dll_paths = {paths[0], paths[1]},
                         .engine_version = rt_version(), .log = ngx_line, .device_idle = vk_fg_wait_idle};
        if (d.init(&in, d.err, sizeof d.err)) {
            d.failed = true;
            LOG("[dlss] not started: %s\n", d.err);
            return false;
        }
        d.inited = true;
        timing_init();
        LOG("[dlss] started on %s (%s)\n", g_vk.props.deviceName, renderer_gpu_rtx40() ? "RTX 40 or newer" : "RTX 20 / 30");
    }
    e->preset = dlss_preset(e->quality);
    if (d.made && (d.rw != e->color.width || d.rh != e->color.height || d.ow != e->output.width || d.oh != e->output.height ||
                   d.quality != e->quality || d.preset != e->preset)) {
        // (the feature for other sizes, mode or model let go: the recorder's last use of it recorded, then the bridge
        // waits for the device to be idle - once, at a change of the settings or the window)
        rec_drain();
        d.release();
        d.made = false;
        d.gpu_ms = 0;
    }
    if (!d.made) {
        d.made = true;
        d.rw = e->color.width, d.rh = e->color.height, d.ow = e->output.width, d.oh = e->output.height;
        d.quality = e->quality, d.preset = e->preset;
        LOG("[dlss] %ux%u -> %ux%u, mode %d, model %s\n", d.rw, d.rh, d.ow, d.oh, d.quality, preset_name(d.preset));
    }
    if (d.blit_src != e->color.format || d.blit_dst != e->output.format) {
        VkFormatProperties a, b;
        vkGetPhysicalDeviceFormatProperties(g_vk.phys, e->color.format, &a);
        vkGetPhysicalDeviceFormatProperties(g_vk.phys, e->output.format, &b);
        d.blit_src = e->color.format, d.blit_dst = e->output.format;
        d.blit_ok = (a.optimalTilingFeatures & VK_FORMAT_FEATURE_BLIT_SRC_BIT) && (b.optimalTilingFeatures & VK_FORMAT_FEATURE_BLIT_DST_BIT);
    }
    EvalPkt k = {.e = *e, .qp = d.qp, .ts = d.ts, .blit = d.blit_ok};
    if (d.ts) k.q0 = 2 * timing_slot();
    rec_call(eval_run, &k, sizeof k);
    return true;
}

void dlss_shutdown(void) {
    if (d.inited) d.shutdown();
    d.inited = d.made = false;
    if (d.qp) vkDestroyQueryPool(g_vk.dev, d.qp, NULL);
    d.qp = VK_NULL_HANDLE;
    d.ts = false;
}

#else  // (no DLSS: Linux, macOS)
bool dlss_bridge_loaded(void) { return false; }
int dlss_instance_extensions(char (*out)[VK_MAX_EXTENSION_NAME_SIZE], int max) { (void)out, (void)max; return 0; }
int dlss_device_extensions(VkInstance i, VkPhysicalDevice p, char (*out)[VK_MAX_EXTENSION_NAME_SIZE], int max) {
    (void)i, (void)p, (void)out, (void)max;
    return 0;
}
void dlss_device_ready(bool on) { (void)on; }
bool dlss_available(void) { return false; }
const char *dlss_dll_path(void) { return ""; }
bool dlss_dll_present(void) { return false; }
void dlss_status(char *out, size_t n) { snprintf(out, n, "DLSS is for Windows and NVIDIA RTX graphics cards."); }
bool dlss_dispatch(WsDlssEval *e) { (void)e; return false; }
void dlss_shutdown(void) {}
const char *dlss_model_in_use(void) { return ""; }
float dlss_gpu_ms(void) { return 0; }
#endif
