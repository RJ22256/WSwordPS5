// On-screen keyboard (see osk.h). A controller has no keys to type with, and ImGui only starts text entry on a
// gamepad's Y (A on a field did nothing): A on any of our text fields opens this keyboard instead.
//
// One keyboard at a time (only one ImGui UI runs: start screen or in-game overlay, one thread each). It is a modal
// popup at the root of the UI, so the menu behind sees "a popup is open" and B / Esc / L / R don't act on it.
#include <ctype.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <atomic>
#include <string>

#include "i18n.h"
#include "imgui.h"
#include "imgui_internal.h"
#include "osk.h"

static struct {
    int open;                        // a field's keyboard is up
    ImGuiID field;                   // the field it types for
    char *buf;                       // ... and its buffer (static in every caller: written on OK)
    size_t size;
    ImGuiInputTextFlags flags;
    char text[128], title[96];
    bool appearing, nav_kbd_off;
    ImGuiID done_field;              // answered: reported by that field's next ui_input_text
    int done, done_frame;            // 1 OK, -1 cancelled; when (a field gone by then never hears of it)
} s;
static std::atomic<bool> s_cancel_req{false};
static bool s_cancelled_now;

bool osk_is_open(void) { return s.open != 0; }
void osk_cancel(void) { s_cancel_req = true; }

bool ui_text_busy(void) {
    ImGuiContext *g = ImGui::GetCurrentContext();
    return s.open || (g && (g->IO.WantTextInput || g->WantTextInputNextFrame == 1));
}

bool ui_input_text_cancelled(void) { return s_cancelled_now; }

// (test) SAVAGEWIND_FIELD_FOCUS=<label>:<n>[:edit]: the n-th time field <label> is drawn it gets the nav cursor (a
// controller's A - SAVAGEWIND_HOST_INPUT sdlpad:east - then opens the keyboard); :edit starts typing in it instead.
static int test_focus(const char *label) {
    static const char *spec = getenv("SAVAGEWIND_FIELD_FOCUS");
    static int count;
    if (!spec) return 0;
    const char *c = strchr(spec, ':');
    if (!c || strncmp(spec, label, (size_t)(c - spec)) || label[c - spec]) return 0;
    if (++count != atoi(c + 1)) return 0;
    return strstr(c + 1, ":edit") ? 2 : 1;
}

bool ui_input_text(const char *label, char *buf, size_t size, ImGuiInputTextFlags flags, const char *hint, const char *title) {
    ImGuiContext &g = *GImGui;
    int test = test_focus(label);
    if (test == 2) ImGui::SetKeyboardFocusHere();
    bool r = hint ? ImGui::InputTextWithHint(label, hint, buf, size, flags) : ImGui::InputText(label, buf, size, flags);
    ImGuiID id = ImGui::GetItemID();
    if (test == 1) { ImGui::FocusItem(); ImGui::SetNavCursorVisible(true); }
    // (and in view for the screenshots for a few frames: the focus' own scroll misses on a NavFlattened page)
    static ImGuiID in_view_id;
    static int in_view;
    if (test) in_view_id = id, in_view = 10;
    if (in_view_id == id && in_view > 0 && in_view--) ImGui::SetScrollHereY(0.5f);
    if (test) fprintf(stderr, "[osk] test: %s field %s\n", test == 2 ? "typing in" : "cursor on", label);
    static std::string last;  // (test runs: what the field holds, as it changes)
    const char *tf = getenv("SAVAGEWIND_FIELD_FOCUS");
    if (tf && !strncmp(tf, label, strlen(label)) && tf[strlen(label)] == ':' && last != buf) { last = buf; fprintf(stderr, "[osk] test: %s = \"%s\"%s\n", label, buf, g.ActiveId == id ? " (typing)" : ""); }
    s_cancelled_now = false;
    if (s.done && s.done_field == id && ImGui::GetFrameCount() - s.done_frame <= 1) {
        if (s.done > 0) r = true;
        else s_cancelled_now = true;
        s.done = 0, s.done_field = 0;
    }
    // activated from the controller: A (ImGui's "activate", which leaves a text field alone), Y (its "input"), or a
    // focus request (SetKeyboardFocusHere) while the controller drives the menu. A mouse click types directly.
    bool by_nav = g.NavActivateId == id || (ImGui::IsItemActivated() && g.ActiveIdSource != ImGuiInputSource_Mouse);
    if (by_nav && g.NavInputSource == ImGuiInputSource_Gamepad && !s.open && !(flags & ImGuiInputTextFlags_ReadOnly)) {
        if (g.ActiveId == id) ImGui::ClearActiveID();
        s.open = 1, s.appearing = true, s.done = 0;
        s.field = id, s.buf = buf, s.size = size, s.flags = flags;
        snprintf(s.text, sizeof s.text, "%s", buf);
        snprintf(s.title, sizeof s.title, "%s", tr(title ? title : hint ? hint : "Enter text"));
        r = false;
    }
    return r;
}

