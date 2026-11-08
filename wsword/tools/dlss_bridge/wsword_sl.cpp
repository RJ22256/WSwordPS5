// (WSword) wsword_dlss.dll, its second half: NVIDIA DLSS frame generation through NVIDIA's Streamline SDK
// (https://github.com/NVIDIA-RTX/Streamline: MIT; its include/ here, its signed sl.interposer.dll and plugins - and the
// player's nvngx_dlssg.dll - in WSword's streamline folder), as runtime/nvn/vulkan/dlss_bridge.h describes (wssl_*).
// Streamline is loaded at run time (LoadLibrary): nothing of it is linked, and without its files the bridge's DLSS
// upscaling (wsword_dlss.cpp) works as before. Built with MSVC with wsword_dlss.cpp (README.md).
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <mutex>

#include <vulkan/vulkan.h>

#include "sl.h"
#include "sl_consts.h"
#include "sl_dlss_g.h"
#include "sl_helpers.h"
#include "sl_helpers_vk.h"
#include "sl_pcl.h"
#include "sl_reflex.h"
#include "sl_security.h"

#include "../../runtime/nvn/vulkan/dlss_bridge.h"

#define EXPORT extern "C" __declspec(dllexport)

namespace {
const char *const PROJECT_ID = "5f0c2a8e-7b41-4d6a-9e3c-1a2b3c4d5e6f";  // (as wsword_dlss.cpp's, for NGX)

struct {
    HMODULE mod;
    PFun_slInit *init;
    PFun_slShutdown *shutdown;
    PFun_slIsFeatureSupported *supported;
    PFun_slSetFeatureLoaded *set_loaded;
    PFun_slSetTagForFrame *tag;
    PFun_slSetConstants *constants;
    PFun_slGetFeatureFunction *feature_fn;
    PFun_slGetNewFrameToken *token;
    PFN_vkGetInstanceProcAddr gipa;
    PFN_vkGetDeviceProcAddr gdpa;
    PFun_slDLSSGSetOptions *fg_options;
    PFun_slDLSSGGetState *fg_state;
    PFun_slReflexSetOptions *reflex_options;
    PFun_slReflexSleep *reflex_sleep;
    PFun_slPCLSetMarker *marker;
    bool inited, fg_ok, was_on;
    void (*log)(const char *);
    std::mutex m;  // (the frame token: markers on the game's thread, the frame's inputs on the recorder thread)
    uint32_t tok_index;
    sl::FrameToken *tok;
    sl::DLSSGOptions last;
} s;

void say(char *err, int n, const char *what, sl::Result r) {
    if (err && n > 0) _snprintf_s(err, (size_t)n, _TRUNCATE, "%s (Streamline: %s)", what, sl::getResultAsStr(r));
}

// Streamline's messages into WSword.log: its warnings and errors always, the rest the first 300 lines (all of them with
// SAVAGEWIND_DLSSG_LOG=1)
void sl_log(sl::LogType type, const char *msg) {
    static long n;
    if (!s.log || !msg) return;
    static int all = -1;  // (SAVAGEWIND_DLSSG_LOG=1: every line)
    if (all < 0) all = getenv("SAVAGEWIND_DLSSG_LOG") != nullptr;
    if (type == sl::LogType::eInfo && !all && InterlockedIncrement(&n) > 300) return;
    char line[1200];
    _snprintf_s(line, sizeof line, _TRUNCATE, "[dlssg] sl%s: %s", type == sl::LogType::eError ? " error" : type == sl::LogType::eWarn ? " warning" : "", msg);
    size_t l = strlen(line);
    while (l && (line[l - 1] == '\n' || line[l - 1] == '\r')) line[--l] = 0;
    strcat_s(line, sizeof line, "\n");
    s.log(line);
}

template <class F> F *proc(const char *name) { return reinterpret_cast<F *>(GetProcAddress(s.mod, name)); }

template <class F> F *feature(sl::Feature f, const char *name) {
    void *p = nullptr;
    if (!s.feature_fn || s.feature_fn(f, name, p) != sl::Result::eOk) return nullptr;
    return reinterpret_cast<F *>(p);
}

// The frame's token (the same one for all its calls)
sl::FrameToken *token(uint32_t frame) {
    std::lock_guard<std::mutex> g(s.m);
    if (!s.tok || s.tok_index != frame) {
        sl::FrameToken *t = nullptr;
        if (s.token(t, &frame) != sl::Result::eOk || !t) return nullptr;
        s.tok = t, s.tok_index = frame;
    }
    return s.tok;
}

void copy16(sl::float4x4 &m, const float *f) { memcpy(&m, f, 16 * sizeof(float)); }

sl::Resource resource(const WsSlImage &i) {
    sl::Resource r(sl::ResourceType::eTex2d, (void *)i.image, nullptr, (void *)i.view, VK_IMAGE_LAYOUT_GENERAL);
    r.width = i.width, r.height = i.height, r.nativeFormat = (uint32_t)i.format, r.mipLevels = 1, r.arrayLayers = 1;
    r.flags = 0, r.usage = (uint32_t)i.usage;
    return r;
}
}  // namespace

