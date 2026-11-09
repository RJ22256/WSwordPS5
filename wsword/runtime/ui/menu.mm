// In-game overlay menu built with Dear ImGui (Metal renderer on macOS, Vulkan elsewhere; input fed from SDL events).
//
// Threads: SDL events arrive on the main thread and are queued; the menu is laid out and drawn on the
// render thread inside backend_present, after the game image, into the same drawable.
#ifdef __APPLE__
#import <Metal/Metal.h>
#endif
#include <SDL3/SDL.h>
#include <math.h>
#include <pthread.h>
#include <atomic>
#include <string>
#include <vector>

#include "i18n.h"
#include "imgui.h"
#include "gyro_drag.h"
#include "option_rows.h"
#include "saves_tab.h"
#include "mods_tab.h"
#include "../mods.h"
#include "imgui_internal.h"  // (NavCursorVisible)
#include "osk.h"
#include "console.h"
#ifdef __APPLE__
#include "imgui_impl_metal.h"
#else
#include "imgui_impl_vulkan.h"
extern "C" bool vk_imgui_backend_init(void);  // runtime/nvn/vulkan/imgui_glue.cpp
#endif

extern "C" {
#include "../hle.h"
#include "../settings.h"
#include "../color_grade.h"
#include "../window_size.h"
extern "C" {
#include "../language.h"
}
#include "menu.h"
void input_reset(void);
void input_pc_escape(bool down);
void controls_bindings_draw(float scale);  // controls_ui.mm
#include "../input_bind.h"
#include "../perfmon.h"
#include "../paths.h"
#include "../pc_cursor.h"
}

// ------------------------------------------------------------------ state shared with the main thread
static std::atomic<bool> g_open{false};
static std::atomic<bool> g_text_busy{false};  // a text field / the on-screen keyboard has the keys (render thread: ui_text_busy)
static std::atomic<bool> g_want_window_apply{false};  // fullscreen or the window size changed
// (also from the game's Options screen, game_options.mm)
extern "C" void menu_request_window_apply(void) { g_want_window_apply.store(true); }
// The window size stepped through (left / right): applied once it stays put a moment, not at every size on the way
static std::atomic<uint64_t> g_size_apply_at{0};  // SDL_GetTicks() then (0: none)
extern "C" void menu_request_window_size_apply(void) { g_size_apply_at.store(SDL_GetTicks() + 600); }
extern "C" bool game_options_input_hold(void);  // game_options.mm: a binding capture from the game's Options screen

struct QEvent {
    enum { KEY, ANALOG, MOUSE_POS, MOUSE_BUTTON, WHEEL, TEXT, FOCUS } kind;
    ImGuiKey key;
    bool down;
    float value, x, y;
    int button;
    char text[32];
};
static pthread_mutex_t q_lock = PTHREAD_MUTEX_INITIALIZER;
static std::vector<QEvent> q_events;
static float g_pixel_density = 1;

static void push(const QEvent &e) {
    pthread_mutex_lock(&q_lock);
    q_events.push_back(e);
    pthread_mutex_unlock(&q_lock);
}

bool menu_is_open(void) { return g_open.load(); }
static void set_open(bool open);
extern "C" void menu_test_open(void) {
    set_open(true);
    if (getenv("SAVAGEWIND_MENU_TAB")) { extern int g_tab_request_ext; g_tab_request_ext = atoi(getenv("SAVAGEWIND_MENU_TAB")); }
}

void menu_tabs_focus(bool first_tab);
static void set_open(bool open) {
    if (open == g_open.load()) return;
    g_open.store(open);
    input_reset();  // nothing held while the menu had focus leaks into the game
    bind_capture_cancel();
    if (open) {
        static bool opened;  // the controller's cursor: the first tab (Controls) the first time this session, later the
        menu_tabs_focus(!opened);  // selected one
        opened = true;
    }
    else { settings_save(); osk_cancel(); g_text_busy = false; }
}

static ImGuiKey key_from_scancode(SDL_Scancode sc) {
    switch (sc) {
    case SDL_SCANCODE_UP: return ImGuiKey_UpArrow;
    case SDL_SCANCODE_DOWN: return ImGuiKey_DownArrow;
    case SDL_SCANCODE_LEFT: return ImGuiKey_LeftArrow;
    case SDL_SCANCODE_RIGHT: return ImGuiKey_RightArrow;
    case SDL_SCANCODE_RETURN: return ImGuiKey_Enter;
    case SDL_SCANCODE_KP_ENTER: return ImGuiKey_KeypadEnter;
    case SDL_SCANCODE_SPACE: return ImGuiKey_Space;
    case SDL_SCANCODE_TAB: return ImGuiKey_Tab;
    case SDL_SCANCODE_BACKSPACE: return ImGuiKey_Backspace;
    case SDL_SCANCODE_DELETE: return ImGuiKey_Delete;
    case SDL_SCANCODE_HOME: return ImGuiKey_Home;
    case SDL_SCANCODE_END: return ImGuiKey_End;
    case SDL_SCANCODE_PAGEUP: return ImGuiKey_PageUp;
    case SDL_SCANCODE_PAGEDOWN: return ImGuiKey_PageDown;
    case SDL_SCANCODE_LSHIFT: return ImGuiKey_LeftShift;
    case SDL_SCANCODE_RSHIFT: return ImGuiKey_RightShift;
    case SDL_SCANCODE_LCTRL: return ImGuiKey_LeftCtrl;
    case SDL_SCANCODE_RCTRL: return ImGuiKey_RightCtrl;
    case SDL_SCANCODE_LGUI: return ImGuiKey_LeftSuper;
    case SDL_SCANCODE_RGUI: return ImGuiKey_RightSuper;
    case SDL_SCANCODE_A: return ImGuiKey_A;
    case SDL_SCANCODE_C: return ImGuiKey_C;
    case SDL_SCANCODE_V: return ImGuiKey_V;
    case SDL_SCANCODE_X: return ImGuiKey_X;
    case SDL_SCANCODE_Z: return ImGuiKey_Z;
    case SDL_SCANCODE_Q: return ImGuiKey_Q;  // previous tab
    case SDL_SCANCODE_E: return ImGuiKey_E;  // next tab
    default: return ImGuiKey_None;
    }
}

// The button bound to A confirms, the one bound to B goes back (by default the Nintendo layout: the right face button
// confirms, the bottom one goes back; on the PS5 Cross and Circle, runtime/hle/bindings.c). So the menus follow the
// game's own A and B, however they are bound.
static ImGuiKey key_from_pad(Uint8 b) {
    if (b == g_bind_pad[BIND_A]) return ImGuiKey_GamepadFaceDown;   // activate
    if (b == g_bind_pad[BIND_B]) return ImGuiKey_GamepadFaceRight;  // cancel / back
    // (A or B on a trigger, not a button: the face buttons of the default layout confirm and go back)
    if (b == SDL_GAMEPAD_BUTTON_EAST && g_bind_pad[BIND_A] >= SDL_GAMEPAD_BUTTON_COUNT) return ImGuiKey_GamepadFaceDown;
    if (b == SDL_GAMEPAD_BUTTON_SOUTH && g_bind_pad[BIND_B] >= SDL_GAMEPAD_BUTTON_COUNT) return ImGuiKey_GamepadFaceRight;
    switch (b) {
    case SDL_GAMEPAD_BUTTON_NORTH: return ImGuiKey_GamepadFaceUp;
    case SDL_GAMEPAD_BUTTON_WEST: return ImGuiKey_GamepadFaceLeft;
    case SDL_GAMEPAD_BUTTON_DPAD_UP: return ImGuiKey_GamepadDpadUp;
    case SDL_GAMEPAD_BUTTON_DPAD_DOWN: return ImGuiKey_GamepadDpadDown;
    case SDL_GAMEPAD_BUTTON_DPAD_LEFT: return ImGuiKey_GamepadDpadLeft;
    case SDL_GAMEPAD_BUTTON_DPAD_RIGHT: return ImGuiKey_GamepadDpadRight;
    case SDL_GAMEPAD_BUTTON_LEFT_SHOULDER: return ImGuiKey_GamepadL1;
    case SDL_GAMEPAD_BUTTON_RIGHT_SHOULDER: return ImGuiKey_GamepadR1;
    case SDL_GAMEPAD_BUTTON_START: return ImGuiKey_GamepadStart;
    case SDL_GAMEPAD_BUTTON_BACK: return ImGuiKey_GamepadBack;
    default: return ImGuiKey_None;
    }
}

// ---- software keyboard (runtime/hle/swkbd.c: the game's name entry etc.) --------------------------------------
// The game thread waits in menu_keyboard_run (re-presenting the last frame); this dialog takes the text: typed
// directly when the player last used a keyboard, an on-screen keyboard (d-pad + A, B deletes, Start / + OK) when
// they last used a controller.
static std::atomic<int> g_kbd{0};  // 1 open, 2 confirmed, 3 cancelled
static std::atomic<bool> g_last_pad{false};
static char g_kbd_text[96];
static int g_kbd_max = 8;
// Window size's list over the game's Options screen (game_options.mm A_SIZE_LIST): up, and until when the press that
// closed it is kept from the game
static std::atomic<bool> g_sizes{false};
static std::atomic<uint64_t> g_sizes_hold{0};  // SDL_GetTicks()
extern "C" void game_options_size_picked(void);  // game_options.mm (the row shows the new size)
extern "C" void menu_size_list_open(void) {
    input_reset();
    g_sizes = true;
}
static bool capturing() { return g_open.load() || g_kbd.load() == 1 || g_sizes.load() || console_is_open(); }
// The game gets no input while this is true (runtime/hle/input.c): menu or name entry up, or a binding capture begun
// from the game's Options screen.
extern "C" bool menu_input_captured(void) {
    return capturing() || game_options_input_hold() || SDL_GetTicks() < g_sizes_hold.load();
}

// Esc opens the game's pause screen or backs out of a menu. F2 frees the mouse cursor; a click in the
// window holds it again (runtime/hle/input.c). (WSword) F1 - or Back + Start / the guide button on a controller - opens
// WSword's Settings over the game, in the Glass Slate look, as 0.2.8's did (Savage Wind had it off, its settings in the
// game's own Options only, which still has them). SAVAGEWIND_OVERLAY=0: off.
static bool overlay_enabled(void) {
    static const bool on = !getenv("SAVAGEWIND_OVERLAY") || *getenv("SAVAGEWIND_OVERLAY") != '0';
    return on;
}
static std::atomic<bool> g_cursor_free{false};
extern "C" bool menu_cursor_free(void) { return g_cursor_free.load() || pc_gyro_scene_active(); }

// The console (console.mm): ` or F12 opens and closes it; the game gets no input meanwhile (capturing)
static void set_console(bool open) {
    if (open == console_is_open()) return;
    console_set_open(open);
    input_reset();  // nothing held leaks into the game
}
// Ctrl+V: the system clipboard as typed text (ImGui has a clipboard of its own, which is not the system's). One line,
// at most 1000 bytes, in pieces that fit a text event, each ending on a whole character.
static void console_paste(void) {
    char *clip = SDL_GetClipboardText();
    if (!clip) return;
    const char *p = clip;
    int total = 0;
    while (*p && total < 1000) {
        QEvent q = {};
        q.kind = QEvent::TEXT;
        size_t n = 0;
        while (*p && n + 4 < sizeof q.text && total < 1000) {
            unsigned char c = (unsigned char)*p;
            size_t len = c < 0x80 ? 1 : c >= 0xF0 ? 4 : c >= 0xE0 ? 3 : c >= 0xC0 ? 2 : 1;
            if (strnlen(p, len) < len) { p += strnlen(p, len); break; }  // (cut off in the middle of a character)
            if (c < 0x20 || c == 0x7F) { if (n && q.text[n - 1] != ' ') q.text[n++] = ' '; p++; total++; continue; }
            memcpy(q.text + n, p, len);
            n += len; p += len; total += (int)len;
        }
        q.text[n] = 0;
        if (n) push(q);
    }
    SDL_free(clip);
}