int osk_style_push(float scale) {
#ifdef __PROSPERO__
    ImGui::PushStyleColor(ImGuiCol_WindowBg, ImVec4(0.055f, 0.06f, 0.075f, 0.97f));
    ImGui::PushStyleColor(ImGuiCol_PopupBg, ImVec4(0.055f, 0.06f, 0.075f, 0.97f));
    ImGui::PushStyleColor(ImGuiCol_Border, ImVec4(1, 1, 1, 0.08f));
    ImGui::PushStyleColor(ImGuiCol_ModalWindowDimBg, ImVec4(0, 0, 0, 0.45f));
    ImGui::PushStyleVar(ImGuiStyleVar_WindowRounding, 22 * scale);
    ImGui::PushStyleVar(ImGuiStyleVar_PopupRounding, 22 * scale);
    ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(36 * scale, 30 * scale));
    return 4 << 8 | 3;
#else
    (void)scale;
    return 0;
#endif
}
void osk_style_pop(int pushed) {
    if (pushed) ImGui::PopStyleVar(pushed & 0xFF), ImGui::PopStyleColor(pushed >> 8);
}
void osk_title(const char *title, ImFont *big) {
#ifdef __PROSPERO__
    (void)big;
    ImGui::SetWindowFontScale(1.25f);  // (the menu font, larger: the big font's glyph sizes aren't the menu's)
    ImGui::TextColored(ImVec4(0.92f, 0.94f, 0.97f, 1), "%s", title);
    ImGui::SetWindowFontScale(1.0f);
    ImGui::Dummy(ImVec2(0, 6));
#else
    ImGui::PushFont(big);
    ImGui::TextColored(ImVec4(0.93f, 0.76f, 0.33f, 1), "%s", title);
    ImGui::PopFont();
#endif
}