EXPORT int wssl_init(const WsSlInit *in, char *err, int n) {
    if (s.inited) return 0;
    s.log = in->log;
    wchar_t path[1100];
    _snwprintf_s(path, 1100, _TRUNCATE, L"%s\\sl.interposer.dll", in->dir);
    if (GetFileAttributesW(path) == INVALID_FILE_ATTRIBUTES) {
        if (err) _snprintf_s(err, (size_t)n, _TRUNCATE, "Streamline's files are missing (streamline\\sl.interposer.dll)");
        return -1;
    }
    if (!sl::security::verifyEmbeddedSignature(path)) {  // (NVIDIA's signed build only)
        if (err) _snprintf_s(err, (size_t)n, _TRUNCATE, "streamline\\sl.interposer.dll isn't NVIDIA's signed one");
        return -1;
    }
    s.mod = LoadLibraryExW(path, nullptr, LOAD_WITH_ALTERED_SEARCH_PATH);
    if (!s.mod) {
        if (err) _snprintf_s(err, (size_t)n, _TRUNCATE, "sl.interposer.dll didn't load (error %lu)", GetLastError());
        return -1;
    }
    s.init = proc<PFun_slInit>("slInit");
    s.shutdown = proc<PFun_slShutdown>("slShutdown");
    s.supported = proc<PFun_slIsFeatureSupported>("slIsFeatureSupported");
    s.set_loaded = proc<PFun_slSetFeatureLoaded>("slSetFeatureLoaded");
    s.tag = proc<PFun_slSetTagForFrame>("slSetTagForFrame");
    s.constants = proc<PFun_slSetConstants>("slSetConstants");
    s.feature_fn = proc<PFun_slGetFeatureFunction>("slGetFeatureFunction");
    s.token = proc<PFun_slGetNewFrameToken>("slGetNewFrameToken");
    s.gipa = reinterpret_cast<PFN_vkGetInstanceProcAddr>(GetProcAddress(s.mod, "vkGetInstanceProcAddr"));
    s.gdpa = reinterpret_cast<PFN_vkGetDeviceProcAddr>(GetProcAddress(s.mod, "vkGetDeviceProcAddr"));
    if (!s.init || !s.shutdown || !s.supported || !s.set_loaded || !s.tag || !s.constants || !s.feature_fn || !s.token ||
        !s.gipa || !s.gdpa) {
        if (err) _snprintf_s(err, (size_t)n, _TRUNCATE, "sl.interposer.dll lacks functions WSword needs (another version?)");
        FreeLibrary(s.mod);
        s.mod = nullptr;
        return -1;
    }
    static const wchar_t *paths[1];
    paths[0] = in->dir;
    static const sl::Feature features[] = {sl::kFeatureDLSS_G, sl::kFeatureReflex, sl::kFeaturePCL};
    sl::Preferences p{};
    p.showConsole = false;
    p.logLevel = getenv("SAVAGEWIND_DLSSG_LOG") ? sl::LogLevel::eVerbose : sl::LogLevel::eDefault;
    p.pathsToPlugins = paths;
    p.numPathsToPlugins = 1;
    p.pathToLogsAndData = getenv("SAVAGEWIND_DLSSG_LOG") ? in->dir : nullptr;  // (its own log and crash dumps there too)
    p.logMessageCallback = sl_log;
    p.flags |= sl::PreferenceFlags::eUseManualHooking | sl::PreferenceFlags::eUseFrameBasedResourceTagging;
    p.featuresToLoad = features;
    p.numFeaturesToLoad = 3;
    p.engine = sl::EngineType::eCustom;
    p.engineVersion = in->engine_version;
    p.projectId = PROJECT_ID;
    p.renderAPI = sl::RenderAPI::eVulkan;
    sl::Result r = s.init(p, sl::kSDKVersion);
    if (r != sl::Result::eOk) {
        say(err, n, "Streamline didn't start", r);
        FreeLibrary(s.mod);
        s.mod = nullptr;
        return -1;
    }
    s.inited = true;
    return 0;
}