static void notice_show(const char *text);  // (WSword: a hotkey's short notice, below)
static void capture_start(void);            // (Ctrl+F8, below)
#ifndef __APPLE__
extern "C" bool rts_available(void);
#endif
bool menu_handle_event(const SDL_Event *e) {
    static bool back_down, start_down;
    if (e->type == SDL_EVENT_WINDOW_FOCUS_LOST || e->type == SDL_EVENT_WINDOW_FOCUS_GAINED) {
        back_down = start_down = false;
        QEvent q = {};
        q.kind = QEvent::FOCUS;
        q.down = e->type == SDL_EVENT_WINDOW_FOCUS_GAINED;
        push(q);
        return false;  // the input runtime also releases its cached controls
    }
    // a binding capture (Controls tab, or the game's Options screen) takes the press
    if (bind_capture_event(e)) return true;
    if (e->type == SDL_EVENT_KEY_DOWN) g_last_pad = false;
    if (e->type == SDL_EVENT_GAMEPAD_BUTTON_DOWN) g_last_pad = true;
    if (g_kbd.load() == 1 && e->type == SDL_EVENT_KEY_DOWN && !e->key.repeat) {  // Enter confirms, Esc cancels
        if (e->key.scancode == SDL_SCANCODE_RETURN || e->key.scancode == SDL_SCANCODE_KP_ENTER) { g_kbd = 2; return true; }
        if (e->key.scancode == SDL_SCANCODE_ESCAPE) { g_kbd = 3; return true; }
    }
    if (g_kbd.load() == 1 && e->type == SDL_EVENT_GAMEPAD_BUTTON_DOWN && e->gbutton.button == SDL_GAMEPAD_BUTTON_START) {
        g_kbd = 2;
        return true;
    }
    // typing (a text field, the on-screen keyboard, the name entry): keys are text, not menu shortcuts
    bool typing = g_kbd.load() == 1 || console_is_open() || (g_open.load() && g_text_busy.load());
    if (e->type == SDL_EVENT_KEY_UP && e->key.scancode == SDL_SCANCODE_ESCAPE)
        input_pc_escape(false);
    if (pc_cursor_enabled() && !capturing() && !typing && !game_options_input_hold() &&
        (e->type == SDL_EVENT_KEY_DOWN || e->type == SDL_EVENT_KEY_UP) && e->key.scancode == SDL_SCANCODE_ESCAPE) {
        if (!e->key.repeat) input_pc_escape(e->type == SDL_EVENT_KEY_DOWN);
        return true;
    }
    if (e->type == SDL_EVENT_MOUSE_BUTTON_DOWN && g_cursor_free.load() && !capturing() && !pc_cursor_active() && !pc_gyro_scene_active()) {
        g_cursor_free = false;  // (the click only takes the cursor back)
        return true;
    }
    switch (e->type) {
    case SDL_EVENT_KEY_DOWN:
        if (!e->key.repeat && (e->key.scancode == SDL_SCANCODE_GRAVE || e->key.scancode == SDL_SCANCODE_F12) &&
            !g_open.load() && g_kbd.load() != 1 && !g_sizes.load()) {
            set_console(!console_is_open());
            return true;
        }
        if (console_is_open()) {
            if (e->key.scancode == SDL_SCANCODE_ESCAPE) { if (!e->key.repeat) set_console(false); return true; }
            if (e->key.scancode == SDL_SCANCODE_V && (e->key.mod & (SDL_KMOD_CTRL | SDL_KMOD_GUI))) {
                if (!e->key.repeat) console_paste();
                return true;
            }
        }
        if (!e->key.repeat && pc_cursor_enabled() && e->key.scancode == SDL_SCANCODE_F2 && !typing) {
            g_cursor_free = !g_cursor_free.load();
            return true;
        }
        if (!e->key.repeat && (e->key.scancode == SDL_SCANCODE_F1 ||
                               (!pc_cursor_enabled() && e->key.scancode == SDL_SCANCODE_ESCAPE && !g_open.load()))) {
            if (!overlay_enabled()) {
                if (e->key.scancode == (pc_cursor_enabled() ? SDL_SCANCODE_F2 : SDL_SCANCODE_ESCAPE) && !typing) g_cursor_free = !g_cursor_free.load();
                return true;
            }
            if (!typing) set_open(!g_open.load());  // (Esc with the menu open goes to ImGui below: it cancels a field)
            return true;
        }
        if (!e->key.repeat && e->key.scancode == SDL_SCANCODE_F6 && !typing) {  // (WSword) Ray-Tracing on / off
#ifndef __APPLE__
            if (rts_available()) {
                g_settings.rt_shadows = !g_settings.rt_shadows;
                settings_save();
                notice_show(g_settings.rt_shadows ? "Ray-Tracing: On" : "Ray-Tracing: Off");
            } else {
                notice_show("Ray-Tracing: not available on this graphics card");
            }
#endif
            return true;
        }
        // (WSword 0.3.17) Ctrl+F8: a performance capture - 15 seconds of the CPU's time, sampled (runtime/sampler.c,
        // Windows) into build\samples.txt for tools/profile_samples.py: where a CPU-bound frame's time goes
        if (!e->key.repeat && e->key.scancode == SDL_SCANCODE_F8 && (e->key.mod & SDL_KMOD_CTRL) && !typing) {
            capture_start();
            return true;
        }
        if (!e->key.repeat && e->key.scancode == SDL_SCANCODE_F10 && !typing) {  // performance overlay: off, FPS, full
            g_settings.perf_overlay = (g_settings.perf_overlay + 1) % 3;
            settings_save();
            return true;
        }
        if (!e->key.repeat && (e->key.scancode == SDL_SCANCODE_F11 ||
                               (e->key.scancode == SDL_SCANCODE_RETURN && (e->key.mod & (SDL_KMOD_ALT | SDL_KMOD_GUI))) ||
                               (e->key.scancode == SDL_SCANCODE_F && (e->key.mod & SDL_KMOD_GUI) && (e->key.mod & SDL_KMOD_CTRL)))) {
            g_settings.fullscreen = !g_settings.fullscreen;
            g_want_window_apply.store(true);
            settings_save();
            return true;
        }
        /* fallthrough */
    case SDL_EVENT_KEY_UP: {
        if (!capturing()) return false;
        bool down = e->type == SDL_EVENT_KEY_DOWN;
        if (down && e->key.scancode == SDL_SCANCODE_ESCAPE) {  // Esc: back out of popups, else close
            QEvent q = {};
            q.kind = QEvent::KEY; q.key = ImGuiKey_Escape; q.down = true; push(q);
            q.down = false; push(q);
            return true;
        }
        ImGuiKey k = key_from_scancode(e->key.scancode);
        if (g_sizes.load()) {  // Window size's list (in game): the keys bound to A, B and up / down work it too
            int sc = e->key.scancode;
            if (sc == g_bind_key[BIND_A]) k = ImGuiKey_Enter;
            else if (sc == g_bind_key[BIND_B]) k = ImGuiKey_Escape;
            else if (sc == g_bind_key[BIND_LS_UP] || sc == g_bind_key[BIND_UP]) k = ImGuiKey_UpArrow;
            else if (sc == g_bind_key[BIND_LS_DOWN] || sc == g_bind_key[BIND_DOWN]) k = ImGuiKey_DownArrow;
        }
        if (k != ImGuiKey_None) { QEvent q = {}; q.kind = QEvent::KEY; q.key = k; q.down = down; push(q); }
        return true;
    }
    case SDL_EVENT_TEXT_INPUT:
        if (!capturing()) return false;
        if (console_is_open() && (!strcmp(e->text.text, "`") || !strcmp(e->text.text, "^") || !strcmp(e->text.text, "~") ||
                                  !strcmp(e->text.text, "\xC2\xB0")))
            return true;  // (the key that opens the console is no text; ^ is that key on a German keyboard)
        { QEvent q = {}; q.kind = QEvent::TEXT; strlcpy(q.text, e->text.text, sizeof q.text); push(q); }
        return true;
    case SDL_EVENT_GAMEPAD_BUTTON_DOWN: case SDL_EVENT_GAMEPAD_BUTTON_UP: {
        bool down = e->type == SDL_EVENT_GAMEPAD_BUTTON_DOWN;
        if (e->gbutton.button == SDL_GAMEPAD_BUTTON_BACK) back_down = down;
        if (e->gbutton.button == SDL_GAMEPAD_BUTTON_START) start_down = down;
        if (down && !typing && overlay_enabled() &&
            ((back_down && start_down) || e->gbutton.button == SDL_GAMEPAD_BUTTON_GUIDE)) {
            set_open(!g_open.load());
            return true;
        }
        if (!capturing()) return false;
        ImGuiKey k = key_from_pad(e->gbutton.button);
        if (g_sizes.load()) {  // Window size's list (in game): the buttons bound to A and B, wherever they are
            int b = e->gbutton.button;
            if (b == g_bind_pad[BIND_A]) k = ImGuiKey_GamepadFaceDown;
            else if (b == g_bind_pad[BIND_B]) k = ImGuiKey_GamepadFaceRight;
        }
        if (k != ImGuiKey_None) { QEvent q = {}; q.kind = QEvent::KEY; q.key = k; q.down = down; push(q); }
        return true;
    }
    case SDL_EVENT_GAMEPAD_AXIS_MOTION: {
        if (!capturing()) return false;
        float v = e->gaxis.value / 32767.0f;
        QEvent q = {};
        q.kind = QEvent::ANALOG;
        switch (e->gaxis.axis) {
        case SDL_GAMEPAD_AXIS_LEFTX:
            q.key = ImGuiKey_GamepadLStickLeft; q.value = v < -0.3f ? -v : 0; push(q);
            q.key = ImGuiKey_GamepadLStickRight; q.value = v > 0.3f ? v : 0; push(q);
            break;
        case SDL_GAMEPAD_AXIS_LEFTY:
            q.key = ImGuiKey_GamepadLStickUp; q.value = v < -0.3f ? -v : 0; push(q);
            q.key = ImGuiKey_GamepadLStickDown; q.value = v > 0.3f ? v : 0; push(q);
            break;
        case SDL_GAMEPAD_AXIS_LEFT_TRIGGER: q.key = ImGuiKey_GamepadL2; q.value = v; push(q); break;
        case SDL_GAMEPAD_AXIS_RIGHT_TRIGGER: q.key = ImGuiKey_GamepadR2; q.value = v; push(q); break;
        default: break;
        }
        return true;
    }
    case SDL_EVENT_MOUSE_MOTION:
        if (!capturing() && !pc_gyro_scene_active()) return false;
        { QEvent q = {}; q.kind = QEvent::MOUSE_POS; q.x = e->motion.x * g_pixel_density; q.y = e->motion.y * g_pixel_density; push(q); }
        return true;
    case SDL_EVENT_MOUSE_BUTTON_DOWN: case SDL_EVENT_MOUSE_BUTTON_UP:
        if (!capturing() && !pc_gyro_scene_active()) return false;
        {
            QEvent q = {};
            q.kind = QEvent::MOUSE_BUTTON;
            q.button = e->button.button == SDL_BUTTON_LEFT ? 0 : e->button.button == SDL_BUTTON_RIGHT ? 1 : 2;
            q.down = e->type == SDL_EVENT_MOUSE_BUTTON_DOWN;
            push(q);
        }
        return true;
    case SDL_EVENT_MOUSE_WHEEL:
        if (!capturing() && !pc_gyro_scene_active()) return false;
        { QEvent q = {}; q.kind = QEvent::WHEEL; q.x = e->wheel.x; q.y = e->wheel.y; push(q); }
        return true;
    default:
        return false;
    }
}

void menu_apply_window_requests(void *win) {
    SDL_Window *w = (SDL_Window *)win;
    g_pixel_density = SDL_GetWindowPixelDensity(w);
    static bool text_input;
    bool want_text = capturing();
    if (want_text != text_input) {
        if (want_text) SDL_StartTextInput(w);
        else SDL_StopTextInput(w);
        text_input = want_text;
    }
    char *copy;
    if (console_take_copy(&copy)) { SDL_SetClipboardText(copy); free(copy); }
    // (the window was made at its size and fullscreen mode: ui_window_init)
    uint64_t at = g_size_apply_at.load();
    if (at && SDL_GetTicks() >= at && g_size_apply_at.compare_exchange_strong(at, 0)) g_want_window_apply.store(true);
    if (g_want_window_apply.exchange(false)) winsize_apply(w);
    else winsize_refresh(w);  // (moved to another display, or its desktop size changed: other sizes are offered)
}

// ------------------------------------------------------------------ render thread
static bool g_inited;
static ImGuiContext *g_ctx;  // ours: the start screen (back to it after a reboot) has its own context
static ImFont *g_font, *g_font_big;
static ImFont *g_font_mono;  // the console (columns line up); NULL: the normal font
static ImFont *g_menu_font, *g_menu_font_big;  // the menu window (Fira Sans); everything else keeps g_font
static int g_tab = -99, g_tab_request = -2;  // (-2: no request; -1 is the start screen's Files; g_tab -99: none yet - the first)
static int g_focus_tab = -99;  // put the nav cursor on this tab next frame (-100: the selected one; -99: none)
static int g_focus_frames;

// The start screen's Settings opening: the controller's cursor starts on the first tab the first time in a session,
// later on the tab that's selected
void menu_tabs_focus(bool first_tab) { g_focus_tab = first_tab ? -1 : -100, g_focus_frames = 0; }
int g_tab_request_ext = -1;

static void style_init(void) {
    ImGuiStyle &s = ImGui::GetStyle();
    ImGui::StyleColorsDark();
    s.WindowRounding = 14; s.FrameRounding = 8; s.GrabRounding = 8; s.TabRounding = 8; s.ChildRounding = 10;
    s.WindowPadding = ImVec2(28, 24); s.FramePadding = ImVec2(14, 8); s.ItemSpacing = ImVec2(14, 12);
    s.WindowBorderSize = 0; s.ScrollbarSize = 18;
    ImVec4 *c = s.Colors;
    ImVec4 gold(0.93f, 0.76f, 0.33f, 1), gold_dim(0.62f, 0.49f, 0.20f, 1), green(0.15f, 0.36f, 0.25f, 1);
    c[ImGuiCol_WindowBg] = ImVec4(0.06f, 0.09f, 0.08f, 0.94f);
    c[ImGuiCol_ChildBg] = ImVec4(0.09f, 0.13f, 0.11f, 0.85f);
    c[ImGuiCol_PopupBg] = ImVec4(0.07f, 0.10f, 0.09f, 0.98f);
    c[ImGuiCol_Text] = ImVec4(0.96f, 0.94f, 0.88f, 1);
    c[ImGuiCol_TextDisabled] = ImVec4(0.62f, 0.64f, 0.58f, 1);
    c[ImGuiCol_FrameBg] = ImVec4(0.13f, 0.19f, 0.16f, 1);
    c[ImGuiCol_FrameBgHovered] = green;
    c[ImGuiCol_FrameBgActive] = ImVec4(0.19f, 0.45f, 0.31f, 1);
    c[ImGuiCol_Button] = ImVec4(0.14f, 0.22f, 0.18f, 1);
    c[ImGuiCol_ButtonHovered] = green;
    c[ImGuiCol_ButtonActive] = ImVec4(0.21f, 0.50f, 0.34f, 1);
    c[ImGuiCol_Header] = green;
    c[ImGuiCol_HeaderHovered] = ImVec4(0.19f, 0.45f, 0.31f, 1);
    c[ImGuiCol_HeaderActive] = ImVec4(0.21f, 0.50f, 0.34f, 1);
    c[ImGuiCol_Tab] = ImVec4(0.12f, 0.18f, 0.15f, 1);
    c[ImGuiCol_TabHovered] = green;
    c[ImGuiCol_TabSelected] = ImVec4(0.21f, 0.44f, 0.31f, 1);
    c[ImGuiCol_TabSelectedOverline] = gold;
    c[ImGuiCol_CheckMark] = gold;
    c[ImGuiCol_SliderGrab] = gold_dim;
    c[ImGuiCol_SliderGrabActive] = gold;
    c[ImGuiCol_NavCursor] = gold;
    c[ImGuiCol_Separator] = ImVec4(0.30f, 0.36f, 0.30f, 1);
    c[ImGuiCol_TitleBg] = c[ImGuiCol_TitleBgActive] = c[ImGuiCol_WindowBg];
    // (WSword's Glass Slate look, as the start screen: deep navy glass, cyan where something is picked)
    ImVec4 field(0.059f, 0.118f, 0.2f, 1), field_hot(0.078f, 0.157f, 0.259f, 1), field_on(0.071f, 0.2f, 0.286f, 1);
    ImVec4 cyan(0.369f, 0.902f, 0.961f, 1);
    c[ImGuiCol_WindowBg] = ImVec4(0.035f, 0.075f, 0.133f, 0.95f);
    c[ImGuiCol_ChildBg] = ImVec4(0, 0, 0, 0);
    c[ImGuiCol_PopupBg] = ImVec4(0.039f, 0.086f, 0.157f, 0.98f);
    c[ImGuiCol_Text] = ImVec4(0.918f, 0.949f, 0.98f, 1);
    c[ImGuiCol_TextDisabled] = ImVec4(0.624f, 0.702f, 0.784f, 1);
    c[ImGuiCol_Border] = ImVec4(0.137f, 0.255f, 0.373f, 1);
    c[ImGuiCol_FrameBg] = field;
    c[ImGuiCol_FrameBgHovered] = field_hot;
    c[ImGuiCol_FrameBgActive] = field_on;
    c[ImGuiCol_Button] = field;
    c[ImGuiCol_ButtonHovered] = field_hot;
    c[ImGuiCol_ButtonActive] = field_on;
    c[ImGuiCol_Header] = field_hot;
    c[ImGuiCol_HeaderHovered] = field_on;
    c[ImGuiCol_HeaderActive] = field_on;
    c[ImGuiCol_Tab] = field;
    c[ImGuiCol_TabHovered] = field_hot;
    c[ImGuiCol_TabSelected] = field_on;
    c[ImGuiCol_TabSelectedOverline] = cyan;
    c[ImGuiCol_CheckMark] = cyan;
    c[ImGuiCol_SliderGrab] = ImVec4(0.30f, 0.70f, 0.80f, 1);
    c[ImGuiCol_SliderGrabActive] = cyan;
    c[ImGuiCol_NavCursor] = cyan;
    c[ImGuiCol_Separator] = ImVec4(0.11f, 0.208f, 0.314f, 1);
    c[ImGuiCol_ScrollbarBg] = ImVec4(0, 0, 0, 0);
    c[ImGuiCol_ScrollbarGrab] = ImVec4(0.18f, 0.30f, 0.42f, 0.9f);
    c[ImGuiCol_ScrollbarGrabHovered] = ImVec4(0.24f, 0.40f, 0.54f, 1);
    c[ImGuiCol_ScrollbarGrabActive] = cyan;
    c[ImGuiCol_TitleBg] = c[ImGuiCol_TitleBgActive] = c[ImGuiCol_WindowBg];
    s.FrameRounding = 10; s.ChildRounding = 12; s.WindowRounding = 22; s.PopupRounding = 18; s.ScrollbarRounding = 8;
    s.FrameBorderSize = 1;
}


// The fonts, with the menu language's glyphs that Latin fonts lack merged in (runtime/ui/i18n.mm); made again when the
// menu language changes (fonts_follow_language).
static int g_fonts_lang = -1;
static void load_fonts(void) {
    ImGuiIO &io = ImGui::GetIO();
    io.Fonts->Clear();
    g_font = g_font_big = g_menu_font = g_menu_font_big = g_font_mono = NULL;
    g_fonts_lang = ui_lang_generation();
    ImFontConfig cfg;
    cfg.OversampleH = 2;
    auto add = [&](const char *path, float size, ImFontConfig c) {
        ImFont *f = io.Fonts->AddFontFromFileTTF(path, size, &c);
        if (f) ui_merge_fallback_font(io.Fonts, size, &cfg);
        return f;
    };
    const char *paths[] = {"/System/Library/Fonts/Avenir Next.ttc", "/System/Library/Fonts/Helvetica.ttc",
                           "C:/Windows/Fonts/segoeui.ttf", "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
                           "/usr/share/fonts/TTF/DejaVuSans.ttf", "/usr/share/fonts/dejavu-sans-fonts/DejaVuSans.ttf"};
    for (const char *p : paths) {
        if (FILE *f = fopen(p, "rb")) fclose(f);  // a missing file is an assertion in ImGui, not a NULL return
        else continue;
        if (!g_font) g_font = add(p, 34, cfg);
        if (g_font && !g_font_big) { ImFontConfig b = cfg; b.FontNo = 0; g_font_big = add(p, 56, b); }
    }
    const char *mono_paths[] = {"/System/Library/Fonts/Menlo.ttc", "C:/Windows/Fonts/consola.ttf",
                                "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf", "/usr/share/fonts/TTF/DejaVuSansMono.ttf",
                                "/usr/share/fonts/dejavu-sans-mono-fonts/DejaVuSansMono.ttf"};
    for (const char *p : mono_paths) {
        if (FILE *f = fopen(p, "rb")) fclose(f);
        else continue;
        g_font_mono = add(p, 28, cfg);
        if (g_font_mono) break;
    }
    // the menu window itself: Fira Sans, as on the start screen (shipped, OFL) - Medium for the rows, SemiBold for the
    // titles - at its Settings window's sizes; the FPS counter, overlays and on-screen keyboard keep the fonts above
    char med[1024], semi[1024];
    const char *test = getenv("SAVAGEWIND_MENU_FONT");  // (test) another weight / face
    if (test) strlcpy(med, test, sizeof med), strlcpy(semi, test, sizeof semi);
    // (WSword's Glass Slate look: Inter Medium / Bold, OFL, as the start screen - Fira Sans if they're missing)
    if (!test && rt_resource("Inter-Medium.otf", "third_party/fonts/Inter/Inter-Medium.otf", med, sizeof med) &&
        rt_resource("Inter-Bold.otf", "third_party/fonts/Inter/Inter-Bold.otf", semi, sizeof semi)) {
        g_menu_font = add(med, 29 * 0.96f, cfg);
        g_menu_font_big = add(semi, 53.5f * 0.96f, cfg);
    } else if (test || (rt_resource("FiraSans-Medium.ttf", "third_party/fonts/FiraSans/FiraSans-Medium.ttf", med, sizeof med) &&
                        rt_resource("FiraSans-SemiBold.ttf", "third_party/fonts/FiraSans/FiraSans-SemiBold.ttf", semi, sizeof semi))) {
        g_menu_font = add(med, 29, cfg);
        g_menu_font_big = add(semi, 53.5f, cfg);
    }
    if (!g_font) g_font = io.Fonts->AddFontDefault();
    if (!g_font_big) g_font_big = g_font;
    if (!g_menu_font || !g_menu_font_big) g_menu_font = g_font, g_menu_font_big = g_font_big;
}