#ifdef __PROSPERO__
// (the PS5) The keys as the console's keyboard draws them: dark rounded keys, the focused one white with dark text
static void ps_key_focus(const char *label, float rounding) {
    if (!ImGui::IsItemFocused() || !GImGui->NavCursorVisible) return;
    ImDrawList *dl = ImGui::GetWindowDrawList();
    ImVec2 a = ImGui::GetItemRectMin(), b = ImGui::GetItemRectMax();
    dl->AddRectFilled(a, b, IM_COL32(242, 244, 247, 255), rounding);
    ImVec2 ts = ImGui::CalcTextSize(label, NULL, true);
    dl->AddText(ImVec2((a.x + b.x - ts.x) * 0.5f, (a.y + b.y - ts.y) * 0.5f), IM_COL32(18, 20, 24, 255), label,
                ImGui::FindRenderedTextEnd(label));
}
// The prompts under the keys: the console's button shapes and what they do
static void ps_prompts(float scale) {
    ImDrawList *dl = ImGui::GetWindowDrawList();
    float h = ImGui::GetFontSize() * 1.15f, r = h * 0.42f, fs = ImGui::GetFontSize() * 0.85f, gap = 30 * scale;
    ImGui::Dummy(ImVec2(0, 8 * scale));
    ImVec2 p = ImGui::GetCursorScreenPos();
    float x = p.x, y = p.y + h * 0.5f;
    const ImU32 txt = IM_COL32(200, 210, 222, 255);
    struct { int glyph; const char *pill, *label; } items[] = {
        {0, NULL, "Select"}, {2, NULL, "Delete"}, {3, NULL, "Space"}, {-1, "L2", "Caps"}, {-1, "R2", "Done"}, {1, NULL, "Close"}};
    for (auto &it : items) {
        if (it.glyph >= 0) {
            ps_glyph(dl, ImVec2(x + r, y), r, it.glyph, scale);
            x += 2 * r + 8 * scale;
        } else {
            float ph = h * 0.8f;
            x += ps_pill(dl, ImVec2(x, y - ph * 0.5f), ph, it.pill, scale) + 8 * scale;
        }
        const char *l = tr(it.label);
        dl->AddText(ImGui::GetFont(), fs, ImVec2(x, y - fs * 0.5f), txt, l);
        x += ImGui::GetFont()->CalcTextSizeA(fs, FLT_MAX, 0, l).x + gap;
    }
    ImGui::Dummy(ImVec2(x - p.x, h));
}
#endif