EXPORT PFN_vkGetInstanceProcAddr wssl_gipa(void) { return s.inited ? s.gipa : nullptr; }
EXPORT PFN_vkGetDeviceProcAddr wssl_gdpa(void) { return s.inited ? s.gdpa : nullptr; }

EXPORT int wssl_device_ready(VkPhysicalDevice phys, char *err, int n) {
    if (!s.inited) { say(err, n, "Streamline isn't started", sl::Result::eErrorNotInitialized); return 0; }
    s.fg_options = feature<PFun_slDLSSGSetOptions>(sl::kFeatureDLSS_G, "slDLSSGSetOptions");
    s.fg_state = feature<PFun_slDLSSGGetState>(sl::kFeatureDLSS_G, "slDLSSGGetState");
    s.reflex_options = feature<PFun_slReflexSetOptions>(sl::kFeatureReflex, "slReflexSetOptions");
    s.reflex_sleep = feature<PFun_slReflexSleep>(sl::kFeatureReflex, "slReflexSleep");
    s.marker = feature<PFun_slPCLSetMarker>(sl::kFeaturePCL, "slPCLSetMarker");
    if (s.reflex_options) {  // (frame generation needs Reflex on; WSword's own frame limit stays the one that paces)
        sl::ReflexOptions ro{};
        ro.mode = sl::ReflexMode::eLowLatency;
        ro.frameLimitUs = 0;
        s.reflex_options(ro);
    }
    sl::AdapterInfo ai{};
    ai.vkPhysicalDevice = (void *)phys;
    sl::Result r = s.supported(sl::kFeatureDLSS_G, ai);
    if (r != sl::Result::eOk || !s.fg_options || !s.fg_state) {
        const char *why = r == sl::Result::eErrorOSDisabledHWS ? "turn on Hardware-accelerated GPU scheduling in Windows' graphics settings (then restart the PC)"
                        : r == sl::Result::eErrorOSOutOfDate ? "Windows 10 version 2004 or newer is needed"
                        : r == sl::Result::eErrorDriverOutOfDate ? "update the NVIDIA driver"
                        : r == sl::Result::eErrorNoSupportedAdapterFound || r == sl::Result::eErrorAdapterNotSupported
                            ? "this GPU has no DLSS frame generation (NVIDIA RTX 40 or newer)"
                        : r == sl::Result::eErrorNoPlugins || r == sl::Result::eErrorNGXFailed ? "nvngx_dlssg.dll or sl.dlss_g.dll is missing or didn't load"
                        : "DLSS frame generation isn't available";
        say(err, n, why, r);
        s.set_loaded(sl::kFeatureDLSS_G, false);  // (a plain swapchain, no copy at every present)
        s.fg_ok = false;
        return 0;
    }
    s.fg_ok = true;
    return 1;
}