// Before a frame: another menu language may need other glyphs - the fonts and their texture are made again
extern "C" void vk_imgui_fonts_changed(void);  // (runtime/nvn/vulkan/imgui_glue.cpp)
static void fonts_follow_language(void) {
    if (g_fonts_lang == ui_lang_generation()) return;
    load_fonts();
#ifdef __APPLE__
    ImGui_ImplMetal_DestroyFontsTexture();  // (NewFrame makes it again)
#else
    vk_imgui_fonts_changed();
#endif
}

#ifdef __APPLE__
static void init(id<MTLDevice> dev) {
#else
static void init(void) {
#endif
    IMGUI_CHECKVERSION();
    g_ctx = ImGui::CreateContext();
    ImGui::SetCurrentContext(g_ctx);
    ImGuiIO &io = ImGui::GetIO();
    io.ConfigFlags |= ImGuiConfigFlags_NavEnableKeyboard | ImGuiConfigFlags_NavEnableGamepad;
    io.BackendFlags |= ImGuiBackendFlags_HasGamepad;
    io.IniFilename = NULL;
    load_fonts();
    style_init();
#ifdef __APPLE__
    ImGui_ImplMetal_Init(dev);
#else
    vk_imgui_backend_init();
#endif
    g_inited = true;
}

static void drain_events(ImGuiIO &io) {
    pthread_mutex_lock(&q_lock);
    std::vector<QEvent> ev;
    ev.swap(q_events);
    pthread_mutex_unlock(&q_lock);
    for (const QEvent &q : ev) {
        switch (q.kind) {
        case QEvent::KEY: io.AddKeyEvent(q.key, q.down); break;
        case QEvent::ANALOG: io.AddKeyAnalogEvent(q.key, q.value > 0.1f, q.value); break;
        case QEvent::MOUSE_POS: io.AddMousePosEvent(q.x, q.y); break;
        case QEvent::MOUSE_BUTTON: io.AddMouseButtonEvent(q.button, q.down); break;
        case QEvent::WHEEL: io.AddMouseWheelEvent(q.x, q.y); break;
        case QEvent::TEXT: io.AddInputCharactersUTF8(q.text); break;
        case QEvent::FOCUS: io.AddFocusEvent(q.down); break;
        }
    }
}

// Section header in the big font.
static void header(const char *t) {
    ImGui::PushFont(g_font_big);
    ImGui::TextColored(ImVec4(0.93f, 0.76f, 0.33f, 1), "%s", tr(t));
    ImGui::PopFont();
    ImGui::Separator();
    ImGui::Spacing();
}

static void hint(const char *t) {
    ImGui::PushTextWrapPos(0);
    ImGui::TextDisabled("%s", tr(t));
    ImGui::PopTextWrapPos();
}

// A row with a label on the left and a choice of options on the right (dpad left/right cycles).
// reserve: room kept free right of the combo (a button on the same line)
static bool choice(const char *label, int *value, const char *const *names, int n, float reserve = 0) {
    ImGui::PushID(label);
    ImGui::AlignTextToFramePadding();
    ImGui::TextUnformatted(tr(label));
    ImGui::SameLine(ImGui::GetContentRegionAvail().x * 0.45f);
    bool changed = false;
    ImGui::SetNextItemWidth(reserve > 0 ? -reserve : -1);
    if (ImGui::BeginCombo("##c", tr(names[*value]))) {
        for (int i = 0; i < n; i++) {
            ImGui::PushID(i);
            if (ImGui::Selectable(tr(names[i]), i == *value)) { *value = i; changed = true; }
            ImGui::PopID();
            if (i == *value) ImGui::SetItemDefaultFocus();
        }
        ImGui::EndCombo();
    }
    if (ImGui::IsItemFocused() && !ImGui::IsPopupOpen("##c")) {
        if (ImGui::IsKeyPressed(ImGuiKey_GamepadDpadRight) || ImGui::IsKeyPressed(ImGuiKey_RightArrow)) {
            *value = (*value + 1) % n; changed = true;
        }
        if (ImGui::IsKeyPressed(ImGuiKey_GamepadDpadLeft) || ImGui::IsKeyPressed(ImGuiKey_LeftArrow)) {
            *value = (*value + n - 1) % n; changed = true;
        }
    }
    ImGui::PopID();
    return changed;
}

static bool toggle(const char *label, bool *v) {
    const char *names[] = {"Off", "On"};
    int i = *v;
    bool ch = choice(label, &i, names, 2);
    *v = i;
    return ch;
}

extern "C" void renderer_get_scale(float *sx, float *sy);
extern "C" void renderer_get_scene_scale(float *sx, float *sy);
extern "C" bool renderer_gpu_rtx(void);  // (vulkan/device.c, metal.m)
extern "C" volatile int g_fg_active;     // (hle/framepace.c: the last presented frame was generated)
extern "C" void vk_lsfg_status(char *out, size_t n);  // (WSword: vulkan/device.c, Lossless frame generation's state)
extern "C" void dlss_status(char *out, size_t n);     // (WSword: vulkan/dlss.c, NVIDIA DLSS's state)
#ifndef __APPLE__
extern "C" bool renderer_gpu_rtx40(void);             // (WSword: vulkan/device.c, an RTX 40 or newer)
extern "C" const char *dlss_model_in_use(void);       // (WSword: vulkan/dlss.c, the model DLSS runs and its GPU time)
extern "C" float dlss_gpu_ms(void);
extern "C" void dlssg_status(char *out, size_t n);    // (WSword: vulkan/dlssg.c, NVIDIA DLSS frame generation)
extern "C" bool dlssg_gpu_ok(void);
extern "C" bool dlssg_gpu_mfg(void);
extern "C" void reshade_status(char *out, size_t n);  // (WSword: vulkan/reshade.c, the player's own ReShade)
extern "C" void rts_status(char *out, size_t n);  // (WSword: vulkan/rtshadow.c, ray-traced sun shadows)
extern "C" bool rts_available(void);
#endif
// Video > Upscaler mode's names, by UPQ_*
static const char *const k_upscale_modes[UPQ_COUNT] = {"Ultra Quality", "Quality", "Balanced", "Performance", "Ultra Performance"};
extern "C" {
#include "../nvn/output_scale.h"
}

#ifndef __APPLE__
// Colour (runtime/color_grade.h; vulkan/exec.c scene_post), the Video tab's last section: a preset sets the sliders,
// which then show "Custom" when they match none
static void tab_colour(void) {
    opt_section("Colour");
    {
        static std::string names_buf[16];
        const char *names[16];
        bool avail[16];
        int n = g_color_preset_count;
        for (int i = 0; i <= n && i < 16; i++) {
            names_buf[i] = tr(i < n ? g_color_presets[i].name : "Custom");
            names[i] = names_buf[i].c_str();
            avail[i] = i < n;
        }
        static int shown = -1;
        int v = color_preset_current();
        if (v < 0) v = n;  // (custom: shown, never picked)
        if (opt_choice_avail("Colour preset", &v, &shown, names, avail, n + 1, 0,
                             "Ready-made looks for the 3D image, made from the sliders below: Natural is the game's "
                             "own colours, Warm and Cool shift the light, Vivid and Cinematic add contrast, Muted "
                             "calms the colours. The HUD and menus keep their colours.") && v < n)
            color_preset_apply(v);
    }
    float ev = g_settings.color_exposure / 10.0f;
    if (opt_slider("Exposure", &ev, -2, 2, 0.1f, 0, "%+.1f EV",
                   "Makes the 3D image brighter or darker, in stops: +1 EV is twice as bright."))
        g_settings.color_exposure = (int)lroundf(ev * 10);
    opt_int("Contrast", &g_settings.color_contrast, -50, 50, 5, 0, "%+d",
            "More (or less) difference between dark and bright areas. Shadows and highlights keep their detail.");
    opt_int("Saturation", &g_settings.color_saturation, -100, 100, 5, 0, "%+d",
            "How strong the colours are. -100: black and white.");
    opt_int("Temperature", &g_settings.color_temperature, -100, 100, 5, 0, "%+d",
            "The colour of the light: below 0 cooler (bluer), above 0 warmer (more orange).");
    opt_int("Tint", &g_settings.color_tint, -100, 100, 5, 0, "%+d",
            "Below 0 toward green, above 0 toward magenta: evens out a colour cast.");
    {   // LUT: None, the shipped ones, the player's own (listed again every couple of seconds while shown)
        static int n;
        static uint64_t at;
        if (!n || SDL_GetTicks() - at > 2000) n = color_lut_list(), at = SDL_GetTicks();
        static std::string none;
        none = tr("None");
        const char *names[COLOR_LUT_MAX];
        for (int i = 0; i < n; i++) names[i] = i ? color_lut_name(i) : none.c_str();
        int cur = color_lut_index(g_settings.color_lut);
        char desc[1500];
        snprintf(desc, sizeof desc,
                 tr("A look-up table (LUT) that recolours the 3D image. WSword's own are listed first. Your own LUTs "
                    "go in this folder: .cube files (up to 64 x 64 x 64) and ReShade-style .png strips (1024 x 32, "
                    "4096 x 64). They are listed by file name.\n\n%s"), color_lut_folder());
        bool picked;
        if (opt_list("LUT", &cur, names, n, 0, desc, &picked))
            snprintf(g_settings.color_lut, sizeof g_settings.color_lut, "%s", color_lut_id(cur));
    }
    opt_indent(1);
    if (!g_settings.color_lut[0]) opt_disable_next();
    opt_int("LUT intensity", &g_settings.color_lut_strength, 0, 100, 5, 100, "%d%%",
            "How much of the LUT's look is used: 100% is all of it, 0% none.");
    opt_indent(-1);
}
#endif

static void tab_display(void) {
    float scale = ImGui::GetFontSize() / 34;
    opt_begin("##video", scale);
#ifndef __APPLE__
    // (0.3.15, Glass Slate 2) Ray-Tracing first on the page, as a card: the switch and its F6
    {   // (WSword) ray-traced sun shadows (vulkan/rtshadow.c): GPUs with hardware ray tracing
        char st[300];
        rts_status(st, sizeof st);
        static std::string d;
        d = std::string(tr("Your graphics card's ray tracing (NVIDIA RTX, AMD Radeon RX 6000 and newer, Intel Arc) on the "
                           "game's own objects: the sun's shadows traced - sharp where things touch, softening with "
                           "distance, without the maps' blur and shimmer - and ambient occlusion: the shade in corners, "
                           "under rocks and around Link where the sky's light can't reach - and reflections on water: "
                           "what's around a lake, a river or the sea mirrored in it, rippling with its waves, where it's "
                           "on screen (the sky and what's out of view keep the game's own reflection). Costs GPU time (a "
                           "few milliseconds). F6 in the game turns it on and off.")) + "\n\n" + tr(st);
        if (!rts_available()) opt_disable_next();
        opt_hero_next(rts_available() ? "Ray-traced sun shadows, ambient occlusion and water reflections."
                                      : "Needs a graphics card with hardware ray tracing.", "F6");
        opt_toggle("Ray-Tracing", &g_settings.rt_shadows, false, d.c_str());
    }
#endif
    {   // (WSword) Mode: the start screen card's sets of the options below (settings.c mode_into); Custom when they
        // match none - shown, never picked
        opt_section("Mode");
#ifdef __PROSPERO__
        static const char *const mn[MODE_COUNT + 1] = {"Performance", "Quality", "Custom"};
        static const bool avail[MODE_COUNT + 1] = {true, true, false};
        const char *md = "Performance: 60 fps, the game drawn at 1080p - the game's own draw distance, sharper shadows. "
                         "Quality: 30 fps, the game drawn at 1440p, with Ray-Tracing (shadows, ambient occlusion, water "
                         "reflections), High draw distance and the sharpest shadows. The TV gets each mode's own "
                         "resolution. With frame generation (below), Performance shows 120 on a 120 Hz TV and Quality "
                         "60. Custom: your own settings below.";
#else
        static const char *const mn[MODE_COUNT + 1] = {"Battery", "Performance", "Turbo", "Unlocked", "Custom"};
        static const bool avail[MODE_COUNT + 1] = {true, true, true, true, false};
        const char *md = "Ready-made sets of the frame rate and the upscaler, as on the start screen's card. Battery: 30 "
                         "fps, the game drawn smaller and AMD FSR 1 onto the window - for a laptop on its battery. "
                         "Performance: 60 fps at the window's full resolution. Turbo: 120 fps, for a 120 Hz monitor. "
                         "Unlocked: no limit (VSync still caps it at the monitor's rate). Custom: your own settings "
                         "below. With frame generation on, the frame rate counts the frames on screen.";
#endif
        static int shown = -1;
        int m = settings_current_mode();
        if (opt_choice_avail("Mode", &m, &shown, mn, avail, MODE_COUNT + 1, MODE_PERFORMANCE, md))
            settings_apply_mode(m);
    }
    opt_section("Display");
    bool fs = g_settings.fullscreen;
    if (opt_toggle("Fullscreen", &fs, false, "Fills the screen. Also: F11, Alt+Enter or Cmd+Ctrl+F.")) {
        g_settings.fullscreen = fs;
        g_want_window_apply.store(true);
    }
    {   // Fullscreen mode (settings.h FSMODE_*; runtime/window_size.c winsize_apply)
        static const char *const names[FSMODE_COUNT] = {"Automatic", "Borderless", "Exclusive"};
        int cur = g_settings.fullscreen_mode;
        opt_indent(1);
        if (opt_choice("Fullscreen mode", &cur, names, FSMODE_COUNT, FSMODE_AUTO,
                       "Automatic: borderless at your display's own size, the display switched to the size chosen at "
                       "any other.\n\nBorderless: never switches the display; another size is scaled to the screen. "
                       "Quick to switch away from.\n\nExclusive: the display switched to the size chosen, at its "
                       "highest refresh rate, its own size too.")) {
            g_settings.fullscreen_mode = cur;
            if (g_settings.fullscreen) g_want_window_apply.store(true);
        }
        opt_indent(-1);
    }
    {   // Monitor (runtime/window_size.c): Automatic, then the displays connected (and the one set, while it isn't)
        WinDisplay ds[WINDISPLAY_MAX];
        static char names_buf[WINDISPLAY_MAX + 2][96];
        const char *names[WINDISPLAY_MAX + 2];
        int n = windisplay_list(ds), cur = windisplay_target(), gone = -1;
        names[0] = "Automatic";
        for (int i = 0; i < n; i++) {
            windisplay_name(&ds[i], i + 1, tr("primary"), names_buf[i + 1], sizeof names_buf[i + 1]);
            names[i + 1] = names_buf[i + 1];
        }
        if (g_settings.display > 0 && !cur) {
            snprintf(names_buf[n + 1], sizeof names_buf[n + 1], tr("%s (not connected)"), g_settings.display_name);
            names[n + 1] = names_buf[n + 1];
            cur = gone = n + 1;
        }
        int pick = cur;
        if (opt_choice("Monitor", &pick, names, n + 1 + (gone >= 0), 0,
                       "The monitor the game is shown on, in a window or fullscreen. Automatic: where the window is "
                       "(the primary monitor at start). A monitor that isn't connected is Automatic until it is.") &&
            pick != gone) {
            windisplay_set(pick);
            g_want_window_apply.store(true);
        }
    }
    {   // Window size (runtime/window_size.c): the sizes the display can show, its own first, then grouped by shape
        WinSize list[WINSIZE_MAX];
        static char names_buf[WINSIZE_MAX][64];
        const char *names[WINSIZE_MAX];
        int n = winsize_list(list, g_settings.fullscreen), cur = 0, def = 0;
        WinSize e = winsize_effective(g_settings.fullscreen), d = winsize_default(g_settings.fullscreen);
        WinSize desk = winsize_desktop();
        for (int i = 0; i < n; i++) {
            winsize_name(list[i], tr("native"), names_buf[i], sizeof names_buf[i]);
            names[i] = names_buf[i];
            if (list[i].w == e.w && list[i].h == e.h) cur = i;
            if (list[i].w == d.w && list[i].h == d.h) def = i;
        }
        char desc[600];
        snprintf(desc, sizeof desc, tr("The size of the game's window, or of the screen in fullscreen. Only the sizes your "
                                       "display can show: its own first, then grouped by shape. Any shape other than 16:9 "
                                       "is filled with Fill wide screens on; off, it keeps 16:9 with bars.\n\nYour display: %d x %d."), desk.w, desk.h);
        bool picked;
        if (opt_list("Window size", &cur, names, n, def, desc, &picked)) {  // (past either end: the other one)
            g_settings.window_w = list[cur].w, g_settings.window_h = list[cur].h;
            if (picked) g_want_window_apply.store(true);
            else menu_request_window_size_apply();  // (stepping: the size where it stops)
        }
    }
    {   // Fill wide screens (runtime/nvn/output_scale.c rt_persp)
        bool wv = g_settings.wide_view;
        if (opt_toggle("Fill wide screens", &wv, true,
                       "On a window or screen that isn't 16:9 the game shows more of the world instead of black bars: "
                       "to the sides when it's wider (21:9, 32:9), above and below when it's taller (16:10, 4:3). "
                       "The HUD stays 16:9 in the middle; the pause menu, the map and the start screen are shown "
                       "16:9."))
            g_settings.wide_view = wv;
    }
    {   // Field of view (runtime/nvn/output_scale.c rt_persp)
        static const int fov[] = FOV_CHOICES;
        enum { NV = sizeof fov / sizeof fov[0] };
        static char names_buf[NV][16];
        const char *names[NV];
        int cur = 0, def = 0;
        for (int i = 0; i < NV; i++) {
            snprintf(names_buf[i], sizeof names_buf[i], "%d%%", fov[i]);
            names[i] = names_buf[i];
            if (fov[i] == g_settings.fov) cur = i;
            if (fov[i] == 100) def = i;
        }
        if (opt_choice("Field of view", &cur, names, NV, def,
                       "How much of the world the camera shows in play: 100% is the game's own. Cutscenes and "
                       "conversations keep theirs.", false))
            g_settings.fov = fov[cur];
    }
    {   // Draw distance (runtime/draw_distance.c)
        static const char *const names[DRAWDIST_COUNT] = {"Original", "Medium", "High", "Extreme+"};  // (DRAWDIST_*)
        int cur = g_settings.draw_distance;
        if (opt_choice("Draw distance", &cur, names, DRAWDIST_COUNT, DRAWDIST_ORIGINAL,
                       "How far out grass, trees, rocks, buildings and enemies appear. Higher costs more CPU and GPU time. "
                       "Extreme+: as far as the game takes - trees, rocks, buildings and enemies 1.4 times the game's "
                       "distance, far buildings and the distant forests 1.5 times, grass as High's (its own limit). "
                       "Further than that the game leaves buildings out or crashes while it loads the world.",
                       true))
            g_settings.draw_distance = cur;
    }
    {   // Frame rate (runtime/hle/framepace.c)
        static const int fps[] = FPS_CHOICES;
        enum { NF = sizeof fps / sizeof fps[0] };
        static char names_buf[NF][32];
        const char *names[NF];
        int cur = 0, def = 0;
        for (int i = 0; i < NF; i++) {
            if (fps[i]) snprintf(names_buf[i], sizeof names_buf[i], tr("%d FPS"), fps[i]);
            names[i] = fps[i] ? names_buf[i] : "Off";
            if (fps[i] == g_settings.fps_limit) cur = i;
            if (fps[i] == FPS_DEFAULT) def = i;
        }
        std::string desc = tr("How many pictures a second the game draws. The game itself runs at the same speed at "
                              "every rate (the console runs it at 30). Higher rates need a faster computer. Menus, "
                              "cutscenes and conversations use it too, and videos play at their own speed. Off: as "
                              "many as the computer can draw, up to 1000.");
        int hz = (int)lroundf(winsize_refresh_rate());
        if (hz > 0) {
            char line[200];
            snprintf(line, sizeof line, tr("Your display refreshes %d times a second: a rate above that shows no more "
                                           "pictures, and one that divides it evenly is the smoothest."), hz);
            desc += std::string("\n\n") + line;
        }
        if (opt_choice("Frame rate", &cur, names, NF, def, desc.c_str(), false)) g_settings.fps_limit = fps[cur];
    }
    {   // VSync (settings.h VSYNC_*: runtime/nvn/vulkan/device.c, runtime/hle/framepace.c)
        static const char *const names[VSYNC_COUNT] = {"On", "Fast", "Adaptive", "Off"};
        std::string desc = tr("On: no tearing; the game waits for the display. With G-SYNC or FreeSync the display "
                              "waits for the game instead: each frame shows as soon as it's ready, and the frame rate "
                              "stays a little under the display's refresh rate. Fast: no tearing and no waiting: each "
                              "refresh shows the newest frame. Adaptive: as On, but a frame that comes late shows at "
                              "once and may tear. Off: each frame shows at once: the least delay, but it tears.");
        float hz = winsize_refresh_rate();
        if (hz >= 30) {
            char line[200];
            snprintf(line, sizeof line,
                     tr("With On and Adaptive, the frame rate on this display goes up to about %d FPS."),
                     (int)lroundf(hz - hz * hz / 3600));
            desc += std::string("\n\n") + line;
        }
        opt_choice("VSync", &g_settings.vsync, names, VSYNC_COUNT, VSYNC_DEFAULT, desc.c_str(), false);
    }
    {   // HDR (settings.h HDR_*: runtime/nvn/vulkan/device.c hdr_wanted)
        static const char *const names[HDR_COUNT] = {"Automatic", "On", "Off"};
        opt_choice("HDR", &g_settings.hdr, names, HDR_COUNT, HDR_AUTO,
                   "Automatic: while Windows HDR is on for this display, the picture is sent in HDR, so it looks as bright "
                   "and colourful as in SDR (in SDR, Windows shows it dim and dull then). On: always in HDR, where the "
                   "display takes it. Off: always SDR. White follows Windows' SDR content brightness (Settings > System > "
                   "Display > HDR).", false);
    }
    static const char *const perf_names[] = {"Off", "FPS", "Full"};
    opt_choice("Performance overlay", &g_settings.perf_overlay, perf_names, 3, PERF_OFF,
               "FPS: the frame rate and frame time. Full: also CPU, memory and GPU load and temperatures, a "
               "frame time graph and Link's coordinates. F10 switches between them while you play.");

    opt_section("Rendering");
    {   // Upscaler: Off, this OS's spatial upscaler (its modes on the row below), and the temporal ones still to come.
        // Values that can't be picked yet are shown greyed ("coming soon"); stepping onto them keeps the one in use.
        // The modes wait for render-target scaling (upscale_modes_available): until then the upscaler brings the
        // game's own 1920 x 1080 image to a bigger window.
        std::string fsr3 = upscaler_available(UPSCALE_FSR3) ? std::string(tr("AMD FSR 3"))
                                                            : std::string(tr("FSR 3")) + " " + tr("(coming soon)");
        std::string dlss = upscaler_available(UPSCALE_DLSS) ? std::string(tr("NVIDIA DLSS"))
                         : std::string(tr("DLSS")) + " " + tr(renderer_gpu_rtx() ? "(add nvngx_dlss.dll)" : "(NVIDIA RTX only)");
#ifdef __APPLE__
        const char *ups[] = {"Off", "MetalFX"};
        static const int ups_value[] = {UPSCALE_OFF, UPSCALE_METALFX};
        const char *ud = "How the game's image (1920 x 1080) is scaled up to a bigger window. Off: plain (bilinear) "
                         "scaling. MetalFX: Apple's upscaler, sharper.\n\nRendering below the window's size (the modes "
                         "below) is coming in a later version.";
#else
        const char *ups[] = {"Off", "AMD FSR 1", fsr3.c_str(), dlss.c_str()};
        static const int ups_value[] = {UPSCALE_OFF, UPSCALE_FSR1, UPSCALE_FSR3, UPSCALE_DLSS};
        // (the FSR 3 paragraph on its own: the first one keeps its translations)
        static std::string uds;
        char dst[400];
        dlss_status(dst, sizeof dst);
        uds = std::string(tr("Off: the 3D image renders at the window's resolution. AMD FSR 1: it renders smaller (the mode "
                             "below), then FSR 1's edge-aware upscaling and sharpening bring it to the window. The HUD and "
                             "menus always render at the window's resolution.")) + "\n\n" +
              (upscaler_available(UPSCALE_FSR3)
                   ? tr("AMD FSR 3: it renders smaller and builds the full-resolution image from the frames before, "
                        "following the game's motion: sharper and steadier than FSR 1, and anti-aliased (Anti-aliasing "
                        "has no effect with it). Sharpening sets its own sharpening.")
                   : tr("AMD FSR 3 is coming in a later version.")) + "\n\n" +
              tr("NVIDIA DLSS (NVIDIA RTX graphics cards, with your own nvngx_dlss.dll): it renders smaller (the mode "
                 "below) and NVIDIA's AI upscaler builds the full-resolution image from the frames before, following the "
                 "game's motion - anti-aliased too (Anti-aliasing has no effect with it). Sharpening still applies after "
                 "it.") + "\n" + dst;
        const char *ud = uds.c_str();
#endif
        enum { NU = sizeof ups_value / sizeof ups_value[0] };
        bool avail[NU];
        int ui = 0;
        for (int i = 0; i < NU; i++) {
            avail[i] = upscaler_available(ups_value[i]);
            if (ups_value[i] == g_settings.upscaler) ui = i;
        }
        static int shown = -1;
        int udef = 0;  // (the reset value: UPSCALE_DEFAULT)
        for (int i = 0; i < NU; i++) if (ups_value[i] == UPSCALE_DEFAULT) udef = i;
        if (opt_choice_avail("Upscaler", &ui, &shown, ups, avail, NU, udef, ud)) g_settings.upscaler = ups_value[ui];
        // its mode (AMD's scale factors), one step in; greyed when the upscaler is off
        const char *const *modes = k_upscale_modes;
        bool modes_ok = upscale_modes_available();
        std::string mode_names[UPQ_COUNT];
        const char *mn[UPQ_COUNT];
        bool mavail[UPQ_COUNT];
        for (int i = 0; i < UPQ_COUNT; i++) {
            mode_names[i] = modes_ok ? tr(modes[i]) : std::string(tr(modes[i])) + " " + tr("(coming soon)");
            mn[i] = mode_names[i].c_str();
            mavail[i] = modes_ok;
        }
        float sx, sy;  // the 3D scene's size (BOTW docked: 1600 x 900 times its scale)
        renderer_get_scene_scale(&sx, &sy);
        char rendering[100];
        snprintf(rendering, sizeof rendering, tr("Rendering at %.0f x %.0f."), 1600.0 * sx, 900.0 * sy);
        std::string md = std::string(tr("How much smaller the game renders before the upscaler brings it to the window, "
                                        "on each side: Ultra Quality 1.3x, Quality 1.5x, Balanced 1.7x, Performance "
                                        "2x, Ultra Performance 3x. Smaller is faster and softer.")) +
                         "\n\n" + (modes_ok ? rendering : tr("Coming in a later version."));
        opt_indent(1);
        if (g_settings.upscaler == UPSCALE_OFF) opt_disable_next();
        static int mshown = -1;
        opt_choice_avail("Upscaler mode", &g_settings.upscale_quality, &mshown, mn, mavail, UPQ_COUNT, UPQ_QUALITY,
                         md.c_str());
#ifndef __APPLE__
        if (renderer_gpu_rtx()) {  // (WSword) NVIDIA DLSS's model (settings.h DLSS_MODEL_*, vulkan/dlss.c dlss_preset);
                                   // on RTX GPUs only, greyed unless DLSS runs
            static const char *const models[DLSS_MODEL_COUNT] = {"Automatic", "CNN (fastest)", "Transformer", "Transformer 2"};
            static std::string dd;
            char now[400];
            dlss_status(now, sizeof now);
            dd = std::string(tr("Which of NVIDIA's DLSS models runs. Newer ones are sharper and steadier in motion, and cost "
                                "more GPU time each frame - on RTX 20 and 30 cards enough to undo what rendering smaller "
                                "saves.")) + "\n\n" +
                 tr("Automatic: on RTX 40 and newer, NVIDIA's own choice for each mode; on RTX 20 and 30, the "
                    "transformer for every mode.") + "\n" +
                 tr("CNN: the older model, the fastest (about 1 ms at 1440p on an RTX 3060) - a little softer, with "
                    "more ghosting.") + "\n" +
                 tr("Transformer: sharper and steadier (about 2.4 ms there).") + "\n" +
                 tr("Transformer 2: NVIDIA's newest, made for RTX 40 and newer (5-7 ms there).") + "\n\n" +
                 tr(renderer_gpu_rtx40() ? "Automatic on this GPU: NVIDIA's choice." : "Automatic on this GPU: Transformer.") +
                 "\n" + now + "\n" + tr("The performance overlay (F10, full) shows DLSS's time too.");
            if (g_settings.upscaler != UPSCALE_DLSS || !upscaler_available(UPSCALE_DLSS)) opt_disable_next();
            opt_choice("DLSS model", &g_settings.dlss_model, models, DLSS_MODEL_COUNT, DLSS_MODEL_AUTO, dd.c_str());
        }
#endif
        opt_indent(-1);
    }
#ifdef __APPLE__
    static const char *aa[] = {"Off", "SMAA"};
    opt_choice("Anti-aliasing", &g_settings.antialias, aa, 2, AA_OFF,
               "Smooths jagged edges of the game image before it is scaled to the window. SMAA: finds the edges and "
               "blends only along them, so textures stay sharp. Most useful with an upscaler.");
#else
    {   // (the TAA sentence on its own: the first one keeps its translations)
        static const char *aa[] = {"Off", "SMAA", "TAA"};  // (settings.h AA_*)
        static std::string d;
        d = std::string(tr("Smooths jagged edges of the game image before it is scaled to the window. SMAA: finds the "
                           "edges and blends only along them, so textures stay sharp. Most useful with an upscaler.")) +
            " " + tr("TAA: blends each frame with the ones before it, following the game's motion, so edges stay "
                     "smooth and stop shimmering; slightly softer, use it with Sharpening.");
        opt_choice("Anti-aliasing", &g_settings.antialias, aa, 3, AA_OFF, d.c_str());
    }
#endif
#ifndef __APPLE__
    {   // Anisotropic filtering and sharpening (Vulkan: vulkan/textures.c sampler_aniso, vulkan/exec.c scene_post)
        static const char *const aniso[] = {"Off", "2x", "4x", "8x", "16x"};
        opt_choice("Anisotropic filtering", &g_settings.anisotropy, aniso, 5, 0,
                   "Keeps the textures of ground, paths and walls sharp where you look along them into the distance. "
                   "Off: the game's own filtering, as on the console. 16x is the sharpest and costs very little on a PC "
                   "graphics card.", false);
        static const char *const sharp[] = {"Off", "10%", "20%", "30%", "40%", "50%", "60%", "70%", "80%", "90%", "100%"};
        opt_choice("Sharpening (AMD CAS)", &g_settings.sharpening, sharp, 11, 0,
                   "AMD FidelityFX CAS sharpens the 3D image after the upscaler (or at the window's resolution with the "
                   "upscaler off), before the HUD is drawn over it: edges get crisper without halos. Most useful with "
                   "AMD FSR 1.", false);
    }
#endif
    opt_toggle("Asynchronous shaders", &g_settings.async_shaders, false,
               "Off: the game waits for each new shader to compile, a short stutter the first time an effect "
               "appears, and everything is drawn. On: no waiting, but what needs a shader still compiling is skipped "
               "meanwhile: effects pop in late, and pictures the game draws only once (the save file's screenshot) "
               "can come out as garbage.");
    // shadow resolution (its own block)
    static const char *shadow[] = {"Console (896)", "High (2048)", "Ultra (4096)", "Extreme (8192)"};
    opt_choice("Shadow resolution", &g_settings.shadow_res, shadow, SHADOW_COUNT, SHADOW_CONSOLE,
               "The size of the maps the sun's shadows are drawn from. Console: the game's own, 896 x 896. High (2048), "
               "Ultra (4096) and Extreme (8192) give sharper shadow edges (Link, trees, buildings) for more GPU time "
               "and video memory (Ultra: about 100 MB, Extreme: about 400 MB).");
#ifndef __APPLE__
    {   // Frame generation: AMD FSR 3 (vulkan/framegen.cpp), or (WSword) Lossless Scaling's from the player's own
        // Lossless.dll (vulkan/device.c lsfg_prepare). The frame rate counts the presented frames (framepace.c).
        opt_section("Frame generation");
        // (WSword) and NVIDIA DLSS frame generation (vulkan/dlssg.c, Streamline): 2x on RTX 40, 3x and 4x on RTX 50
        static const char *const fgn[] = {"Off", "AMD FSR 3", "Lossless 2x", "Lossless 3x", "Lossless 4x",
                                          "NVIDIA DLSS 2x", "NVIDIA DLSS 3x", "NVIDIA DLSS 4x"};
        int fv = g_settings.dlssg > 0 ? 4 + g_settings.dlssg : g_settings.lsfg > 0 ? 1 + g_settings.lsfg : g_settings.frame_gen ? 1 : 0;
        int fcount = 5 + (dlssg_gpu_ok() ? (dlssg_gpu_mfg() ? 3 : 1) : 0);
        if (fv + 1 > fcount) fcount = fv + 1;  // (a setting this GPU can't run still shows)
        char st[600], dst[600];
        vk_lsfg_status(st, sizeof st);
        dlssg_status(dst, sizeof dst);
        static std::string d;
        d = std::string(tr("AMD FSR 3 makes a frame between each two the game draws: about twice the frames on screen. The "
                           "frame rate above counts them all, so the game itself draws half of it (60 with 120) and the "
                           "controls answer as at that rate, a little later. In play only: the menus and the map show the "
                           "game's own frames. Fast moves can leave faint smears around Link and what moves on its own.")) +
            "\n\n" + tr("Lossless 2x, 3x, 4x: Lossless Scaling's frame generation, from your own copy of Lossless.dll - one, "
                         "two or three frames between each two the game draws. The frame rate above counts them all too: "
                         "at 120, 2x draws 60, 3x 40, 4x 30. Pick the frame rate your monitor shows (120 on a 120 Hz one) "
                         "and the multiplier the game keeps up with. It adds about half a game frame of delay and some GPU "
                         "time; the menus, the map and the FPS counter are never generated. Add Lossless.dll on the start "
                         "screen: Settings > Files > Lossless Scaling.") +
            "\n\n" + tr("NVIDIA DLSS 2x (RTX 40 and newer), 3x and 4x (RTX 50): NVIDIA's frame generation, from your own "
                         "nvngx_dlssg.dll - added on the start screen: Settings > Files > NVIDIA DLSS frame generation. It "
                         "starts with WSword: choose it, then restart. It brings NVIDIA Reflex, and VSync On works as Fast "
                         "with it - use G-SYNC or a frame rate cap. Windows' Hardware-accelerated GPU scheduling must be on.") +
            "\n\n" + st + "\n" + dst;
#ifdef __PROSPERO__
        // (the PS5: 2x is what the TV shows - Performance's 60 as 120 on a 120 Hz output, Quality's 30 as 60 - and
        // Lossless.dll is copied to the title folder, not added on the start screen)
        fcount = fv + 1 > 3 ? fv + 1 : 3;
        d = std::string(tr("A frame made between each two the game draws. Performance: the game's 60 shown as 120 - "
                           "with your TV on 120 Hz (the PS5's Settings > Screen and Video > Video Output > 120 Hz Output: "
                           "Automatic). Quality: its 30 shown as 60. AMD FSR 3: built in. Lossless 2x: Lossless "
                           "Scaling's, from your own Lossless.dll - copy it to /data/homebrew/PPSA99777/lsfg/Lossless.dll "
                           "over FTP. It adds about half a game frame of delay and some GPU time; the menus, the map and "
                           "the FPS counter are never generated.")) +
            "\n\n" + st;
        int mode_before = settings_current_mode();
#endif
        if (opt_choice("Frame generation", &fv, fgn, fcount, 0, d.c_str(), false)) {
            g_settings.frame_gen = fv == 1;
            g_settings.lsfg = fv >= 2 && fv <= 4 ? fv - 1 : 0;
            g_settings.dlssg = fv >= 5 ? fv - 4 : 0;
#ifdef __PROSPERO__
            if (mode_before < MODE_COUNT) settings_apply_mode(mode_before);  // (Quality: 30 or 60 on screen)
#endif
        }
        {   // (settings.h lsfg_flow: 0 Automatic, shown as the lowest step)
            int fl = g_settings.lsfg_flow > 0 ? g_settings.lsfg_flow : 20;
            if (!g_settings.lsfg) opt_disable_next();
            if (opt_int("Flow scale", &fl, 20, 100, 5, 20, "%d%%",
                        "Lossless: the resolution motion is found at, as a share of the game's image - most of frame "
                        "generation's GPU time. Automatic: Lossless Scaling's own advice by the image's height, about 1080 "
                        "lines of motion (100% at 1080 lines, 75% at 1440, 50% at 2160 - 4K). Lower: less GPU time, motion "
                        "found less finely (thin things can wobble); higher than Automatic costs more for little you'd see.",
                        "Automatic"))
                g_settings.lsfg_flow = fl <= 20 ? 0 : fl;
        }
        if (!g_settings.lsfg) opt_disable_next();
        opt_toggle("Performance mode", &g_settings.lsfg_perf, false,
                   "Lossless: Lossless Scaling's lighter passes - much less GPU time, the frames in between slightly less "
                   "accurate. Turn it on if the game's own frame rate drops with Lossless on.");
    }
    {   // (WSword) the player's own ReShade, loaded by WSword (vulkan/reshade.c): from the next start
        opt_section("ReShade");
        char st[600];
        reshade_status(st, sizeof st);
        static std::string d, dd;
        d = std::string(tr("Your own ReShade, loaded by WSword - no installer. Add it on the start screen: Settings > Files > "
                           "ReShade (ReShade64.dll, or ReShade's setup program). Its menu opens with the Home key; its "
                           "shaders, presets and add-ons go in WSword's reshade folder. On or off applies from WSword's next "
                           "start.")) + "\n\n" + st;
        opt_toggle("ReShade", &g_settings.reshade, false, d.c_str());
        static const char *const dn[] = {"The game's (WSword)", "ReShade's own detection"};
        int dv = g_settings.reshade_own_depth ? 1 : 0;
        dd = tr("The depth ReShade's effects see (ambient occlusion, depth of field, fog...). The game's: WSword gives them "
                "the game's own 3D depth, lined up with the picture, ready for ReShade's default depth settings (the "
                "distance in metres / 1000) - leave those as they are. ReShade's own detection: its Generic Depth add-on "
                "looks for it among the game's draws (more CPU time, and it can pick the wrong one). From WSword's next "
                "start.");
        if (!g_settings.reshade) opt_disable_next();
        if (opt_choice("ReShade depth", &dv, dn, 2, 0, dd.c_str(), false)) g_settings.reshade_own_depth = dv == 1;
    }
    tab_colour();
#endif
    opt_end();
}

static void tab_audio(void) {
    opt_begin("##audio", ImGui::GetFontSize() / 34);
    opt_section("Sound");
    float pct = roundf(g_settings.volume * 100);
    if (opt_slider("Volume", &pct, 0, 200, 5, 100, "%g%%",
                   "The game's volume. 100% is the game's own level; above it, louder."))
        g_settings.volume = pct / 100.0f;
    opt_toggle("Room reverb", &g_settings.reverb, true,
               "The game's echo in caves, dungeons and big rooms.");
    opt_toggle("Movie audio", &g_settings.movie_audio, true,
               "Sound in the game's movies (the opening and the ending). Applies the next time a movie starts.");
    opt_end();
}

extern "C" void rt_request_reboot(int kind);  // runtime/main.c (RT_REBOOT_GAME = 1, RT_REBOOT_TITLE = 2)

// Text and voice languages (runtime/language.c). The game reads both when it starts: in game they apply after
// Quit > Start screen and Play.
static void tab_language(bool in_game) {
    opt_begin("##language", ImGui::GetFontSize() / 34);
    opt_section("Language");
    static const char *tnames[32], *vnames[32];
    for (int i = 0; i < g_ntext_languages && i < 32; i++) tnames[i] = g_text_languages[i].name;
    for (int i = 0; i < g_nvoice_languages && i < 32; i++) vnames[i] = g_voice_languages[i].name;
    const char *later = in_game ? tr("\n\nApplies the next time the game starts: Restart now below, or Quit > Start "
                                     "screen, then Play.") : "";
    char d1[600], d2[800];
    snprintf(d1, sizeof d1, tr("The language of the game's texts and of these menus. Auto: your system's language "
                               "(English if the game doesn't have it).%s"), later);
    snprintf(d2, sizeof d2, tr("The language the characters speak. Same as text: the voices the game picks for the text "
                               "language (Japanese for Korean and Chinese, English for the other languages it has no "
                               "voices for). Any other: those voices with any text language.%s"), later);
    int text = language_text_index();  // (of the languages the game files have: Thai from 1.9.0 on)
    if (opt_choice("Text", &text, tnames, language_text_count(), 0, d1, false)) g_settings.text_language = text;
    opt_choice("Voices", &g_settings.voice_language, vnames, g_nvoice_languages, 0, d2, false);
    if (in_game && language_pending() &&
        opt_button("Restart now", "Starts the game again with these languages. Progress since your last save is lost.")) {
        settings_save();
        rt_request_reboot(1);  // (RT_REBOOT_GAME: boot again at once)
    }
    opt_end();
}

// Quit: back to the start screen (in game: the game reboots to it) or out to the desktop. Each asks first (progress
// since the last save is lost); B / Esc or Cancel backs out.
extern "C" void rt_request_reboot(int kind);  // runtime/main.c (RT_REBOOT_TITLE = 2: the start screen)
static void tab_quit(float scale, bool in_game) {
    static int ask;  // 0: the two choices; 1: start screen?; 2: desktop?
    if (ask && (ImGui::IsKeyPressed(ImGuiKey_GamepadFaceRight, false) || ImGui::IsKeyPressed(ImGuiKey_Escape, false)))
        ask = 0;
    const char *lost = in_game ? tr("\n\nProgress since your last save is lost.") : "";
    char d1[400], d2[400];
    snprintf(d1, sizeof d1, tr("Leaves the game and goes back to the WSword start screen.%s"), lost);
    snprintf(d2, sizeof d2, tr("Closes WSword.%s"), lost);
    opt_begin("##quit", scale);
    opt_section("Quit");
    if (!ask) {
        if (!in_game) opt_disable_next();  // (already on it)
        if (opt_action("Quit to Start Screen", "", in_game ? d1 : "You're on the start screen.")) ask = 1;
        if (opt_action("Quit to Desktop", "", d2)) ask = 2;
    } else {
        if (opt_action(ask == 1 ? "Yes, quit to Start Screen" : "Yes, quit to Desktop", "", ask == 1 ? d1 : d2)) {
            settings_save();
            if (ask == 1) {
                rt_request_reboot(2);
                set_open(false);
            } else {
                SDL_Event q = {};
                q.type = SDL_EVENT_QUIT;
                SDL_PushEvent(&q);
            }
            ask = 0;
        }
        if (opt_action("Cancel", "", "Stays where you are.")) ask = 0;
    }
    opt_end();
}

static void tab_about(void) {
    header("Movement");
    toggle("D-pad as left stick", &g_settings.dpad_move);
    hint("The d-pad (and the arrow keys) also move like the left stick while the stick is at rest.");
    ImGui::Spacing();
    header("Mouse");
    opt_toggle("PC mouse pointer", &g_settings.pc_cursor, true,
               "Point and click in menus and map. Esc pauses/goes back; F2 frees the cursor.");
    toggle("Mouse camera", &g_settings.mouse_camera);
    hint("The mouse turns the camera. Pointer off: Esc frees it; pointer on: F2 frees it.");
    float sens = roundf(g_settings.mouse_sens * 100);
    if (opt_slider("Mouse sensitivity", &sens, 10, 1000, 5, MOUSE_SENS_DEFAULT * 100, "%g%%", "How fast the mouse turns the camera."))
        g_settings.mouse_sens = sens / 100.0f;
    float sens_y = roundf(g_settings.mouse_sens_y * 100);
    if (opt_slider("Mouse vertical sensitivity", &sens_y, 50, 200, 5, 100, "%g%%",
                   "Up and down, as a percentage of the mouse sensitivity."))
        g_settings.mouse_sens_y = sens_y / 100.0f;
    toggle("Invert mouse Y", &g_settings.mouse_invert_y);
    ImGui::Spacing();
    header("Controls");
    controls_bindings_draw(ImGui::GetFontSize() / 34);
    ImGui::Spacing();
    header("Menu");
    ImGui::TextUnformatted(tr("Open / close this menu:  F1, Esc, the controller's Home / Xbox / PlayStation button, or Back + Start"));
    ImGui::TextUnformatted(tr("Switch tabs:  L / R  (Q / E)        Back:  B  (Esc)"));
    ImGui::TextUnformatted(tr("Fullscreen:  F11 / Alt+Enter"));
}

// Reboot (runtime/main.c): the game is gone - menu and name dialog close; the ImGui context stays.
RT_ON_RESET(menu_reset) {
    set_open(false);
    g_kbd = 0;
    osk_cancel();
    pthread_mutex_lock(&q_lock);
    q_events.clear();
    pthread_mutex_unlock(&q_lock);
}

// (WSword) A short notice at the top of the screen for a hotkey's change (F6: Ray-Tracing), 2 seconds
static std::atomic<uint64_t> g_notice_until{0};
static char g_notice[128];
static void notice_show_for(const char *text, uint64_t ms) {
    snprintf(g_notice, sizeof g_notice, "%s", text);
    g_notice_until.store(SDL_GetTicks() + ms);
}
static void notice_show(const char *text) { notice_show_for(text, 2000); }
// (0.3.17) Ctrl+F8's capture: its notice while it records, then where it went
extern "C" const char *sampler_status(void);
extern "C" const char *sampler_request(double seconds, unsigned interval_us);
static bool g_capture_watch;
static void capture_start(void) {
    if (g_capture_watch) return;  // (one at a time)
    const char *err = sampler_request(15, 1000);
    if (err) {
        notice_show_for("Performance capture: couldn't start (Windows only)", 4000);
        LOG("[sample] Ctrl+F8: %s\n", err);
        return;
    }
    LOG("[sample] Ctrl+F8: performance capture, 15 s\n");
    g_capture_watch = true;
    notice_show_for("Performance capture: recording for 15 seconds - keep playing", 16000);
}
static bool notice_on(void) {
    if (g_capture_watch) {
        const char *st = sampler_status();
        if (!strcmp(st, "done")) {
            g_capture_watch = false;
            notice_show_for("Performance capture saved: build\\samples.txt - send it with WSword.log", 8000);
        } else if (!strncmp(st, "failed", 6)) {
            g_capture_watch = false;
            notice_show_for("Performance capture failed: WSword.log says why", 6000);
        }
    }
    return SDL_GetTicks() < g_notice_until.load();
}
static void notice_draw(ImGuiIO &io, float scale) {
    ImGui::SetNextWindowPos(ImVec2(io.DisplaySize.x * 0.5f, 24 * scale), 0, ImVec2(0.5f, 0));
    ImGui::SetNextWindowBgAlpha(0.7f);
    ImGui::Begin("##notice", NULL, ImGuiWindowFlags_NoDecoration | ImGuiWindowFlags_AlwaysAutoResize |
                                       ImGuiWindowFlags_NoInputs | ImGuiWindowFlags_NoNav | ImGuiWindowFlags_NoFocusOnAppearing);
    ImGui::TextUnformatted(tr(g_notice));
    ImGui::End();
}

// Performance overlay (F10), in the style of MangoHud: the game's frame rate and frame times, and the machine's load
// and temperatures (runtime/perfmon.c). Numbers the platform doesn't give read "-".
static void perf_cell(const char *fmt, float v) {
    ImGui::TableNextColumn();
    if (v < 0) ImGui::TextDisabled("-");
    else ImGui::Text(fmt, v);
}
static void perf_overlay_draw(ImGuiIO &io, float scale) {
    PerfStats s;
    perfmon_snapshot(&s);
    // top right: BOTW keeps its hearts and stamina top left, its map and gauges bottom right
    ImGui::SetNextWindowPos(ImVec2(io.DisplaySize.x - 16 * scale, 16 * scale), 0, ImVec2(1, 0));
    ImGui::SetNextWindowBgAlpha(0.6f);
    ImGui::Begin("##perf", NULL, ImGuiWindowFlags_NoDecoration | ImGuiWindowFlags_AlwaysAutoResize |
                                     ImGuiWindowFlags_NoInputs | ImGuiWindowFlags_NoNav | ImGuiWindowFlags_NoFocusOnAppearing);
    ImGui::SetWindowFontScale(0.72f);
    const ImVec4 gpu_c(0.55f, 0.83f, 0.31f, 1), cpu_c(0.18f, 0.59f, 0.80f, 1), ram_c(0.80f, 0.45f, 0.70f, 1),
                 fps_c(0.95f, 0.95f, 0.95f, 1);
    if (g_settings.perf_overlay == PERF_FPS) {
        // (frame generation: the presented frames, generated ones included)
        ImGui::TextColored(fps_c, "%.0f FPS  %.1f ms", s.fps + s.fps_generated, s.frame_ms_avg);
        ImGui::End();
        return;
    }
    if (ImGui::BeginTable("##perft", 4, ImGuiTableFlags_SizingFixedFit)) {
        ImGui::TableNextColumn(); ImGui::TextColored(gpu_c, "GPU");
        perf_cell("%.0f%%", s.gpu_pct); perf_cell("%.0f C", s.gpu_temp_c); perf_cell("%.0f W", s.gpu_power_w);
        ImGui::TableNextColumn(); ImGui::TextColored(gpu_c, "VRAM");
        perf_cell("%.2f GB", s.vram_used_mb < 0 ? -1 : s.vram_used_mb / 1024); perf_cell("/ %.1f GB", s.vram_total_mb < 0 ? -1 : s.vram_total_mb / 1024);
        perf_cell("%.0f MHz", s.gpu_clock_mhz);
        ImGui::TableNextColumn(); ImGui::TextColored(cpu_c, "CPU");
        perf_cell("%.0f%%", s.cpu_total_pct); perf_cell("%.0f C", s.cpu_temp_c); perf_cell(tr("game %.0f%%"), s.cpu_game_pct);
        ImGui::TableNextColumn(); ImGui::TextColored(ram_c, "RAM");
        perf_cell("%.1f GB", s.ram_used_mb / 1024); perf_cell("/ %.1f GB", s.ram_total_mb / 1024); perf_cell(tr("game %.1f GB"), s.ram_game_mb / 1024);
        ImGui::TableNextColumn(); ImGui::TextColored(fps_c, "FPS");
        perf_cell("%.0f", s.fps + s.fps_generated);
        perf_cell("%.1f ms", s.frame_ms_avg); perf_cell(tr("max %.1f ms"), s.frame_ms_max);
        ImGui::EndTable();
    }
    float top = s.frame_ms_max > 50 ? s.frame_ms_max : 50;
    ImGui::PlotLines("##ft", s.frame_ms, PERF_HISTORY, 0, NULL, 0, top, ImVec2(330 * scale, 48 * scale));
    ImGui::TextDisabled("%s", s.gpu_name[0] ? s.gpu_name : tr("GPU: no NVML / sysfs data"));
    ImGui::TextDisabled("%s", s.cpu_name);
    // the graphics settings in effect: what the game falls back to (FSR 3 not built in, a mode that isn't offered), not
    // what the menu says
    int up = upscaler_available(g_settings.upscaler) ? g_settings.upscaler : UPSCALE_OFF;
    std::string line = std::string(tr("Upscaler")) + ": ";
    switch (up) {
        case UPSCALE_METALFX: line += tr("MetalFX"); break;
        case UPSCALE_FSR1: line += tr("FSR 1"); break;
        case UPSCALE_FSR3: line += tr("FSR 3"); break;
        case UPSCALE_DLSS: line += tr("DLSS"); break;
        default: line += tr("Off");
    }
    int q = g_settings.upscale_quality;
    if (up != UPSCALE_OFF && upscale_factor() > 1.0) {
        char f[16];
        snprintf(f, sizeof f, "%.1f", upscale_factor());
        line += std::string(" ") + (q >= 0 && q < UPQ_COUNT ? std::string(tr(k_upscale_modes[q])) + " " : "") + f + "x";
    }
    // (FSR 3 anti-aliases the scene itself: the setting does nothing then)
    int aa = rt_antialias();
    line += std::string(" | ") + tr("Anti-aliasing") + ": " + (rt_fsr3() ? tr("FSR 3") : rt_dlss() ? tr("DLSS") : aa == AA_TAA ? tr("TAA") : aa == AA_SMAA ? tr("SMAA") : tr("Off"));
    ImGui::TextDisabled("%s", line.c_str());
    line.clear();
#ifndef __APPLE__
    if (rt_dlss() && dlss_model_in_use()[0]) {  // (WSword) DLSS's model and its own GPU time a frame
        char dl[160];
        float ms = dlss_gpu_ms();
        if (ms > 0) snprintf(dl, sizeof dl, tr("DLSS: %s, %.2f ms GPU"), dlss_model_in_use(), ms);
        else snprintf(dl, sizeof dl, tr("DLSS: %s"), dlss_model_in_use());
        ImGui::TextDisabled("%s", dl);
    }
#endif
#ifndef __APPLE__
    {   // the scene's size and the final image's (the HUD and menus render at that one)
        float rx, ry, ox, oy;
        renderer_get_scene_scale(&rx, &ry);
        renderer_get_scale(&ox, &oy);
        if (rx > 0 && ox > 0) {
            char r[48];
            snprintf(r, sizeof r, "%.0f x %.0f -> %.0f x %.0f", 1600.0 * rx, 900.0 * ry, 1920.0 * ox, 1080.0 * oy);
            line = r;
        }
    }
#endif
    if (g_fg_active) line += std::string(line.empty() ? "" : " | ") + tr("Frame generation on");
    if (!line.empty()) ImGui::TextDisabled("%s", line.c_str());
    // Link's coordinates; no line at all while there is no Link or the game is in a scene (title, loading, movie, event).
    // Axis letters are not translated.
    float pos[3];
    if (perfmon_position(pos)) ImGui::Text("X %.1f  Y %.1f  Z %.1f", pos[0], pos[1], pos[2]);
    ImGui::End();
}

static void keyboard_draw(ImGuiIO &io, float scale) {
    ImGui::GetBackgroundDrawList()->AddRectFilled(ImVec2(0, 0), io.DisplaySize, IM_COL32(0, 0, 0, 120));
    float w = fminf(io.DisplaySize.x * 0.9f, 1100 * scale);
    ImGui::SetNextWindowPos(ImVec2(io.DisplaySize.x * 0.5f, io.DisplaySize.y * 0.5f), ImGuiCond_Always, ImVec2(0.5f, 0.5f));
    ImGui::SetNextWindowSize(ImVec2(w, 0), ImGuiCond_Always);
    ImGui::Begin("##kbd", NULL, ImGuiWindowFlags_NoDecoration | ImGuiWindowFlags_NoMove | ImGuiWindowFlags_NoSavedSettings |
                                    ImGuiWindowFlags_AlwaysAutoResize);
    ImGui::PushFont(g_font_big);
    ImGui::TextColored(ImVec4(0.93f, 0.76f, 0.33f, 1), "%s", tr("Enter your name"));
    ImGui::PopFont();
    static bool was_open, was_pad;
    bool pad = g_last_pad.load(), appearing = !was_open || pad != was_pad;  // (switching device: focus the new one)
    was_open = true, was_pad = pad;
    if (!pad) {  // keyboard: type straight into the field
        if (appearing) ImGui::SetKeyboardFocusHere();
        ImGui::SetNextItemWidth(-1);
        ImGui::PushFont(g_font_big);
        ImGui::InputText("##name", g_kbd_text, (size_t)(g_kbd_max * 4 + 1 < (int)sizeof g_kbd_text ? g_kbd_max * 4 + 1 : sizeof g_kbd_text),
                         ImGuiInputTextFlags_CallbackCharFilter,
                         [](ImGuiInputTextCallbackData *d) -> int { return d->EventChar < 0x20 ? 1 : 0; });
        ImGui::PopFont();
        if ((int)strlen(g_kbd_text) > g_kbd_max) g_kbd_text[g_kbd_max] = 0;
        ImGui::TextDisabled(tr("Enter  confirm      Esc  cancel      (%d / %d)"), (int)strlen(g_kbd_text), g_kbd_max);
    } else {  // controller: on-screen keyboard (osk.mm, shared with our menus' text fields)
        int r = osk_keys(g_kbd_text, sizeof g_kbd_text, g_kbd_max, appearing, scale, g_font_big);
        if (r) g_kbd = r > 0 ? 2 : 3;  // (Start / + confirms in menu_handle_event too)
    }
    ImGui::End();
    if (g_kbd.load() != 1) was_open = false;
}

// Window size's list, dropped down under the row's button on the game's Options screen (Video), drawn like the game's
// own pop-up lists: the menu is 16:9 in the middle of the window (output_scale.c), the button where its layout has it
static void size_list_draw(ImGuiIO &io, float scale) {
    static bool was_open;
    static int frames;
    bool appearing = !was_open;
    was_open = true;
    frames = appearing ? 0 : frames + 1;
    float gw = io.DisplaySize.x, gh = gw * 9 / 16;
    if (gh > io.DisplaySize.y) gh = io.DisplaySize.y, gw = gh * 16 / 9;
    float ox = (io.DisplaySize.x - gw) * 0.5f, oy = (io.DisplaySize.y - gh) * 0.5f;
    float x0 = ox + gw * 0.496f, x1 = ox + gw * 0.708f, y0 = oy + gh * 0.318f, bottom = oy + gh * 0.87f;
    float row_h = gh * 0.046f;
    WinSize list[WINSIZE_MAX];
    static char names[WINSIZE_MAX][64];
    int n = winsize_list(list, g_settings.fullscreen), cur = 0;
    WinSize e = winsize_effective(g_settings.fullscreen);
    for (int i = 0; i < n; i++) {
        winsize_name(list[i], tr("native"), names[i], sizeof names[i]);
        if (list[i].w == e.w && list[i].h == e.h) cur = i;
    }
    ImGui::SetNextWindowPos(ImVec2(x0, y0), ImGuiCond_Always);
    ImGui::SetNextWindowSizeConstraints(ImVec2(x1 - x0, 0), ImVec2(x1 - x0, bottom - y0));
    if (appearing) ImGui::SetNextWindowFocus();
    ImGui::PushStyleVar(ImGuiStyleVar_WindowRounding, 0);
    ImGui::PushStyleVar(ImGuiStyleVar_WindowBorderSize, 1.5f * scale);
    ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(4 * scale, 4 * scale));
    ImGui::PushStyleVar(ImGuiStyleVar_ItemSpacing, ImVec2(0, 2 * scale));
    ImGui::PushStyleColor(ImGuiCol_WindowBg, ImVec4(0.04f, 0.04f, 0.04f, 0.94f));
    ImGui::PushStyleColor(ImGuiCol_Border, ImVec4(0.62f, 0.62f, 0.58f, 0.9f));
    ImGui::PushStyleColor(ImGuiCol_Header, ImVec4(1, 1, 1, 0.10f));
    ImGui::PushStyleColor(ImGuiCol_HeaderHovered, ImVec4(1, 1, 1, 0.22f));
    ImGui::PushStyleColor(ImGuiCol_HeaderActive, ImVec4(1, 1, 1, 0.30f));
    ImGui::PushStyleColor(ImGuiCol_NavCursor, ImVec4(0.95f, 0.93f, 0.85f, 1));
    ImGui::Begin("##sizes", NULL, ImGuiWindowFlags_NoDecoration | ImGuiWindowFlags_NoMove | ImGuiWindowFlags_NoSavedSettings |
                                      ImGuiWindowFlags_AlwaysAutoResize);
    ImGui::PushFont(g_menu_font);
    int picked = -1;
    for (int i = 0; i < n; i++) {
        ImGui::PushID(i);
        ImVec2 p = ImGui::GetCursorScreenPos();
        float w = ImGui::GetContentRegionAvail().x;
        if (ImGui::Selectable("##size", i == cur, 0, ImVec2(w, row_h))) picked = i;
        if (appearing && i == cur) {
            ImGui::SetItemDefaultFocus();
            ImGui::SetScrollHereY(0.5f);
            ImGui::SetNavCursorVisible(g_last_pad.load());
        }
        bool hot = ImGui::IsItemHovered() || ImGui::IsItemFocused();
        ImVec2 ts = ImGui::CalcTextSize(names[i]);
        ImU32 col = i == cur ? IM_COL32(236, 194, 84, 255) : hot ? IM_COL32(255, 255, 255, 255) : IM_COL32(215, 213, 205, 255);
        ImGui::GetWindowDrawList()->AddText(ImVec2(p.x + (w - ts.x) * 0.5f, p.y + (row_h - ts.y) * 0.5f), col, names[i]);
        ImGui::PopID();
    }
    // (test) SAVAGEWIND_SIZE_PICK=<n>: picks size n three seconds after the list is up
    if (const char *t = getenv("SAVAGEWIND_SIZE_PICK"); t && frames == 180) picked = atoi(t) < n ? atoi(t) : cur;
    bool cancel = !appearing && (ImGui::IsKeyPressed(ImGuiKey_GamepadFaceRight, false) ||
                                 ImGui::IsKeyPressed(ImGuiKey_Escape, false) ||
                                 (ImGui::IsMouseClicked(0) && !ImGui::IsWindowHovered()));
    ImGui::PopFont();
    ImGui::End();
    ImGui::PopStyleColor(6);
    ImGui::PopStyleVar(4);
    if (picked >= 0 && picked != cur) {
        g_settings.window_w = list[picked].w, g_settings.window_h = list[picked].h;
        settings_save();
        g_want_window_apply.store(true);
        game_options_size_picked();
    }
    if (picked >= 0 || cancel) {
        g_sizes_hold = SDL_GetTicks() + 300;  // (the A / B that closed it, still down, stays out of the game)
        g_sizes = false;
        was_open = false;
    }
}

