// (WSword) wsword_dlss.dll, its third part: the game's depth for the player's own ReShade (runtime/nvn/vulkan/
// reshade.c loads it as a Vulkan layer), as runtime/nvn/vulkan/dlss_bridge.h describes (wsrs_*). The bridge registers
// with ReShade as an add-on (ReShade's add-on API: third_party/reshade, BSD-3-Clause) and binds WSword's depth image -
// the game's 3D scene depth, placed as the window shows the game's image, in the form ReShade's default depth settings
// read - to the DEPTH semantic its effects sample (ReShade.fxh's DepthBuffer). With frame generation, WSword draws
// ReShade's effects itself, once a frame, before the HUD and frame generation (wsrs_effects). Only the effect runtime's
// events and present are used, which every build of ReShade gives add-ons (the one without full add-on support too). Nothing of ReShade is
// linked: it is found in the process by its exports. Built with MSVC with wsword_dlss.cpp (README.md).
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <stdarg.h>
#include <stdio.h>

#include <atomic>

#include "reshade.hpp"

#include "../../runtime/nvn/vulkan/dlss_bridge.h"

#define EXPORT extern "C" __declspec(dllexport)

// The add-on's name and description on ReShade's Add-ons page (ReShadeRegisterAddon reads these exports)
EXPORT const char *NAME = "WSword game depth";
EXPORT const char *DESCRIPTION = "The game's depth for ReShade's effects, from WSword (Settings > Video > ReShade depth).";

namespace {

void (*g_log)(const char *line);
std::atomic<uint64_t> g_view{0};       // WSword's depth view (wsrs_depth)
std::atomic<bool> g_rebind{true};      // the next begin_effects binds it again (effects reloaded, a new runtime)
reshade::api::effect_runtime *g_rt;    // the runtime it was last bound for (the presenting thread's)
reshade::api::effect_runtime *g_any;   // the runtime (made with the window's swapchain)
std::atomic<bool> g_ext{false};        // this frame's effects drawn by WSword (wsrs_effects): none at its presents
uint64_t g_bound = ~0ull;              // and the view bound there
bool g_attached;

void logf(const char *fmt, ...) {
    if (!g_log) return;
    char b[512];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(b, sizeof b, fmt, ap);
    va_end(ap);
    g_log(b);
}

// Before each present's effects: WSword's view as DEPTH, when it changed (a descriptor update in ReShade only then)
void on_begin_effects(reshade::api::effect_runtime *rt, reshade::api::command_list *, reshade::api::resource_view,
                      reshade::api::resource_view) {
    if (!g_any) g_any = rt;
    uint64_t v = g_view.load(std::memory_order_acquire);
    if (rt == g_rt && v == g_bound && !g_rebind.exchange(false)) return;
    rt->update_texture_bindings("DEPTH", reshade::api::resource_view{v}, reshade::api::resource_view{v});
    if (rt != g_rt || g_bound == ~0ull) logf("[reshade] the game's depth bound for ReShade's effects (view %#llx)\n", (unsigned long long)v);
    g_rt = rt, g_bound = v;
}

void on_reloaded_effects(reshade::api::effect_runtime *) { g_rebind = true; }

void on_init_runtime(reshade::api::effect_runtime *rt) { g_any = rt, g_rebind = true; }

void on_destroy_runtime(reshade::api::effect_runtime *rt) {
    if (rt == g_rt) g_rt = nullptr, g_bound = ~0ull;
    if (rt == g_any) g_any = nullptr;
}

// A present of a frame whose effects WSword drew (before its HUD and frame generation): none drawn again there - an
// add-on's render_effects call marks the frame's effects done (ReShade's runtime.cpp), and with no target it draws
// nothing (only its special uniforms - time, frame count - move on, as at any present)
void on_present(reshade::api::command_queue *, reshade::api::swapchain *, const reshade::api::rect *,
                const reshade::api::rect *, uint32_t, const reshade::api::rect *) {
    reshade::api::effect_runtime *rt = g_any;
    if (!rt || !g_ext.load(std::memory_order_acquire)) return;
    rt->render_effects(rt->get_command_queue()->get_immediate_command_list(), reshade::api::resource_view{0},
                       reshade::api::resource_view{0});
}

HMODULE self_module() {
    HMODULE m = nullptr;
    GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                       reinterpret_cast<LPCWSTR>(&self_module), &m);
    return m;
}

}  // namespace

EXPORT int wsrs_attach(void (*log)(const char *line), char *why, int why_size) {
    if (log) g_log = log;
    if (g_attached) return 1;
    HMODULE rs = reshade::internal::get_reshade_module_handle();
    if (!rs) {
        snprintf(why, (size_t)why_size, "ReShade isn't loaded");
        return 0;
    }
    // This header's API version (ReShade 6.8's); an older ReShade with the same major version takes the first one
    // (the effect runtime's update_texture_bindings and these events are in every version of the API)
    using RegisterFn = bool (*)(void *, uint32_t);
    RegisterFn reg = reinterpret_cast<RegisterFn>(GetProcAddress(rs, "ReShadeRegisterAddon"));
    HMODULE me = self_module();
    if (!reg || !me || (!reg(me, RESHADE_API_VERSION) && !reg(me, 1))) {
        snprintf(why, (size_t)why_size, "ReShade didn't take WSword's add-on (its log, ReShade.log, says why)");
        return 0;
    }
    reshade::register_event<reshade::addon_event::reshade_begin_effects>(on_begin_effects);
    reshade::register_event<reshade::addon_event::reshade_reloaded_effects>(on_reloaded_effects);
    reshade::register_event<reshade::addon_event::destroy_effect_runtime>(on_destroy_runtime);
    reshade::register_event<reshade::addon_event::init_effect_runtime>(on_init_runtime);
    reshade::register_event<reshade::addon_event::present>(on_present);
    g_attached = true;
    logf("[reshade] WSword's add-on registered with ReShade\n");
    return 1;
}

EXPORT void wsrs_depth(uint64_t view) { g_view.store(view, std::memory_order_release); }

// ReShade's effects on WSword's image now (the recorder thread, between WSword's submissions: ReShade's immediate
// command list, submitted on the game's queue at once), with `depth` as DEPTH; the frame's presents then draw none
// (wsrs_frame_end ends that). 1: drawn (or ReShade still loading them), 0: no runtime yet.
EXPORT int wsrs_effects(uint64_t rtv, uint64_t rtv_srgb, uint64_t depth) {
    reshade::api::effect_runtime *rt = g_any;
    if (!rt) return 0;
    g_view.store(depth, std::memory_order_release);
    reshade::api::command_queue *q = rt->get_command_queue();
    rt->render_effects(q->get_immediate_command_list(), reshade::api::resource_view{rtv}, reshade::api::resource_view{rtv_srgb});
    q->flush_immediate_command_list();
    g_ext.store(true, std::memory_order_release);
    return 1;
}

EXPORT void wsrs_frame_end(void) { g_ext.store(false, std::memory_order_release); }