EXPORT void wssl_marker(int m, uint32_t frame) {
    if (!s.inited || !s.marker) return;
    static const sl::PCLMarker k[] = {sl::PCLMarker::eSimulationStart, sl::PCLMarker::eSimulationEnd, sl::PCLMarker::eRenderSubmitStart,
                                      sl::PCLMarker::eRenderSubmitEnd, sl::PCLMarker::ePresentStart, sl::PCLMarker::ePresentEnd};
    if (m < 0 || m > WSSL_M_PRESENT_END) return;
    sl::FrameToken *t = token(frame);
    if (t) s.marker(k[m], *t);
}

EXPORT void wssl_sleep(uint32_t frame) {
    if (!s.inited) return;
    sl::FrameToken *t = token(frame);
    if (!t) return;
    if (s.reflex_sleep) s.reflex_sleep(*t);
    if (s.marker) s.marker(sl::PCLMarker::eSimulationStart, *t);
}

EXPORT int wssl_frame(const WsSlFrame *f, char *err, int n) {
    if (!s.inited || !s.fg_ok) { say(err, n, "DLSS frame generation isn't running", sl::Result::eErrorNotInitialized); return -1; }
    sl::FrameToken *t = token(f->frame);
    if (!t) { say(err, n, "no frame token", sl::Result::eErrorInvalidParameter); return -1; }
    sl::ViewportHandle vp(0u);
    sl::CommandBuffer *cb = reinterpret_cast<sl::CommandBuffer *>(f->cb);
    sl::Result r;
    if (f->on) {
        sl::Constants c{};
        copy16(c.cameraViewToClip, f->view_to_clip);
        copy16(c.clipToCameraView, f->clip_to_view);
        static const float id[16] = {1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1};
        copy16(c.clipToLensClip, id);
        copy16(c.clipToPrevClip, f->clip_to_prev_clip);
        copy16(c.prevClipToClip, f->prev_clip_to_clip);
        c.jitterOffset = sl::float2(0, 0);
        c.mvecScale = sl::float2(f->mv_scale[0], f->mv_scale[1]);
        c.cameraPinholeOffset = sl::float2(0, 0);
        c.cameraPos = sl::float3(f->cam_pos[0], f->cam_pos[1], f->cam_pos[2]);
        c.cameraUp = sl::float3(f->cam_up[0], f->cam_up[1], f->cam_up[2]);
        c.cameraRight = sl::float3(f->cam_right[0], f->cam_right[1], f->cam_right[2]);
        c.cameraFwd = sl::float3(f->cam_fwd[0], f->cam_fwd[1], f->cam_fwd[2]);
        c.cameraNear = f->cam_near, c.cameraFar = f->cam_far, c.cameraFOV = f->cam_fov, c.cameraAspectRatio = f->cam_aspect;
        c.depthInverted = sl::Boolean::eFalse;
        c.cameraMotionIncluded = sl::Boolean::eTrue;
        c.motionVectors3D = sl::Boolean::eFalse;
        c.reset = f->reset ? sl::Boolean::eTrue : sl::Boolean::eFalse;
        c.orthographicProjection = sl::Boolean::eFalse;
        c.motionVectorsDilated = sl::Boolean::eFalse;
        c.motionVectorsJittered = sl::Boolean::eFalse;
        r = s.constants(c, *t, vp);
        if (r != sl::Result::eOk) { say(err, n, "the frame's constants", r); return -1; }
        sl::Resource depth = resource(f->depth), motion = resource(f->motion), hudless = resource(f->hudless);
        sl::Extent de{0, 0, f->depth.width, f->depth.height}, me{0, 0, f->motion.width, f->motion.height},
            he{0, 0, f->hudless.width, f->hudless.height};
        sl::Extent bb{f->rect[1], f->rect[0], f->rect[2], f->rect[3]};  // (top, left, width, height)
        sl::ResourceTag tags[4] = {sl::ResourceTag(&depth, sl::kBufferTypeDepth, sl::eValidUntilPresent, &de),
                                   sl::ResourceTag(&motion, sl::kBufferTypeMotionVectors, sl::eValidUntilPresent, &me),
                                   sl::ResourceTag(&hudless, sl::kBufferTypeHUDLessColor, sl::eValidUntilPresent, &he),
                                   sl::ResourceTag(nullptr, sl::kBufferTypeBackbuffer, sl::eValidUntilPresent, &bb)};
        bool whole = !f->rect[0] && !f->rect[1] && f->rect[2] == f->back_w && f->rect[3] == f->back_h;
        r = s.tag(*t, vp, tags, whole ? 3u : 4u, cb);
        if (r != sl::Result::eOk) { say(err, n, "the frame's inputs", r); return -1; }
    } else if (s.was_on) {  // (the menus: the inputs let go)
        sl::ResourceTag tags[4] = {sl::ResourceTag(nullptr, sl::kBufferTypeDepth, sl::eValidUntilPresent),
                                   sl::ResourceTag(nullptr, sl::kBufferTypeMotionVectors, sl::eValidUntilPresent),
                                   sl::ResourceTag(nullptr, sl::kBufferTypeHUDLessColor, sl::eValidUntilPresent),
                                   sl::ResourceTag(nullptr, sl::kBufferTypeBackbuffer, sl::eValidUntilPresent)};
        s.tag(*t, vp, tags, 4, cb);
    }
    sl::DLSSGOptions o{};
    o.mode = f->on ? sl::DLSSGMode::eOn : sl::DLSSGMode::eOff;
    o.numFramesToGenerate = f->frames < 1 ? 1u : (uint32_t)f->frames;
    o.flags = sl::DLSSGFlags::eRetainResourcesWhenOff;  // (the menus: no reallocation, no stutter, when it comes back)
    o.numBackBuffers = f->back_count;
    o.mvecDepthWidth = f->depth.width, o.mvecDepthHeight = f->depth.height;
    o.colorWidth = f->back_w, o.colorHeight = f->back_h;
    o.colorBufferFormat = (uint32_t)f->back_format;
    o.mvecBufferFormat = (uint32_t)f->motion.format;
    o.depthBufferFormat = (uint32_t)f->depth.format;
    o.hudLessBufferFormat = (uint32_t)f->hudless.format;
    bool changed = o.mode != s.last.mode || o.numFramesToGenerate != s.last.numFramesToGenerate || o.colorWidth != s.last.colorWidth ||
                   o.colorHeight != s.last.colorHeight || o.mvecDepthWidth != s.last.mvecDepthWidth ||
                   o.mvecDepthHeight != s.last.mvecDepthHeight || o.numBackBuffers != s.last.numBackBuffers;
    if (changed || !f->on != !s.was_on) {
        r = s.fg_options(vp, o);
        if (r != sl::Result::eOk) { say(err, n, "the frame generation options", r); return -1; }
        s.last = o;
    }
    s.was_on = f->on != 0;
    return 0;
}

EXPORT int wssl_state(WsSlState *st) {
    memset(st, 0, sizeof *st);
    if (!s.inited || !s.fg_ok) return -1;
    sl::DLSSGState g{};
    sl::ViewportHandle vp(0u);
    if (s.fg_state(vp, g, nullptr) != sl::Result::eOk) return -1;
    st->status = (int)g.status, st->max_frames = g.numFramesToGenerateMax, st->presented = g.numFramesActuallyPresented;
    st->min_size = g.minWidthOrHeight;
    return 0;
}

EXPORT void wssl_off(void) {
    if (!s.inited || !s.fg_ok || !s.was_on) return;
    sl::DLSSGOptions o = s.last;
    o.mode = sl::DLSSGMode::eOff;
    sl::ViewportHandle vp(0u);
    s.fg_options(vp, o);
    s.last = o;
    s.was_on = false;
}

EXPORT void wssl_shutdown(void) {
    if (!s.inited) return;
    s.shutdown();
    s.inited = s.fg_ok = false;
}