// Game thread (runtime/hle/swkbd.c): show the dialog, re-present the last frame until it's answered.
// Returns 1 confirmed (out = text, UTF-8), 0 cancelled.
extern "C" int menu_keyboard_run(const char *initial, int max_len, char *out, int cap) {
    extern void backend_represent(void);
    snprintf(g_kbd_text, sizeof g_kbd_text, "%s", initial ? initial : "");
    g_kbd_max = max_len > 0 && max_len < (int)sizeof g_kbd_text / 4 ? max_len : 8;
    input_reset();
    g_kbd = 1;
    // (test) SAVAGEWIND_KBD_AUTO=<text>: answer at once
    if (getenv("SAVAGEWIND_KBD_AUTO")) { snprintf(g_kbd_text, sizeof g_kbd_text, "%s", getenv("SAVAGEWIND_KBD_AUTO")); g_kbd = 2; }
    while (g_kbd.load() == 1 && !g_rt_unwind) {  // ~60 Hz (a reboot cancels)
        uint64_t t0 = SDL_GetTicks();
        backend_represent();
        uint64_t dt = SDL_GetTicks() - t0;
        if (dt < 16) SDL_Delay((uint32_t)(16 - dt));
    }
    bool ok = g_kbd.load() == 2 && g_kbd_text[0];
    if (ok) snprintf(out, cap, "%s", g_kbd_text);
    g_kbd = 0;
    input_reset();
    return ok;
}

