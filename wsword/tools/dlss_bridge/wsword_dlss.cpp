// (WSword) wsword_dlss.dll: NVIDIA DLSS (Super Resolution) for WSword's Vulkan renderer, through NVIDIA's NGX - the
// bridge runtime/nvn/vulkan/dlss_bridge.h describes. Built with MSVC (cl.exe) against NVIDIA's DLSS SDK
// (https://github.com/NVIDIA/DLSS: its include/ and nvsdk_ngx_s.lib, the static CRT's), by .github/workflows/
// build-windows.yml - see README.md here. The SDK is NVIDIA's, under its own licence (NVIDIA-DLSS-LICENSE.txt in the
// release); this file is WSword's (MIT).
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <vulkan/vulkan.h>

#include "nvsdk_ngx_helpers_vk.h"
#include "nvsdk_ngx_vk.h"

#include "../../runtime/nvn/vulkan/dlss_bridge.h"

#define EXPORT extern "C" __declspec(dllexport)

namespace {
// WSword's project id for NGX (GUID-like, NVSDK_NGX_ENGINE_TYPE_CUSTOM: no NVIDIA application id)
const char *const PROJECT_ID = "5f0c2a8e-7b41-4d6a-9e3c-1a2b3c4d5e6f";

bool g_inited;
VkDevice g_dev;
NVSDK_NGX_Parameter *g_params;
NVSDK_NGX_Handle *g_feature;
struct { uint32_t rw, rh, ow, oh; int quality, preset; } g_made;
void (*g_log)(const char *);
void (*g_idle)(void);
const wchar_t *g_paths[5];
NVSDK_NGX_FeatureCommonInfo g_info;

void say(char *err, int n, const char *what, NVSDK_NGX_Result r) {
    if (err && n > 0) _snprintf_s(err, (size_t)n, _TRUNCATE, "%s (NGX 0x%08x)", what, (unsigned)r);
}

void NVSDK_CONV ngx_log(const char *message, NVSDK_NGX_Logging_Level, NVSDK_NGX_Feature) {
    if (!g_log || !message) return;
    char line[1024];
    _snprintf_s(line, sizeof line, _TRUNCATE, "[dlss] ngx: %s", message);
    size_t l = strlen(line);
    while (l && (line[l - 1] == '\n' || line[l - 1] == '\r')) line[--l] = 0;
    strcat_s(line, sizeof line, "\n");
    g_log(line);
}

NVSDK_NGX_FeatureDiscoveryInfo discovery(const wchar_t *data_path) {
    static NVSDK_NGX_FeatureCommonInfo info;  // (only the exe's folder here: NGX's default)
    NVSDK_NGX_FeatureDiscoveryInfo d = {};
    d.SDKVersion = NVSDK_NGX_Version_API;
    d.FeatureID = NVSDK_NGX_Feature_SuperSampling;
    d.Identifier.IdentifierType = NVSDK_NGX_Application_Identifier_Type_Project_Id;
    d.Identifier.v.ProjectDesc.ProjectId = PROJECT_ID;
    d.Identifier.v.ProjectDesc.EngineType = NVSDK_NGX_ENGINE_TYPE_CUSTOM;
    d.Identifier.v.ProjectDesc.EngineVersion = "1";
    d.ApplicationDataPath = data_path;
    d.FeatureInfo = &info;
    return d;
}

int copy_names(const VkExtensionProperties *p, uint32_t n, char (*out)[VK_MAX_EXTENSION_NAME_SIZE], int max) {
    int k = 0;
    for (uint32_t i = 0; i < n && k < max; i++) strcpy_s(out[k++], VK_MAX_EXTENSION_NAME_SIZE, p[i].extensionName);
    return k;
}

void release_feature(void) {
    if (!g_feature) return;
    if (g_idle) g_idle();
    NVSDK_NGX_VULKAN_ReleaseFeature(g_feature);
    g_feature = nullptr;
}

NVSDK_NGX_PerfQuality_Value perf_quality(int q) {
    switch (q) {
    case WSDLSS_Q_ULTRA_QUALITY:  // (DLSS has no Ultra Quality of its own: Quality's model, at WSword's 1.3x)
    case WSDLSS_Q_QUALITY: return NVSDK_NGX_PerfQuality_Value_MaxQuality;
    case WSDLSS_Q_BALANCED: return NVSDK_NGX_PerfQuality_Value_Balanced;
    case WSDLSS_Q_PERFORMANCE: return NVSDK_NGX_PerfQuality_Value_MaxPerf;
    case WSDLSS_Q_ULTRA_PERFORMANCE: return NVSDK_NGX_PerfQuality_Value_UltraPerformance;
    default: return NVSDK_NGX_PerfQuality_Value_DLAA;
    }
}

NVSDK_NGX_Resource_VK resource(const WsDlssImage &m, bool rw) {
    VkImageSubresourceRange r = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
    return NVSDK_NGX_Create_ImageView_Resource_VK(m.view, m.image, r, m.format, m.width, m.height, rw);
}
}  // namespace