int osk_keys(char *text, size_t cap, int max_chars, bool appearing, float scale, ImFont *big, bool upper_first) {
    static bool upper = true;
    if (appearing) upper = upper_first;
    ImGuiIO &io = ImGui::GetIO();
    // B deletes: owning it keeps ImGui's nav cancel (which drops the cursor off the keys) from seeing it
    ImGuiID own = ImGui::GetID("##oskkeys");
    ImGui::SetKeyOwner(ImGuiKey_GamepadFaceRight, own);
    if (max_chars <= 0 || max_chars > (int)cap - 1) max_chars = (int)cap - 1;
    int len = (int)strlen(text), r = 0;
    auto add = [&](char ch) { if (len < max_chars) text[len++] = ch, text[len] = 0; };
    auto del = [&]() { if (len > 0) text[--len] = 0; };

    // typed on a keyboard while it's up: straight into the text
    for (ImWchar c : io.InputQueueCharacters) if (c >= 0x20 && c < 0x7f) add((char)c);
    io.InputQueueCharacters.resize(0);
    if (ImGui::IsKeyPressed(ImGuiKey_Backspace)) del();
    if (ImGui::IsKeyPressed(ImGuiKey_Enter, false) || ImGui::IsKeyPressed(ImGuiKey_KeypadEnter, false)) r = 1;
    if (ImGui::IsKeyPressed(ImGuiKey_Escape, false)) r = -1;
    if (ImGui::IsKeyPressed(ImGuiKey_GamepadStart, false)) r = 1;
#ifdef __PROSPERO__
    // (the PS5: the console keyboard's buttons - Square deletes, Triangle a space, L2 caps, R2 / OPTIONS done, Circle
    // closes: done with what's typed, or cancelled when nothing is)
    ImGui::SetKeyOwner(ImGuiKey_GamepadFaceLeft, own);
    ImGui::SetKeyOwner(ImGuiKey_GamepadFaceUp, own);
    if (ImGui::IsKeyPressed(ImGuiKey_GamepadFaceLeft, ImGuiInputFlags_Repeat, own)) del();
    if (ImGui::IsKeyPressed(ImGuiKey_GamepadFaceUp, ImGuiInputFlags_Repeat, own) && len > 0) add(' ');
    if (ImGui::IsKeyPressed(ImGuiKey_GamepadL2, false)) upper = !upper;
    if (ImGui::IsKeyPressed(ImGuiKey_GamepadR2, false)) r = 1;
    if (ImGui::IsKeyPressed(ImGuiKey_GamepadFaceRight, false, own)) r = len > 0 ? 1 : -1;
    // the text in a field of its own
    {
        ImDrawList *dl = ImGui::GetWindowDrawList();
        ImVec2 a = ImGui::GetCursorScreenPos();
        float fh = ImGui::GetFontSize() * 1.9f, fw = ImGui::GetContentRegionAvail().x;
        dl->AddRectFilled(a, ImVec2(a.x + fw, a.y + fh), IM_COL32(28, 31, 37, 255), 10 * scale);
        dl->AddRect(a, ImVec2(a.x + fw, a.y + fh), IM_COL32(255, 255, 255, 40), 10 * scale, 0, 1.5f * scale);
        float ts = ImGui::GetFontSize() * 1.2f;
        char shown[160];
        snprintf(shown, sizeof shown, "%s%s", text, (ImGui::GetFrameCount() / 30) % 2 ? "|" : " ");
        dl->AddText(ImGui::GetFont(), ts, ImVec2(a.x + 18 * scale, a.y + (fh - ts) * 0.5f), IM_COL32(240, 243, 247, 255), shown);
        char cnt[32];
        snprintf(cnt, sizeof cnt, "%d / %d", len, max_chars);
        float cw = ImGui::CalcTextSize(cnt).x;
        dl->AddText(ImVec2(a.x + fw - cw - 18 * scale, a.y + (fh - ImGui::GetFontSize()) * 0.5f), IM_COL32(150, 160, 172, 255), cnt);
        ImGui::Dummy(ImVec2(fw, fh + 12 * scale));
    }
    (void)big;
    float krnd = 10 * scale;
    ImGui::PushStyleColor(ImGuiCol_Button, ImVec4(0.16f, 0.17f, 0.20f, 1));
    ImGui::PushStyleColor(ImGuiCol_ButtonHovered, ImVec4(0.22f, 0.23f, 0.27f, 1));
    ImGui::PushStyleColor(ImGuiCol_ButtonActive, ImVec4(0.85f, 0.87f, 0.9f, 1));
    ImGui::PushStyleColor(ImGuiCol_NavCursor, ImVec4(1, 1, 1, 0));
    ImGui::PushStyleVar(ImGuiStyleVar_FrameRounding, krnd);
    ImGui::PushStyleVar(ImGuiStyleVar_ItemSpacing, ImVec2(8 * scale, 8 * scale));
#define KEY_FOCUS(l) ps_key_focus(l, krnd)
#else
    if (ImGui::IsKeyPressed(ImGuiKey_GamepadFaceRight, ImGuiInputFlags_Repeat, own)) del();
#define KEY_FOCUS(l) ((void)0)
    ImGui::PushFont(big);
    ImGui::Text("%s_", text);
    ImGui::PopFont();
#endif
    static const char *rows_u[] = {"ABCDEFGHIJ", "KLMNOPQRST", "UVWXYZ-.'!", "0123456789"};
    static const char *rows_l[] = {"abcdefghij", "klmnopqrst", "uvwxyz-.'!", "0123456789"};
    const char **rows = upper ? rows_u : rows_l;
    float k = 70 * scale;
    for (int row = 0; row < 4; row++) {
        for (int i = 0; rows[row][i]; i++) {
            if (i) ImGui::SameLine();
            char lbl[8] = {rows[row][i], 0};
            if (appearing && row == 0 && i == 0) {  // (cursor shown: else the first A only reveals it)
                ImGui::SetKeyboardFocusHere();
                ImGui::SetNavCursorVisible(true);
            }
            if (ImGui::Button(lbl, ImVec2(k, k))) add(rows[row][i]);
            KEY_FOCUS(lbl);
        }
    }
    const char *cl = upper ? "abc" : "ABC";
    if (ImGui::Button(cl, ImVec2(k * 2, k))) upper = !upper;
    KEY_FOCUS(cl);
    ImGui::SameLine();
    if (ImGui::Button(tr("Space"), ImVec2(k * 3, k)) && len > 0) add(' ');
    KEY_FOCUS(tr("Space"));
    ImGui::SameLine();
    if (ImGui::Button(tr("Delete"), ImVec2(k * 2, k))) del();
    KEY_FOCUS(tr("Delete"));
    ImGui::SameLine();
    if (ImGui::Button(tr("Cancel"), ImVec2(k * 2, k))) r = -1;
    KEY_FOCUS(tr("Cancel"));
    ImGui::SameLine();
#ifdef __PROSPERO__
    ImGui::PushStyleColor(ImGuiCol_Button, ImVec4(0.0f, 0.36f, 0.85f, 1));  // (the console's blue for Done)
    ImGui::PushStyleColor(ImGuiCol_ButtonHovered, ImVec4(0.1f, 0.45f, 0.95f, 1));
    if (ImGui::Button(tr("Done"), ImVec2(k * 2, k))) r = 1;
    ImGui::PopStyleColor(2);
    KEY_FOCUS(tr("Done"));
    ImGui::PopStyleVar(2);
    ImGui::PopStyleColor(4);
    ps_prompts(scale);
#else
    if (ImGui::Button(tr("OK"), ImVec2(k * 2, k))) r = 1;
    ImGui::TextDisabled(tr("A  type      B  delete      Start / +  OK      (%d / %d)"), len, max_chars);
#endif
#undef KEY_FOCUS
    return r;
}