// The settings' pages, into the current window: the in-game menu, and the start screen's Settings (in_game false:
// nothing of the game is loaded yet - the pages that need it are greyed out; prelaunch: the start screen's own first
// page, Files - the game files, the look, Lossless.dll, fonts - drawn by launcher.mm).
//
// (WSword) The pages' icons, drawn (r: half their size): files (a folder), video (a screen), audio (a speaker),
// language (a globe), saves (a disk), controls (two Joy-Con), quit (a door)
static void settings_icon(ImDrawList *dl, int id, ImVec2 c, float r, ImU32 col, float scale) {
    float t = fmaxf(1.5f, 2.2f * scale);
    switch (id) {
    case -1:
        dl->AddRect(ImVec2(c.x - r, c.y - r * 0.55f), ImVec2(c.x + r, c.y + r * 0.75f), col, r * 0.12f, 0, t);
        dl->AddLine(ImVec2(c.x - r, c.y - r * 0.55f), ImVec2(c.x - r * 0.75f, c.y - r * 0.85f), col, t);
        dl->AddLine(ImVec2(c.x - r * 0.75f, c.y - r * 0.85f), ImVec2(c.x - r * 0.1f, c.y - r * 0.85f), col, t);
        dl->AddLine(ImVec2(c.x - r * 0.1f, c.y - r * 0.85f), ImVec2(c.x + r * 0.1f, c.y - r * 0.55f), col, t);
        break;
    case 0:
        dl->AddRect(ImVec2(c.x - r, c.y - r * 0.75f), ImVec2(c.x + r, c.y + r * 0.45f), col, r * 0.1f, 0, t);
        dl->AddLine(ImVec2(c.x, c.y + r * 0.45f), ImVec2(c.x, c.y + r * 0.75f), col, t);
        dl->AddLine(ImVec2(c.x - r * 0.45f, c.y + r * 0.8f), ImVec2(c.x + r * 0.45f, c.y + r * 0.8f), col, t);
        break;
    case 1: {
        const ImVec2 sp[] = {{c.x - r, c.y - r * 0.3f}, {c.x - r * 0.55f, c.y - r * 0.3f}, {c.x - r * 0.05f, c.y - r * 0.75f},
                             {c.x - r * 0.05f, c.y + r * 0.75f}, {c.x - r * 0.55f, c.y + r * 0.3f}, {c.x - r, c.y + r * 0.3f}};
        dl->AddConvexPolyFilled(sp, 6, col);
        dl->PathArcTo(ImVec2(c.x - r * 0.05f, c.y), r * 0.5f, -0.9f, 0.9f, 10);
        dl->PathStroke(col, 0, t);
        dl->PathArcTo(ImVec2(c.x - r * 0.05f, c.y), r * 0.9f, -0.9f, 0.9f, 12);
        dl->PathStroke(col, 0, t);
        break;
    }
    case 2:  // (a globe: its outline, a meridian, the equator)
        dl->AddCircle(c, r * 0.9f, col, 24, t);
        dl->AddEllipse(c, ImVec2(r * 0.4f, r * 0.9f), col, 0, 20, t);
        dl->AddLine(ImVec2(c.x - r * 0.9f, c.y), ImVec2(c.x + r * 0.9f, c.y), col, t);
        break;
    case 3:  // (a disk: its body, the label, the shutter)
        dl->AddRect(ImVec2(c.x - r * 0.8f, c.y - r * 0.8f), ImVec2(c.x + r * 0.8f, c.y + r * 0.8f), col, r * 0.15f, 0, t);
        dl->AddRect(ImVec2(c.x - r * 0.45f, c.y - r * 0.8f), ImVec2(c.x + r * 0.35f, c.y - r * 0.2f), col, 0, 0, t);
        dl->AddRect(ImVec2(c.x - r * 0.45f, c.y + r * 0.15f), ImVec2(c.x + r * 0.45f, c.y + r * 0.8f), col, 0, 0, t);
        break;
    case 8:
        for (int side = -1; side <= 1; side += 2) {
            float x0 = side < 0 ? c.x - r : c.x + r * 0.12f, x1 = side < 0 ? c.x - r * 0.12f : c.x + r;
            dl->AddRect(ImVec2(x0, c.y - r * 0.8f), ImVec2(x1, c.y + r * 0.8f), col, r * 0.4f, 0, t);
            dl->AddCircleFilled(ImVec2((x0 + x1) * 0.5f, c.y + side * r * 0.3f), r * 0.17f, col, 10);
        }
        break;
    case 4:  // (WSword, Mods: two stacked boxes, the top one offset)
        dl->AddRect(ImVec2(c.x - r * 0.9f, c.y - r * 0.1f), ImVec2(c.x + r * 0.5f, c.y + r * 0.85f), col, r * 0.12f, 0, t);
        dl->AddRect(ImVec2(c.x - r * 0.5f, c.y - r * 0.85f), ImVec2(c.x + r * 0.9f, c.y + r * 0.1f), col, r * 0.12f, 0, t);
        break;
    case 9:
        dl->AddRect(ImVec2(c.x - r * 0.9f, c.y - r), ImVec2(c.x + r * 0.2f, c.y + r), col, 0, 0, t);
        dl->AddLine(ImVec2(c.x - r * 0.2f, c.y), ImVec2(c.x + r, c.y), col, t);
        dl->AddLine(ImVec2(c.x + r, c.y), ImVec2(c.x + r * 0.6f, c.y - r * 0.4f), col, t);
        dl->AddLine(ImVec2(c.x + r, c.y), ImVec2(c.x + r * 0.6f, c.y + r * 0.4f), col, t);
        break;
    }
}