EXPORT int wsdlss_abi(void) { return WSDLSS_ABI; }

EXPORT int wsdlss_instance_extensions(const wchar_t *data_path, char (*out)[VK_MAX_EXTENSION_NAME_SIZE], int max) {
    NVSDK_NGX_FeatureDiscoveryInfo d = discovery(data_path);
    uint32_t n = 0;
    VkExtensionProperties *p = nullptr;
    if (NVSDK_NGX_FAILED(NVSDK_NGX_VULKAN_GetFeatureInstanceExtensionRequirements(&d, &n, &p))) return -1;
    return copy_names(p, n, out, max);
}

EXPORT int wsdlss_device_extensions(VkInstance instance, VkPhysicalDevice phys, const wchar_t *data_path,
                                    char (*out)[VK_MAX_EXTENSION_NAME_SIZE], int max) {
    NVSDK_NGX_FeatureDiscoveryInfo d = discovery(data_path);
    uint32_t n = 0;
    VkExtensionProperties *p = nullptr;
    if (NVSDK_NGX_FAILED(NVSDK_NGX_VULKAN_GetFeatureDeviceExtensionRequirements(instance, phys, &d, &n, &p))) return -1;
    return copy_names(p, n, out, max);
}

EXPORT int wsdlss_init(const WsDlssInit *in, char *err, int n) {
    if (g_inited) return 0;
    g_log = in->log, g_idle = in->device_idle;
    unsigned np = 0;
    for (int i = 0; i < 4; i++)
        if (in->dll_paths[i]) g_paths[np++] = in->dll_paths[i];
    g_info = {};
    g_info.PathListInfo.Path = g_paths;
    g_info.PathListInfo.Length = np;
    g_info.LoggingInfo.LoggingCallback = ngx_log;
    g_info.LoggingInfo.MinimumLoggingLevel = getenv("SAVAGEWIND_DLSS_LOG") ? NVSDK_NGX_LOGGING_LEVEL_VERBOSE : NVSDK_NGX_LOGGING_LEVEL_ON;
    g_info.LoggingInfo.DisableOtherLoggingSinks = true;  // (WSword.log only: no log files of NGX's own beside it)
    NVSDK_NGX_Result r = NVSDK_NGX_VULKAN_Init_with_ProjectID(PROJECT_ID, NVSDK_NGX_ENGINE_TYPE_CUSTOM, in->engine_version,
                                                             in->data_path, in->instance, in->phys, in->dev, in->gipa,
                                                             in->gdpa, &g_info);
    if (NVSDK_NGX_FAILED(r)) { say(err, n, "NGX didn't start on this GPU and driver", r); return -1; }
    g_dev = in->dev;
    g_inited = true;
    r = NVSDK_NGX_VULKAN_GetCapabilityParameters(&g_params);
    if (NVSDK_NGX_FAILED(r)) { say(err, n, "NGX has no parameters", r); return -1; }
    int available = 0, update = 0, major = 0, minor = 0, init_result = 0;
    NVSDK_NGX_Parameter_GetI(g_params, NVSDK_NGX_Parameter_SuperSampling_NeedsUpdatedDriver, &update);
    NVSDK_NGX_Parameter_GetI(g_params, NVSDK_NGX_Parameter_SuperSampling_MinDriverVersionMajor, &major);
    NVSDK_NGX_Parameter_GetI(g_params, NVSDK_NGX_Parameter_SuperSampling_MinDriverVersionMinor, &minor);
    NVSDK_NGX_Parameter_GetI(g_params, NVSDK_NGX_Parameter_SuperSampling_FeatureInitResult, &init_result);
    r = NVSDK_NGX_Parameter_GetI(g_params, NVSDK_NGX_Parameter_SuperSampling_Available, &available);
    if (update) {
        if (err && n > 0) _snprintf_s(err, (size_t)n, _TRUNCATE, "DLSS needs a newer NVIDIA driver (%d.%d or later)", major, minor);
        return -1;
    }
    if (NVSDK_NGX_FAILED(r) || !available) {
        say(err, n, "DLSS isn't available: nvngx_dlss.dll missing or not for this GPU", (NVSDK_NGX_Result)init_result);
        return -1;
    }
    return 0;
}