// close it (and give the keyboard back to ImGui's navigation)
static void finish(int result) {
    if (result > 0 && s.buf && s.size) {
        if (s.flags & ImGuiInputTextFlags_CharsUppercase)
            for (char *p = s.text; *p; p++) *p = (char)toupper((unsigned char)*p);
        snprintf(s.buf, s.size, "%s", s.text);
    }
    s.done = result, s.done_field = s.field, s.done_frame = ImGui::GetFrameCount();
    s.open = 0, s.buf = NULL;
    if (s.nav_kbd_off) ImGui::GetIO().ConfigFlags |= ImGuiConfigFlags_NavEnableKeyboard;
    s.nav_kbd_off = false;
}

void osk_draw(ImFont *big, float scale) {
    bool cancel = s_cancel_req.exchange(false);
    if (!s.open) return;
    ImGuiIO &io = ImGui::GetIO();
    ImGuiContext &g = *GImGui;
    if (!ImGui::IsPopupOpen("##osk")) {
        ImGui::OpenPopup("##osk");
        s.appearing = true;
        // keys typed while it's up are text: Space / Enter / arrows must not also press the focused key
        if (io.ConfigFlags & ImGuiConfigFlags_NavEnableKeyboard) { io.ConfigFlags &= ~ImGuiConfigFlags_NavEnableKeyboard; s.nav_kbd_off = true; }
    }
    g.WantTextInputNextFrame = 1;  // (typing stays on: the backends keep text input enabled; ui_text_busy)
    float w = fminf(io.DisplaySize.x * 0.9f, 1100 * scale);
    ImGui::SetNextWindowPos(ImVec2(io.DisplaySize.x * 0.5f, io.DisplaySize.y * 0.5f), ImGuiCond_Always, ImVec2(0.5f, 0.5f));
    ImGui::SetNextWindowSize(ImVec2(w, 0), ImGuiCond_Always);
    int pushed = osk_style_push(scale);
    if (!ImGui::BeginPopupModal("##osk", NULL, ImGuiWindowFlags_NoDecoration | ImGuiWindowFlags_NoMove |
                                                   ImGuiWindowFlags_NoSavedSettings | ImGuiWindowFlags_AlwaysAutoResize)) {
        osk_style_pop(pushed);
        finish(-1);
        return;
    }
    osk_title(s.title, big);
    int max = (int)(s.size < sizeof s.text ? s.size : sizeof s.text) - 1;
    int r = cancel ? -1 : osk_keys(s.text, sizeof s.text, max, s.appearing, scale, big);
    s.appearing = false;
    if (r) {
        ImGui::CloseCurrentPopup();
        finish(r);
    }
    ImGui::EndPopup();
    osk_style_pop(pushed);
}