// (WSword) a glass button: navy, outlined in cyan while focused, hovered or pressed, an icon on the left (0: back, a
// chevron) and the label
static bool glass_button(const char *label, ImVec2 size, float scale) {
    ImGui::PushID(label);
    ImVec2 a = ImGui::GetCursorScreenPos();
    ImGui::PushStyleColor(ImGuiCol_NavCursor, ImVec4(0, 0, 0, 0));
    bool clicked = ImGui::InvisibleButton("##b", size, ImGuiButtonFlags_EnableNav);
    ImGui::PopStyleColor();
    bool hot = ImGui::IsItemActive() || (ImGui::IsItemFocused() && ImGui::GetCurrentContext()->NavCursorVisible) ||
               ImGui::IsItemHovered();
    ImDrawList *dl = ImGui::GetWindowDrawList();
    ImVec2 b(a.x + size.x, a.y + size.y);
    float rr = 14 * scale;
    dl->AddRectFilled(a, b, ImGui::IsItemActive() ? IM_COL32(26, 52, 82, 255) : hot ? IM_COL32(20, 40, 66, 255) : IM_COL32(15, 30, 51, 255), rr);
    dl->AddRect(a, b, hot ? IM_COL32(94, 230, 245, 255) : IM_COL32(35, 65, 95, 255), rr, 0, (hot ? 2.2f : 1.3f) * scale);
    float fs = ImGui::GetFontSize(), cy = a.y + size.y * 0.5f, ix = a.x + 30 * scale, r = fs * 0.36f, t = 2.4f * scale;
    ImU32 col = IM_COL32(234, 242, 250, 255), icol = IM_COL32(94, 230, 245, 255);
    dl->AddLine(ImVec2(ix + r * 0.4f, cy - r), ImVec2(ix - r * 0.4f, cy), icol, t);
    dl->AddLine(ImVec2(ix - r * 0.4f, cy), ImVec2(ix + r * 0.4f, cy + r), icol, t);
    const char *shown = tr(label);
    float tx = ix + r + 22 * scale, tw = ImGui::CalcTextSize(shown).x;
    tx = fmaxf(tx, a.x + (size.x - tw) * 0.5f + r);
    dl->AddText(ImVec2(tx, cy - fs * 0.5f), col, shown);
    ImGui::PopID();
    return clicked;
}