// The model for every mode (the feature uses the one of the mode it is made with): 0, NVIDIA's own default for it
static void set_preset(int preset) {
    static const char *const modes[] = {
        NVSDK_NGX_Parameter_DLSS_Hint_Render_Preset_DLAA, NVSDK_NGX_Parameter_DLSS_Hint_Render_Preset_Quality,
        NVSDK_NGX_Parameter_DLSS_Hint_Render_Preset_Balanced, NVSDK_NGX_Parameter_DLSS_Hint_Render_Preset_Performance,
        NVSDK_NGX_Parameter_DLSS_Hint_Render_Preset_UltraPerformance, NVSDK_NGX_Parameter_DLSS_Hint_Render_Preset_UltraQuality};
    for (const char *m : modes) NVSDK_NGX_Parameter_SetUI(g_params, m, (unsigned)preset);
}

EXPORT void wsdlss_release_feature(void) { release_feature(); }

EXPORT int wsdlss_evaluate(const WsDlssEval *e, char *err, int n) {
    if (!g_inited || !g_params) { say(err, n, "NGX isn't started", NVSDK_NGX_Result_Fail); return -1; }
    if (g_feature && (g_made.rw != e->color.width || g_made.rh != e->color.height || g_made.ow != e->output.width ||
                      g_made.oh != e->output.height || g_made.quality != e->quality || g_made.preset != e->preset)) {
        // (letting it go needs the device idle, which this thread - the recorder's - can't wait for: the caller's)
        say(err, n, "DLSS was made for other sizes and wasn't let go", NVSDK_NGX_Result_Fail);
        return -1;
    }
    if (!g_feature) {
        set_preset(e->preset);
        NVSDK_NGX_DLSS_Create_Params cp = {};
        cp.Feature.InWidth = e->color.width;
        cp.Feature.InHeight = e->color.height;
        cp.Feature.InTargetWidth = e->output.width;
        cp.Feature.InTargetHeight = e->output.height;
        cp.Feature.InPerfQualityValue = perf_quality(e->quality);
        // (LDR in, motion vectors at the render size and without the jitter, depth not inverted, exposure DLSS's own)
        cp.InFeatureCreateFlags = NVSDK_NGX_DLSS_Feature_Flags_MVLowRes | NVSDK_NGX_DLSS_Feature_Flags_AutoExposure;
        NVSDK_NGX_Result r = NGX_VULKAN_CREATE_DLSS_EXT1(g_dev, e->cb, 1, 1, &g_feature, g_params, &cp);
        if (NVSDK_NGX_FAILED(r)) {
            g_feature = nullptr;
            say(err, n, "DLSS couldn't be made for these sizes", r);
            return -1;
        }
        g_made = {e->color.width, e->color.height, e->output.width, e->output.height, e->quality, e->preset};
    }
    NVSDK_NGX_Resource_VK color = resource(e->color, false), depth = resource(e->depth, false),
                          motion = resource(e->motion, false), output = resource(e->output, true);
    NVSDK_NGX_VK_DLSS_Eval_Params ep = {};
    ep.Feature.pInColor = &color;
    ep.Feature.pInOutput = &output;
    ep.pInDepth = &depth;
    ep.pInMotionVectors = &motion;
    ep.InJitterOffsetX = e->jitter[0];
    ep.InJitterOffsetY = e->jitter[1];
    ep.InRenderSubrectDimensions = {e->color.width, e->color.height};
    ep.InReset = e->reset;
    ep.InMVScaleX = e->mv_scale[0];
    ep.InMVScaleY = e->mv_scale[1];
    ep.InFrameTimeDeltaInMsec = e->dt_ms;
    NVSDK_NGX_Result r = NGX_VULKAN_EVALUATE_DLSS_EXT(e->cb, g_feature, g_params, &ep);
    if (NVSDK_NGX_FAILED(r)) { say(err, n, "DLSS failed", r); return -1; }
    return 0;
}

EXPORT void wsdlss_shutdown(void) {
    if (!g_inited) return;
    release_feature();
    if (g_params) NVSDK_NGX_VULKAN_DestroyParameters(g_params);
    g_params = nullptr;
    NVSDK_NGX_VULKAN_Shutdown1(g_dev);
    g_inited = false;
}