static bool g_settings_back;  // (the start screen's Settings: BACK on the rail - launcher.mm closes the page)
bool menu_settings_back_requested() { bool back = g_settings_back; g_settings_back = false; return back; }

// (WSword 0.3.15, Glass Slate 2) In the game, beside the page's title: quick toggles - Ray-Tracing (F6), frame
// generation (off / the last one on), ReShade (from the next start), the performance overlay (F10's three steps) -
// pills, lit when on, right-aligned in [a, b]; the ones that don't fit are left out (Settings' pages have them all)
static void quick_toggles(ImDrawList *dl, ImVec2 a, ImVec2 b, float scale) {
    struct Q { const char *id; std::string text; bool on, enabled; int what; };
    std::vector<Q> q;
#ifndef __APPLE__
    q.push_back({"##qrt", tr("Ray-Tracing"), g_settings.rt_shadows && rts_available(), rts_available(), 0});
    int fv = g_settings.dlssg > 0 ? 4 + g_settings.dlssg : g_settings.lsfg > 0 ? 1 + g_settings.lsfg : g_settings.frame_gen ? 1 : 0;
    static int fg_last = 1;  // (the frame generation turned back on: the last one on this session, else AMD FSR 3)
    if (fv) fg_last = fv;
    static const char *const fgs[] = {"Frame gen", "FSR 3", "Lossless 2x", "Lossless 3x", "Lossless 4x", "DLSS 2x", "DLSS 3x", "DLSS 4x"};
    q.push_back({"##qfg", fv ? std::string(tr(fgs[fv < 8 ? fv : 0])) + (fv >= 5 ? std::string(" \xc2\xb7 ") + tr("restart") : "")
                             : std::string(tr("Frame gen")),
                 fv != 0, true, 1});
    static int rs_start = -1;  // (ReShade loads at WSword's start: a change shows "next start")
    if (rs_start < 0) rs_start = g_settings.reshade;
    q.push_back({"##qrs", std::string("ReShade") + ((int)g_settings.reshade != rs_start ? std::string(" \xc2\xb7 ") + tr("next start") : ""),
                 g_settings.reshade, true, 2});
#endif
    static const char *const po[] = {"FPS counter", "FPS counter", "Full overlay"};
    q.push_back({"##qpo", tr(po[g_settings.perf_overlay % 3]), g_settings.perf_overlay != 0, true, 3});
    float fs = ImGui::GetFontSize() * 0.66f, h = fminf(44 * scale, (b.y - a.y) * 0.8f), gap = 8 * scale, cy = (a.y + b.y) * 0.5f;
    float x = b.x;
    for (int i = (int)q.size() - 1; i >= 0; i--) {
        float w = ImGui::CalcTextSize(q[i].text.c_str()).x * 0.66f + 30 * scale;
        if (x - w < a.x) break;
        x -= w;
        ImGui::SetCursorScreenPos(ImVec2(x, cy - h * 0.5f));
        ImGui::BeginDisabled(!q[i].enabled);
        ImGui::PushStyleColor(ImGuiCol_NavCursor, ImVec4(0, 0, 0, 0));
        bool clicked = ImGui::InvisibleButton(q[i].id, ImVec2(w, h), ImGuiButtonFlags_EnableNav);
        ImGui::PopStyleColor();
        bool hot = q[i].enabled && ((ImGui::IsItemFocused() && ImGui::GetCurrentContext()->NavCursorVisible) || ImGui::IsItemHovered());
        ImGui::EndDisabled();
        ImVec2 p0(x, cy - h * 0.5f), p1(x + w, cy + h * 0.5f);
        dl->AddRectFilled(p0, p1, q[i].on ? IM_COL32(94, 230, 245, 255) : IM_COL32(20, 40, 66, 255), h * 0.5f);
        if (!q[i].on) dl->AddRect(p0, p1, IM_COL32(94, 230, 245, q[i].enabled ? 90 : 35), h * 0.5f, 0, 1.2f * scale);
        if (hot) dl->AddRect(ImVec2(p0.x - 3 * scale, p0.y - 3 * scale), ImVec2(p1.x + 3 * scale, p1.y + 3 * scale),
                             IM_COL32(234, 242, 250, 255), h * 0.5f + 3 * scale, 0, 1.6f * scale);
        ImU32 fg = !q[i].enabled ? IM_COL32(110, 125, 140, 255) : q[i].on ? IM_COL32(6, 36, 48, 255) : IM_COL32(207, 227, 241, 255);
        dl->AddText(ImGui::GetFont(), fs, ImVec2(x + 15 * scale, cy - fs * 0.6f), fg, q[i].text.c_str());
        if (clicked && q[i].enabled) {
            switch (q[i].what) {
#ifndef __APPLE__
            case 0:
                g_settings.rt_shadows = !g_settings.rt_shadows;
                break;
            case 1: {
                int nv = fv ? 0 : fg_last;
                g_settings.frame_gen = nv == 1;
                g_settings.lsfg = nv >= 2 && nv <= 4 ? nv - 1 : 0;
                g_settings.dlssg = nv >= 5 ? nv - 4 : 0;
                break;
            }
            case 2:
                g_settings.reshade = !g_settings.reshade;
                break;
#endif
            case 3:
                g_settings.perf_overlay = (g_settings.perf_overlay + 1) % 3;
                break;
            }
            settings_save();
        }
        x -= gap;
    }
}

static void tabs_body(float scale, bool in_game, void (*prelaunch)(float)) {
    // (id: the page; -1 = Files, the start screen's first)
    struct Tab { const char *name; int id; bool on; };
    Tab tabs[11];
    int ntabs = 0;
    if (prelaunch) tabs[ntabs++] = {"Files", -1, true};
    // (ids 4-7 were Link's Awakening tabs; the ids stay: test hooks)
    static const char *names[] = {"Video", "Audio", "Language", "Saves", "Mods", "", "", "", "Controls", "Quit"};
    static const int order[] = {0, 1, 8, 2, 4, 3, 9};  // Video, Audio, Controls, Language, Mods (WSword), Saves, Quit
    for (int i : order) {  // (Quit: in game only - the start screen has its own QUIT; Saves: on the start screen only,
        if (i == 9 && prelaunch) continue;  //  the game must not be running while its saves change)
        if (i == 3 && !prelaunch) continue;
        tabs[ntabs++] = {names[i], i, true};
    }
    // WSword's Glass Slate look (0.2.8's, the UI concepts' D, as the start screen): a rail down the left - the app's name
    // and "Settings", the pages as tiles (an icon and the name; the open one filled and outlined in cyan), BACK at its
    // foot - and the open page beside it under its own title. The page ids stay (test hooks, the controller's L / R);
    // Up / Down go along the rail, Right into the page.
    if (g_tab_request_ext >= 0) { g_tab_request = g_tab_request_ext; g_tab_request_ext = -1; }  // (-1: none)
    for (int i = 0; i < ntabs; i++) if (tabs[i].id == g_tab_request && tabs[i].on) g_tab = tabs[i].id;
    bool available = false;
    for (int i = 0; i < ntabs; i++) available |= tabs[i].id == g_tab && tabs[i].on;
    if (!available) g_tab = tabs[0].id;
    bool popup = ImGui::IsPopupOpen("", ImGuiPopupFlags_AnyPopupId);
    if (!popup && !ui_text_busy()) {  // L / R (or Q / E) go through the pages (not while typing: Q / E are letters then)
        int step = ImGui::IsKeyPressed(ImGuiKey_GamepadR1, false) || ImGui::IsKeyPressed(ImGuiKey_E, false) ? 1
                 : ImGui::IsKeyPressed(ImGuiKey_GamepadL1, false) || ImGui::IsKeyPressed(ImGuiKey_Q, false) ? -1 : 0;
        if (step) {
            int index = 0;
            for (int i = 0; i < ntabs; i++) if (tabs[i].id == g_tab) index = i;
            do index = (index + step + ntabs) % ntabs; while (!tabs[index].on);
            g_tab = tabs[index].id;
        }
    }
    const ImU32 ink = IM_COL32(234, 242, 250, 255), cyan = IM_COL32(94, 230, 245, 255), line = IM_COL32(46, 110, 134, 255),
                rule = IM_COL32(28, 53, 80, 255), sel_fill = IM_COL32(18, 51, 73, 255), label = IM_COL32(143, 217, 230, 255);
    ImDrawList *wdl = ImGui::GetWindowDrawList();
    ImVec2 wp = ImGui::GetWindowPos(), ws = ImGui::GetWindowSize();
    wdl->AddRect(ImVec2(wp.x + 1, wp.y + 1), ImVec2(wp.x + ws.x - 1, wp.y + ws.y - 1), line, 22 * scale, 0, 1.5f * scale);
    float rail_w = 290 * scale, gap = 28 * scale;
    ImVec2 avail = ImGui::GetContentRegionAvail(), c0 = ImGui::GetCursorScreenPos();
    wdl->AddLine(ImVec2(c0.x + rail_w + gap * 0.5f, c0.y), ImVec2(c0.x + rail_w + gap * 0.5f, c0.y + avail.y), rule, 1.2f * scale);
    const char *open_name = "Settings";
    ImGui::PushStyleVar(ImGuiStyleVar_ItemSpacing, ImVec2(0, 8 * scale));
    ImGui::PushStyleColor(ImGuiCol_ChildBg, ImVec4(0, 0, 0, 0));
    ImGui::BeginChild("##rail", ImVec2(rail_w, avail.y), ImGuiChildFlags_None,
                      ImGuiWindowFlags_NavFlattened | ImGuiWindowFlags_NoScrollbar | ImGuiWindowFlags_NoScrollWithMouse);
    ImGui::PopStyleColor();
    {
        ImDrawList *dl = ImGui::GetWindowDrawList();
        ImVec2 p = ImGui::GetCursorScreenPos();
        // (the titles a little under the big font's own size on screen: drawn from its atlas, not enlarged - crisp)
        float fs = ImGui::GetFontSize(), ts = g_font_big->FontSize * ImGui::GetIO().FontGlobalScale * 0.8f;
        dl->AddText(ImGui::GetFont(), fs * 0.82f, ImVec2(p.x + 4 * scale, p.y), label, "WSword");
        dl->AddText(g_font_big, ts, ImVec2(p.x + 2 * scale, p.y + fs * 0.95f), ink, tr("Settings"));
        ImGui::Dummy(ImVec2(rail_w, fs * 0.95f + ts * 1.2f + 18 * scale));
        float th = 72 * scale;
        for (int i = 0; i < ntabs; i++) {
            const Tab &t = tabs[i];
            if (g_tab == t.id) open_name = t.name;
            ImGui::PushID(t.id);
            ImVec2 a = ImGui::GetCursorScreenPos();
            if (g_focus_tab == t.id || ((g_focus_tab == -100 || g_focus_tab == -1) && t.id == g_tab)) {  // (on the open page)
                ImGui::SetKeyboardFocusHere();
                ImGui::SetNavCursorVisible(true);
                // a few frames: the page's child window appearing makes ImGui pick its first widget once it's laid out
                if (++g_focus_frames >= 4) g_focus_tab = -99, g_focus_frames = 0;
            }
            ImGui::BeginDisabled(!t.on);
            ImGui::PushStyleColor(ImGuiCol_NavCursor, ImVec4(0, 0, 0, 0));
            if (ImGui::InvisibleButton("##tab", ImVec2(rail_w, th), ImGuiButtonFlags_EnableNav)) g_tab = t.id;
            ImGui::PopStyleColor();
            bool hot = (ImGui::IsItemFocused() && ImGui::GetCurrentContext()->NavCursorVisible) || ImGui::IsItemHovered();
            ImGui::EndDisabled();
            bool open = g_tab == t.id;
            ImVec2 b(a.x + rail_w, a.y + th);
            if (open) {
                dl->AddRectFilled(a, b, sel_fill, 14 * scale);
                dl->AddRect(a, b, cyan, 14 * scale, 0, 2.2f * scale);
            } else if (hot) {
                dl->AddRectFilled(a, b, IM_COL32(20, 40, 66, 255), 14 * scale);
                dl->AddRect(a, b, IM_COL32(94, 230, 245, 170), 14 * scale, 0, 1.6f * scale);
            }
            if (open && hot) dl->AddRect(ImVec2(a.x - 3 * scale, a.y - 3 * scale), ImVec2(b.x + 3 * scale, b.y + 3 * scale), ink,
                                         17 * scale, 0, 1.6f * scale);
            ImU32 col = !t.on ? IM_COL32(110, 125, 140, 255) : open ? ink : IM_COL32(207, 227, 241, 255);
            ImU32 icol = !t.on ? col : open ? cyan : IM_COL32(159, 216, 230, 255);
            float isz = 16 * scale, cy = a.y + th * 0.5f;
            settings_icon(dl, t.id, ImVec2(a.x + 24 * scale + isz, cy), isz, icol, scale);
            dl->AddText(ImVec2(a.x + 24 * scale + isz * 2 + 20 * scale, cy - fs * 0.5f), col, tr(t.name));
            {   // (0.3.15, Glass Slate 2) a badge at the tile's right: what's on there
                char badge[32] = "";
                bool lit = false;
#ifndef __APPLE__
                if (t.id == 0 && g_settings.rt_shadows && rts_available()) snprintf(badge, sizeof badge, "RT"), lit = true;
#endif
                if (t.id == 4) {
                    static int on = -1, all = 0;
                    static double at = -10;
                    if (ImGui::GetTime() - at > 1) {
                        at = ImGui::GetTime();
                        ModInfo mi[MODS_MAX];
                        all = mods_list(mi, MODS_MAX), on = 0;
                        for (int k = 0; k < all; k++) on += mi[k].on;
                    }
                    if (all > 0) snprintf(badge, sizeof badge, "%d/%d", on, all);
                }
                if (badge[0]) {
                    float bfs = fs * 0.62f, bw = ImGui::CalcTextSize(badge).x * 0.62f + 16 * scale, bh = bfs * 1.6f;
                    ImVec2 b0(b.x - 16 * scale - bw, cy - bh * 0.5f), b1(b.x - 16 * scale, cy + bh * 0.5f);
                    dl->AddRectFilled(b0, b1, lit ? cyan : IM_COL32(30, 50, 67, 255), bh * 0.5f);
                    dl->AddText(ImGui::GetFont(), bfs, ImVec2(b0.x + 8 * scale, cy - bfs * 0.6f),
                                lit ? IM_COL32(6, 36, 48, 255) : IM_COL32(201, 214, 226, 255), badge);
                }
            }
            ImGui::PopID();
        }
        float bh = 62 * scale, y_back = ImGui::GetWindowHeight() - bh - 2 * scale;  // (BACK at the rail's foot)
        if (ImGui::GetCursorPosY() < y_back) ImGui::SetCursorPosY(y_back);
        if (glass_button("Back", ImVec2(rail_w, bh), scale)) {
            if (prelaunch) g_settings_back = true;
            else set_open(false);
        }
    }
    ImGui::EndChild();
    ImGui::PopStyleVar();
    ImGui::SameLine(0, gap);
    ImGui::PushStyleColor(ImGuiCol_ChildBg, ImVec4(0, 0, 0, 0));
    ImGui::BeginChild("##content", ImVec2(0, avail.y), ImGuiChildFlags_None,
                      ImGuiWindowFlags_NavFlattened | ImGuiWindowFlags_NoScrollbar | ImGuiWindowFlags_NoScrollWithMouse);
    ImGui::PopStyleColor();
    {   // the page's title, a rule under it
        ImDrawList *dl = ImGui::GetWindowDrawList();
        ImVec2 p = ImGui::GetCursorScreenPos();
        float ts = g_font_big->FontSize * ImGui::GetIO().FontGlobalScale * 0.8f, hh = fmaxf(62 * scale, ts * 1.25f);
        float cw = ImGui::GetContentRegionAvail().x;
        dl->AddText(g_font_big, ts, ImVec2(p.x + 4 * scale, p.y + (hh - ts * 1.1f) * 0.5f), ink, tr(open_name));
        if (in_game) quick_toggles(dl, ImVec2(p.x + 4 * scale + g_font_big->CalcTextSizeA(ts, FLT_MAX, 0, tr(open_name)).x + 24 * scale, p.y),
                                   ImVec2(p.x + cw, p.y + hh), scale);
        ImGui::SetCursorScreenPos(ImVec2(p.x, p.y + hh + 12 * scale));
        dl->AddLine(ImVec2(p.x, p.y + hh + 6 * scale), ImVec2(p.x + cw, p.y + hh + 6 * scale), rule, 1.2f * scale);
        ImGui::Dummy(ImVec2(cw, 6 * scale));
    }
    ImGui::PushStyleColor(ImGuiCol_ChildBg, ImVec4(0, 0, 0, 0));
    ImGui::BeginChild("##page", ImVec2(0, fmaxf(1, ImGui::GetContentRegionAvail().y)), ImGuiChildFlags_None,
                      ImGuiWindowFlags_NavFlattened);
    ImGui::PopStyleColor();
    ImGui::PushID(g_tab);
    switch (g_tab) {
    case -1: prelaunch(scale); break;
    case 0: tab_display(); break;
    case 1: tab_audio(); break;
    case 2: tab_language(in_game); break;
    case 3: saves_tab_draw(); break;
    case 4: mods_tab_draw(ImGui::GetFontSize() / 34, in_game); break;
    case 8: tab_about(); break;
    case 9: tab_quit(scale, in_game); break;
    }
    ImGui::PopID();
    static const char *scroll_test = getenv("SAVAGEWIND_MENU_SCROLL");  // test hook: page scroll, 0..1
    if (scroll_test) ImGui::SetScrollY(ImGui::GetScrollMaxY() * (float)atof(scroll_test));
    ImGui::EndChild();
    ImGui::EndChild();
    g_tab_request = -2;
    opt_focus_first(false);
}

void menu_tabs_draw(float scale, ImFont *font, ImFont *font_big, bool in_game, void (*prelaunch)(float)) {
    ImFont *f0 = g_font, *f1 = g_font_big;
    g_font = font, g_font_big = font_big;
    ImGuiStyle saved = ImGui::GetStyle();  // the menu's look (the start screen has its own style)
    style_init();
    ImGui::GetStyle().ScaleAllSizes(scale);
    tabs_body(scale, in_game, prelaunch);
    ImGui::GetStyle() = saved;
    g_font = f0, g_font_big = f1;
}

#ifndef __APPLE__
extern "C" void rec_drain(void);  // (runtime/nvn/vulkan/record.c)
#endif

// Everything menu_render draws, in one place: menu_render_needed (the caller's cue to drain the recorder first) and
// menu_render (which decides again, and drains itself) must agree on it. The pointer's hover box, the console and the
// gyro drag were missing here: their frames went to the command buffer while the recorder thread was still filling it.
static bool menu_draws(bool *pointer_hover = NULL, float *pointer_box = NULL, bool *gyro_show = NULL, GyroScene *gyro = NULL) {
    float box[4];
    GyroScene gs;
    bool hover = pc_cursor_hover_box(pointer_box ? pointer_box : box);
    bool gyro_on = pc_gyro_scene_view(gyro ? gyro : &gs);
    if (pointer_hover) *pointer_hover = hover;
    if (gyro_show) *gyro_show = gyro_on;
    return g_open.load() || g_kbd.load() == 1 || g_sizes.load() || console_is_open() || gyro_on || hover ||
           g_settings.perf_overlay != PERF_OFF || notice_on();
}

bool menu_render_needed(void) { return menu_draws(); }

#ifdef __APPLE__
void menu_render(id<MTLDevice> dev, id<MTLCommandBuffer> cb, id<MTLTexture> target) {
    const double tw = target.width, th = target.height;
#else
void menu_render(void *cmd, uint32_t target_w, uint32_t target_h) {
    const double tw = target_w, th = target_h;
#endif
    bool open = g_open.load();
    bool kbd = g_kbd.load() == 1;
    bool sizes = g_sizes.load();
    bool con = console_is_open();
    console_collect();
    GyroScene gyro_scene;
    bool gyro_scene_show;
    float pointer_box[4];
    bool pointer_hover;
    if (!menu_draws(&pointer_hover, pointer_box, &gyro_scene_show, &gyro_scene)) {
        if (g_inited) { pthread_mutex_lock(&q_lock); q_events.clear(); pthread_mutex_unlock(&q_lock); }
        return;
    }
#ifndef __APPLE__
    // ImGui records into the frame's command buffer from this thread, which is the recorder's until it has caught up.
    // The caller drains when menu_render_needed said so, but the pointer's hover box can appear (and the console and
    // the gyro drag can open) between that call and this one: draining again here is cheap when nothing is queued.
    rec_drain();
#endif
#ifdef __APPLE__
    if (!g_inited) init(dev);
#else
    if (!g_inited) init();
#endif
    ImGui::SetCurrentContext(g_ctx);
    ImGuiIO &io = ImGui::GetIO();
    io.DisplaySize = ImVec2((float)tw, (float)th);
    io.DisplayFramebufferScale = ImVec2(1, 1);
    static double last;
    double now = SDL_GetTicks() / 1000.0;
    io.DeltaTime = last > 0 && now > last ? (float)(now - last) : 1.0f / 60;
    last = now;
    drain_events(io);
    // fonts are built at 34/56 px for a ~1080 px tall output; scale to the window
    float scale = (float)(th / 1080.0);
    if (scale < 0.45f) scale = 0.45f;
    io.FontGlobalScale = scale;

#ifdef __APPLE__
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = target;
    rp.colorAttachments[0].loadAction = MTLLoadActionLoad;
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
#endif
    // spacing/rounding follow the output size too (style tuned for 1080 p)
    static ImGuiStyle base;
    static float style_scale = -1;
    if (style_scale < 0) base = ImGui::GetStyle();
    if (fabsf(style_scale - scale) > 0.01f) {
        ImGui::GetStyle() = base;
        ImGui::GetStyle().ScaleAllSizes(scale);
        style_scale = scale;
    }
    fonts_follow_language();
#ifdef __APPLE__
    ImGui_ImplMetal_NewFrame(rp);
#else
    ImGui_ImplVulkan_NewFrame();
#endif
    ImGui::NewFrame();

    if(pointer_hover&&!open&&!kbd) {
        float s=fminf(io.DisplaySize.x/1280.f,io.DisplaySize.y/720.f);
        ImVec2 a(io.DisplaySize.x*.5f+pointer_box[0]*s,io.DisplaySize.y*.5f-pointer_box[3]*s);
        ImVec2 b(io.DisplaySize.x*.5f+pointer_box[2]*s,io.DisplaySize.y*.5f-pointer_box[1]*s);
        bool pressed=pc_cursor_hover_pressed();
        if(pressed)ImGui::GetForegroundDrawList()->AddRectFilled(a,b,IM_COL32(250,250,220,45),2.f*s);
        ImGui::GetForegroundDrawList()->AddRect(a,b,pressed?IM_COL32(255,235,155,255):IM_COL32(250,250,220,255),2.f*s,0,2.f*s);
    }

    if (g_settings.perf_overlay != PERF_OFF) perf_overlay_draw(io, scale);
    if (notice_on()) notice_draw(io, scale);
    if (!open && !kbd && !sizes && !con && gyro_scene_show) gyro_scene_draw(io, scale, gyro_scene);

    if (open) {
        // dim the game behind the menu
        ImGui::GetBackgroundDrawList()->AddRectFilled(ImVec2(0, 0), io.DisplaySize, IM_COL32(0, 0, 0, 110));
        // (WSword's Glass Slate look, as the start screen's Settings: the rail of pages with its title and BACK -
        // tabs_body - in a navy glass window over most of the screen; B / Esc close it too)
        float w = io.DisplaySize.x * 0.94f, h = io.DisplaySize.y - 2 * 18 * scale;  // (all the height: a slim margin)
        ImGui::SetNextWindowPos(ImVec2(io.DisplaySize.x * 0.5f, io.DisplaySize.y * 0.5f), ImGuiCond_Always, ImVec2(0.5f, 0.5f));
        ImGui::SetNextWindowSize(ImVec2(w, h), ImGuiCond_Always);
        ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(28 * scale, 24 * scale));
        ImGui::PushStyleVar(ImGuiStyleVar_WindowRounding, 22 * scale);
        ImGui::Begin("##menu", NULL, ImGuiWindowFlags_NoDecoration | ImGuiWindowFlags_NoMove | ImGuiWindowFlags_NoSavedSettings);
        ImGui::PopStyleVar(2);
        ImFont *keep_big = g_font_big;  // (the window in the menu's font; header() uses g_font_big)
        g_font_big = g_menu_font_big;
        ImGui::PushFont(g_menu_font);

        bool any_popup = ImGui::IsPopupOpen("", ImGuiPopupFlags_AnyPopupId), typing = ui_text_busy();  // (before the
        tabs_body(scale, true, NULL);                                                                          //  pages run)
        // B with nothing focused-deeper closes the menu (not the Esc / B that ends typing: typing is from the frame
        // before, so it's still true the frame a field lets go)
        if (!any_popup && !typing && !ui_text_busy() && ImGui::IsWindowFocused(ImGuiFocusedFlags_RootAndChildWindows) &&
            (ImGui::IsKeyPressed(ImGuiKey_GamepadFaceRight, false) || ImGui::IsKeyPressed(ImGuiKey_Escape, false)))
            set_open(false);
        ImGui::PopFont();
        g_font_big = keep_big;
        ImGui::End();
        osk_draw(g_font_big, scale);  // (a text field activated with the controller)
    }

    if (kbd) keyboard_draw(io, scale);
    if (sizes) size_list_draw(io, scale);
    if (con) console_draw(io, scale, g_font_mono ? g_font_mono : g_font);
    ImGui::Render();
    g_text_busy = open && ui_text_busy();
#ifdef __APPLE__
    id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
    ImGui_ImplMetal_RenderDrawData(ImGui::GetDrawData(), cb, enc);
    [enc endEncoding];
#else
    ImGui_ImplVulkan_RenderDrawData(ImGui::GetDrawData(), (VkCommandBuffer)cmd);  // inside the window image's rendering
#endif
}
