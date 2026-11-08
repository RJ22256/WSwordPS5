// Two-pane settings pages (see option_rows.h) in WSword's Glass Slate look: rows on the left - the label, the value in
// the right part of the row - the selected one a navy glass tile outlined in cyan, and the selected / hovered row's
// name and description in a glass card on the right.
#include <ctype.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <string>
#include <vector>

#include "imgui.h"
#include "imgui_internal.h"  // (SetKeyOwner, NavCursorVisible)

#include "i18n.h"
#include "option_rows.h"
#include "osk.h"

static float g_scale = 1;
static std::string g_desc_hover, g_desc_focus, g_desc_shown;  // this frame's hovered / selected row, and the last shown
static std::string g_desc_first;  // the page's first row (shown until a row is selected or hovered)
static std::string g_name_hover, g_name_focus, g_name_shown, g_name_first;  // (WSword: their names, the card's title)
static bool g_two_panes;          // room for the description beside the rows (else it goes under the selected row)
static float g_drag = -1;         // a slider row being dragged along its value: where, 0..1 (-1: none)
static ImGuiID g_drag_id;         // (that row)
static bool g_row_dragged;        // (the last row drawn is being dragged this frame: opt_slider / opt_int)
struct DescImage { unsigned long long tex = 0; int w = 0, h = 0; };
static DescImage g_img_hover, g_img_focus, g_img_shown;  // (the pictures of those rows: opt_desc_image)
static std::vector<unsigned long long> g_img_live;       // the pictures offered this frame

static const ImU32 kCyan = IM_COL32(94, 230, 245, 255);  // (WSword's Glass Slate look: what's picked)

// ◀ / ▶ and › (the fonts have no arrow glyphs)
static void arrow(ImDrawList *dl, float x, float cy, float s, bool right, ImU32 col) {
    if (right) dl->AddTriangleFilled(ImVec2(x + s, cy), ImVec2(x, cy - s * 0.9f), ImVec2(x, cy + s * 0.9f), col);
    else dl->AddTriangleFilled(ImVec2(x, cy), ImVec2(x + s, cy - s * 0.9f), ImVec2(x + s, cy + s * 0.9f), col);
}
static void chevron(ImDrawList *dl, float x, float cy, float s, ImU32 col) {
    dl->AddLine(ImVec2(x - s * 0.5f, cy - s), ImVec2(x + s * 0.5f, cy), col, fmaxf(1.5f, s * 0.28f));
    dl->AddLine(ImVec2(x + s * 0.5f, cy), ImVec2(x - s * 0.5f, cy + s), col, fmaxf(1.5f, s * 0.28f));
}
static bool g_next_disabled;
void opt_disable_next(void) { g_next_disabled = true; }
static bool g_value_dim;  // the next row's value is shown greyed (a value that can't be picked yet)
static int g_indent;
static bool g_focus_req, g_take_first;  // (opt_focus_first: requested / this page's first row takes it)
void opt_focus_first(bool on) { g_focus_req = on; }
static bool g_held;  // the last row's left / right has been held a while (steppers go faster)
void opt_indent(int step) { g_indent = g_indent + step < 0 ? 0 : g_indent + step; }
// (WSword 0.3.15, Glass Slate 2) the next toggle as a hero card: taller, its line under the name, a switch, a key chip
static bool g_hero, g_hero_on;
static const char *g_hero_sub, *g_hero_key;
void opt_hero_next(const char *sub, const char *key) { g_hero = true, g_hero_sub = sub, g_hero_key = key; }

void opt_begin(const char *id, float scale) {
    g_scale = scale;
    static std::string page;  // (another page: its first row's description, not the last page's)
    if (page != id) page = id, g_desc_shown.clear(), g_name_shown.clear(), g_img_shown = DescImage();
    g_take_first = g_focus_req;
    g_focus_req = false;
    if (g_take_first) ImGui::NavMoveRequestCancel();  // (this frame's Down goes to the first row instead)
    g_indent = 0;
    g_desc_hover.clear(), g_desc_focus.clear(), g_name_hover.clear(), g_name_focus.clear();
    g_img_hover = g_img_focus = DescImage(), g_img_live.clear();
    ImVec2 avail = ImGui::GetContentRegionAvail();
    ImGui::PushID(id);
    // two panes when there is room: the rows, and the description on the right (a narrow window: under the row)
    g_two_panes = avail.x >= 760 * scale;
    ImGui::PushStyleColor(ImGuiCol_ChildBg, ImVec4(0, 0, 0, 0));  // (the window's own glass shows through)
    ImGui::BeginChild("##rows", ImVec2(g_two_panes ? avail.x * 0.6f : avail.x, avail.y), ImGuiChildFlags_None,
                      ImGuiWindowFlags_NavFlattened);
    ImGui::PopStyleColor();
    ImGui::PushStyleVar(ImGuiStyleVar_ItemSpacing, ImVec2(ImGui::GetStyle().ItemSpacing.x, 0));  // (rows touch: their lines part them)
    g_desc_first.clear(), g_name_first.clear();
}

// (labels, values, descriptions and titles are English: shown in the menu language, tr(); IDs stay English)
void opt_section(const char *title) { ui_glass_heading(title, g_scale); }

// (WSword's Glass Slate look) a section's title: light cyan capitals, a thin navy rule after them
void ui_glass_heading(const char *title, float s) {
    std::string t = tr_upper(tr(title));
    if (ImGui::GetCursorPosY() > ImGui::GetStyle().WindowPadding.y + 1) ImGui::Dummy(ImVec2(0, 14 * s));
    ImVec2 p = ImGui::GetCursorScreenPos();
    float fs = ImGui::GetFontSize() * 0.78f, w = ImGui::GetContentRegionAvail().x;
    ImDrawList *dl = ImGui::GetWindowDrawList();
    float tw = ImGui::CalcTextSize(t.c_str()).x * 0.78f;
    dl->AddText(ImGui::GetFont(), fs, ImVec2(p.x + 16 * s, p.y), IM_COL32(143, 217, 230, 255), t.c_str());
    float ly = p.y + fs * 0.55f, lx = p.x + 16 * s + tw + 14 * s;
    if (lx < p.x + w - 20 * s) dl->AddLine(ImVec2(lx, ly), ImVec2(p.x + w - 12 * s, ly), IM_COL32(28, 53, 80, 255), 1.2f * s);
    ImGui::Dummy(ImVec2(w, fs + 8 * s));
}

// One row: draws it, handles A / click and left / right while selected. Returns 2 (A / click), -1 / +1 (left / right,
// or a click on that side's arrow) or 0. arrows: a value that steps (◀ value ▶ on the selected row). bar: a slider's
// position, 0..1 (-1: none) - dragging along the selected row's value sets it (g_drag). (upper: the labels were
// capitals; the Glass Slate look writes them as given.)
static int row(const char *label, const std::string &value, bool changed, const char *desc, bool upper = true,
               bool arrows = false, float bar = -1) {
    (void)upper;
    ImGui::PushID(label);
    const char *name = tr(label);
    bool hero = g_hero;
    g_hero = false;
    if (g_indent) ImGui::SetCursorPosX(ImGui::GetCursorPosX() + g_indent * 28 * g_scale);  // (an option of the row above)
    ImVec2 p = ImGui::GetCursorScreenPos();
    float s = g_scale, fs = ImGui::GetFontSize();
    float w = ImGui::GetContentRegionAvail().x, h = hero ? fmaxf(fs * 4.2f, 124 * s) : fmaxf(fs * 2.4f, 62 * s);
    ImGui::PushStyleColor(ImGuiCol_NavCursor, ImVec4(0, 0, 0, 0));  // (the row's own frame shows the selection)
    bool clicked = ImGui::InvisibleButton("##row", ImVec2(w, h), ImGuiButtonFlags_EnableNav);
    ImGui::PopStyleColor();
    ImGuiID id = ImGui::GetItemID();
    if (g_take_first) {  // (opt_focus_first)
        g_take_first = false;
        ImGui::SetFocusID(id, ImGui::GetCurrentWindow());
        ImGui::SetNavCursorVisible(true);
        ImGui::SetScrollHereY(0);
    }
    bool off = g_next_disabled;  // (greyed out: still selectable, so its description shows, but it can't change)
    g_next_disabled = false;
    bool dim = off || g_value_dim;
    g_value_dim = false;
    ImGuiIO &io = ImGui::GetIO();
    bool hov = ImGui::IsItemHovered(), foc = ImGui::IsItemFocused() && ImGui::GetCurrentContext()->NavCursorVisible;
    bool sel = hov || foc;
    // the value's column: the right part of the row, the value centred in it
    float pad = 18 * s, vx0 = p.x + w * 0.56f, vx1 = p.x + w - pad - fs * 0.5f, cy = p.y + h * 0.5f;
    float aw = fs * 0.36f;
    float lax = vx0 + pad * 0.5f, rax = vx1 - aw - pad * 0.5f;  // (the arrows' x, on the selected row)
    int step = clicked && !off ? 2 : 0;
    if (step && arrows && !value.empty()) {  // (a click on an arrow steps that way)
        float mx = io.MousePos.x;
        if (mx >= vx0 && mx <= lax + aw + pad) step = -1;
        else if (mx >= rax - pad) step = 1;
    }
    if (clicked && g_drag_id == id) step = 0;  // (the mouse let go of a drag along the value)
    g_held = false;
    if (foc && !off) {
        if (ImGui::IsKeyPressed(ImGuiKey_GamepadDpadLeft) || ImGui::IsKeyPressed(ImGuiKey_GamepadLStickLeft) ||
            ImGui::IsKeyPressed(ImGuiKey_LeftArrow))
            step = -1;
        if (ImGui::IsKeyPressed(ImGuiKey_GamepadDpadRight) || ImGui::IsKeyPressed(ImGuiKey_GamepadLStickRight) ||
            ImGui::IsKeyPressed(ImGuiKey_RightArrow))
            step = 1;
        for (ImGuiKey k : {ImGuiKey_GamepadDpadLeft, ImGuiKey_GamepadDpadRight, ImGuiKey_GamepadLStickLeft,
                           ImGuiKey_GamepadLStickRight, ImGuiKey_LeftArrow, ImGuiKey_RightArrow})
            if (ImGui::GetKeyData(k)->DownDuration > 1.0f) g_held = true;
        // left / right belong to the row (navigation would otherwise try to move sideways)
        for (ImGuiKey k : {ImGuiKey_GamepadDpadLeft, ImGuiKey_GamepadDpadRight, ImGuiKey_LeftArrow, ImGuiKey_RightArrow})
            ImGui::SetKeyOwner(k, id);
    }
    // a slider: the mouse held on the selected row's value and moved sideways sets it where it is along the bar
    float bx0 = lax + aw + pad, bx1 = rax - pad;
    g_row_dragged = false;
    if (bar >= 0 && !off && ImGui::IsItemActive() && io.MouseDown[0] && io.MouseClickedPos[0].x >= vx0 &&
        (g_drag_id == id || fabsf(io.MousePos.x - io.MouseClickedPos[0].x) > fs * 0.3f) && bx1 > bx0) {
        g_drag = fminf(1, fmaxf(0, (io.MousePos.x - bx0) / (bx1 - bx0)));
        g_drag_id = id, g_row_dragged = true;
    } else if (g_drag_id == id && !io.MouseDown[0]) g_drag = -1, g_drag_id = 0;
    if (desc) desc = tr(desc);
    if (foc) g_desc_focus = desc ? desc : "", g_name_focus = name;
    if (hov) g_desc_hover = desc ? desc : "", g_name_hover = name;
    if (g_name_first.empty()) g_desc_first = desc ? desc : "", g_name_first = name;

    ImDrawList *dl = ImGui::GetWindowDrawList();
    if (hero) {  // (opt_hero_next) a card: the name large, its line under it, the switch and the key on the right
        ImVec2 a(p.x + 2, p.y + 4 * s), b(p.x + w, p.y + h - 10 * s);
        float r = 16 * s, sw = 66 * s, sh = 36 * s, sx = p.x + w - pad - sw, scy = (a.y + b.y) * 0.5f;
        dl->AddRectFilled(a, b, off ? IM_COL32(16, 36, 52, 150) : IM_COL32(14, 44, 64, 235), r);
        dl->AddRectFilled(ImVec2(a.x, a.y), ImVec2(a.x + 5 * s, b.y), off ? IM_COL32(94, 230, 245, 70) : kCyan, r,
                          ImDrawFlags_RoundCornersLeft);
        dl->AddRect(a, b, sel ? IM_COL32(94, 230, 245, off ? 120 : 245) : IM_COL32(94, 230, 245, off ? 40 : 90), r, 0,
                    (sel ? 2.2f : 1.3f) * s);
        float tx = a.x + pad + 8 * s, room = sx - tx - 20 * s, big = fs * 1.2f, small = fs * 0.7f;
        float ty0 = a.y + (b.y - a.y - big * 1.15f - small * 1.3f * 2) * 0.5f;
        dl->AddText(ImGui::GetFont(), big, ImVec2(tx, ty0), off ? IM_COL32(110, 125, 140, 255) : IM_COL32(243, 247, 250, 255), name);
        if (g_hero_sub)
            dl->AddText(ImGui::GetFont(), small, ImVec2(tx, ty0 + big * 1.18f), IM_COL32(170, 190, 207, 255), tr(g_hero_sub), NULL,
                        room);
        bool on = g_hero_on && !off;
        dl->AddRectFilled(ImVec2(sx, scy - sh * 0.5f), ImVec2(sx + sw, scy + sh * 0.5f),
                          on ? kCyan : IM_COL32(30, 50, 67, 255), sh * 0.5f);
        float kr = sh * 0.5f - 4 * s, kx = on ? sx + sw - 4 * s - kr : sx + 4 * s + kr;
        dl->AddCircleFilled(ImVec2(kx, scy), kr, off ? IM_COL32(140, 155, 170, 255) : IM_COL32(243, 247, 250, 255), 24);
        if (g_hero_key && *g_hero_key) {  // the key that flips it in the game: a keycap left of the switch
            float kfs = fs * 0.66f, kw = ImGui::CalcTextSize(g_hero_key).x * 0.66f + 18 * s, kh = kfs * 1.7f;
            float kx0 = sx - 14 * s - kw;
            dl->AddRect(ImVec2(kx0, scy - kh * 0.5f), ImVec2(kx0 + kw, scy + kh * 0.5f), IM_COL32(170, 190, 207, 160), 6 * s, 0,
                        1.4f * s);
            dl->AddText(ImGui::GetFont(), kfs, ImVec2(kx0 + 9 * s, scy - kfs * 0.6f), IM_COL32(201, 214, 226, 255), g_hero_key);
        }
        if (!g_two_panes && foc && desc && *desc) {
            ImGui::PushTextWrapPos(0);
            ImGui::TextColored(ImVec4(0.73f, 0.80f, 0.86f, 1), "%s", desc);
            ImGui::PopTextWrapPos();
        }
        ImGui::PopID();
        return step;
    }
    const ImU32 rule = IM_COL32(28, 53, 80, off ? 120 : 255);
    ImVec2 b(p.x + w, p.y + h - 3 * s);
    if (sel) {
        dl->AddRectFilled(ImVec2(p.x + 2, p.y + 3 * s), b, off ? IM_COL32(18, 51, 73, 110) : IM_COL32(18, 51, 73, 255), 12 * s);
        dl->AddRect(ImVec2(p.x + 2, p.y + 3 * s), b, off ? IM_COL32(94, 230, 245, 90) : IM_COL32(94, 230, 245, 240), 12 * s,
                    0, 2 * s);
    } else {
        dl->AddLine(ImVec2(p.x + 10 * s, p.y + h - 1), ImVec2(p.x + w - 4 * s, p.y + h - 1), rule, 1.2f * s);
    }
    float ty = cy - fs * 0.5f;
    ImU32 label_col = off ? IM_COL32(110, 125, 140, 255) : IM_COL32(234, 242, 250, 255);
    // the label, cut short with an ellipsis before the value's column (long names, bigger fonts)
    float room = (value.empty() ? vx1 : vx0) - (p.x + pad) - pad * 0.5f;
    const char *end = name;
    while (*end) {
        const char *next = end + 1;
        while (((unsigned char)*next & 0xc0) == 0x80) ++next;
        if (ImGui::CalcTextSize(name, next).x > room) break;
        end = next;
    }
    dl->AddText(ImVec2(p.x + pad, ty), label_col, name, end);
    if (*end) dl->AddText(ImVec2(p.x + pad + ImGui::CalcTextSize(name, end).x, ty), label_col, "...");
    if (!value.empty()) {
        ImU32 vcol = dim ? IM_COL32(110, 125, 140, 255) : changed ? IM_COL32(143, 217, 230, 255) : IM_COL32(207, 227, 241, 255);
        float vw = ImGui::CalcTextSize(value.c_str()).x, vx = (vx0 + vx1 - vw) * 0.5f;
        if (vw > vx1 - vx0) vx = vx1 - vw;  // (a long value: its end at the column's)
        float vy = bar >= 0 && sel ? ty - fs * 0.18f : ty;
        dl->AddText(ImVec2(vx, vy), vcol, value.c_str());
        if (sel && arrows && !off) {
            arrow(dl, lax, cy, aw, false, kCyan);
            arrow(dl, rax, cy, aw, true, kCyan);
        }
        if (bar >= 0 && sel && bx1 > bx0) {  // (a slider: its track under the value, filled to where it is)
            float by = cy + fs * 0.52f, f = g_drag_id == id ? g_drag : bar;
            dl->AddLine(ImVec2(bx0, by), ImVec2(bx1, by), IM_COL32(35, 65, 95, 255), 2 * s);
            dl->AddLine(ImVec2(bx0, by), ImVec2(bx0 + (bx1 - bx0) * f, by), kCyan, 3 * s);
            dl->AddCircleFilled(ImVec2(bx0 + (bx1 - bx0) * f, by), 5 * s, kCyan, 12);
        }
    }
    if (!sel || !arrows) chevron(dl, p.x + w - pad * 0.9f, cy, fs * 0.22f, off ? IM_COL32(94, 230, 245, 70) : kCyan);
    if (!g_two_panes && foc && desc && *desc) {  // (one pane: the description under the selected row)
        ImGui::PushTextWrapPos(0);
        ImGui::TextColored(ImVec4(0.73f, 0.80f, 0.86f, 1), "%s", desc);
        ImGui::PopTextWrapPos();
    }
    ImGui::PopID();
    return step;
}

bool opt_toggle(const char *label, bool *v, bool def, const char *desc) {
    g_hero_on = *v;
    if (!row(label, tr(*v ? "On" : "Off"), *v != def, desc)) return false;  // (any step flips it)
    *v = !*v;
    return true;
}

bool opt_choice(const char *label, int *v, const char *const *names, int n, int def, const char *desc, bool wrap) {
    int cur = *v >= 0 && *v < n ? *v : 0;
    int step = row(label, tr(names[cur]), cur != def, desc, true, true);
    if (!step) return false;
    int nv = cur + (step == 2 ? 1 : step);
    nv = wrap ? (nv + n) % n : nv < 0 ? 0 : nv >= n ? n - 1 : nv;
    if (nv == cur) return false;
    *v = nv;
    return true;
}

bool opt_list(const char *label, int *v, const char *const *names, int n, int def, const char *desc, bool *picked) {
    int cur = *v >= 0 && *v < n ? *v : 0;
    int step = row(label, tr(names[cur]), cur != def, desc, true, true);
    *picked = false;
    ImVec2 a = ImGui::GetItemRectMin(), b = ImGui::GetItemRectMax();
    ImGui::PushID(label);
    static bool test_open;  // (test: SAVAGEWIND_OPT_LIST=<label> opens that list once)
    const char *t = getenv("SAVAGEWIND_OPT_LIST");
    if (step == 2 || (t && !test_open && !strcmp(t, label) && (test_open = true))) ImGui::OpenPopup("##list");
    int nv = step == 1 || step == -1 ? (cur + step + n) % n : cur;
    // the list below the row (above it when there's no room), the current value selected and in view
    float rows_h = ImGui::GetFrameHeightWithSpacing() * 12;
    bool up = b.y + rows_h > ImGui::GetMainViewport()->WorkPos.y + ImGui::GetMainViewport()->WorkSize.y;
    ImGui::SetNextWindowPos(up ? ImVec2(a.x, a.y) : ImVec2(a.x, b.y), ImGuiCond_Appearing, ImVec2(0, up ? 1.0f : 0.0f));
    ImGui::SetNextWindowSizeConstraints(ImVec2(b.x - a.x, 0), ImVec2(b.x - a.x, rows_h));
    ImVec4 bg = ImGui::GetStyleColorVec4(ImGuiCol_PopupBg);
    bg.w = 1;  // (opaque: the rows below don't show through)
    ImGui::PushStyleColor(ImGuiCol_PopupBg, bg);
    ImGui::PushStyleColor(ImGuiCol_Border, ImGui::ColorConvertU32ToFloat4(kCyan));
    bool open = ImGui::BeginPopup("##list");
    ImGui::PopStyleColor(2);
    if (open) {
        bool appearing = ImGui::IsWindowAppearing();
        for (int i = 0; i < n; i++) {
            ImGui::PushID(i);
            if (ImGui::Selectable(tr(names[i]), i == cur)) nv = i, *picked = true;
            if (i == cur && appearing) ImGui::SetItemDefaultFocus(), ImGui::SetScrollHereY(0.5f);
            ImGui::PopID();
        }
        ImGui::EndPopup();
    }
    ImGui::PopID();
    if (nv == cur) return false;
    *v = nv;
    return true;
}

bool opt_choice_avail(const char *label, int *v, int *shown, const char *const *names, const bool *avail, int n, int def,
                      const char *desc) {
    int cur = *v >= 0 && *v < n ? *v : 0;
    if (*shown < 0 || *shown >= n || (avail[*shown] && *shown != cur)) *shown = cur;  // (changed elsewhere)
    int s = *shown;
    g_value_dim = !avail[s];
    int step = row(label, tr(names[s]), s != def, desc, true, true);
    if (!step) return false;
    s = (s + (step == 2 ? 1 : step) + n) % n;
    *shown = s;
    if (!avail[s] || s == cur) return false;
    *v = s;
    return true;
}

bool opt_slider(const char *label, float *v, float lo, float hi, float step, float def, const char *fmt, const char *desc) {
    char buf[32];
    snprintf(buf, sizeof buf, tr(fmt), *v);
    float frac = hi > lo ? (*v - lo) / (hi - lo) : 0;
    int s = row(label, buf, fabsf(*v - def) > step * 0.01f, desc, true, true, frac);
    if (g_row_dragged) {  // (dragged along the value: continuous, to the step)
        float n = lo + roundf(g_drag * (hi - lo) / step) * step;
        n = n < lo ? lo : n > hi ? hi : n;
        if (n == *v) return false;
        *v = n;
        return true;
    }
    if (!s) return false;
    float eps = step * 0.01f, n = roundf(*v / step) * step + (s == 2 ? step : s * step);
    if (s == 2 && n > hi + eps) n = lo;  // (A / click past the top wraps to the bottom; left / right stop at the ends)
    *v = n < lo ? lo : n > hi ? hi : n;
    return true;
}

bool opt_int(const char *label, int *v, int lo, int hi, int step, int def, const char *fmt, const char *desc,
             const char *lo_name) {
    char buf[48];
    if (lo_name && *v == lo) snprintf(buf, sizeof buf, "%s", tr(lo_name));
    else snprintf(buf, sizeof buf, tr(fmt), *v);
    float frac = hi > lo ? (float)(*v - lo) / (float)(hi - lo) : 0;
    int s = row(label, buf, *v != def, desc, true, true, frac);
    if (g_row_dragged) {
        int n = lo + (int)roundf(g_drag * (float)(hi - lo) / step) * step;
        n = n < lo ? lo : n > hi ? hi : n;
        if (n == *v) return false;
        *v = n;
        return true;
    }
    if (!s) return false;
    int d = s == 2 ? step : s * step * (g_held && hi - lo > 40 * step ? 10 : 1);
    int n = *v + d;
    if (s == 2 && n > hi) n = lo;  // (A / click past the top wraps; left / right stop at the ends)
    n = n < lo ? lo : n > hi ? hi : n;
    if (n == *v) return false;
    *v = n;
    return true;
}

void opt_desc_image(unsigned long long tex, int w, int h) {
    g_img_live.push_back(tex);
    if (ImGui::IsItemHovered()) g_img_hover = {tex, w, h};
    if (ImGui::IsItemFocused() && ImGui::GetCurrentContext()->NavCursorVisible) g_img_focus = {tex, w, h};
}

bool opt_button(const char *label, const char *desc) { return row(label, "", false, desc) == 2; }

bool opt_radio(const char *label, bool selected, const char *desc) {
    bool off = g_next_disabled;
    bool chosen = row(label, "", false, desc) == 2;
    ImVec2 a = ImGui::GetItemRectMin(), b = ImGui::GetItemRectMax();
    float r = ImGui::GetFontSize() * 0.32f, cx = b.x - 40 * g_scale - r, cy = (a.y + b.y) * 0.5f;
    ImDrawList *dl = ImGui::GetWindowDrawList();
    ImU32 col = off ? IM_COL32(110, 125, 140, 255) : selected ? kCyan : IM_COL32(207, 227, 241, 255);
    dl->AddCircle(ImVec2(cx, cy), r, col, 0, 2.0f);
    if (selected) dl->AddCircleFilled(ImVec2(cx, cy), r * 0.55f, col);
    return chosen && !selected;
}

bool opt_action(const char *label, const char *value, const char *desc, bool upper) {
    return row(label, value ? value : "", false, desc, upper) == 2;
}

static ImGuiID g_text_editing;  // the text row turned into a field (one at a time)
bool opt_text_editing(const char *label) { return g_text_editing && g_text_editing == ImGui::GetID(label); }

bool opt_text(const char *label, char *buf, size_t cap, const char *hint, const char *desc) {
    ImGuiID &editing = g_text_editing;
    static int focus;        // frames left to give it the keyboard focus
    ImGuiID id = ImGui::GetID(label);
    if (editing != id) {
        if (row(label, buf[0] ? buf : (hint ? tr(hint) : ""), false, desc) == 2) editing = id, focus = 2;
        return false;
    }
    ImGui::PushID(label);
    ImGui::SetNextItemWidth(-1);
    if (focus > 0) ImGui::SetKeyboardFocusHere(), focus--;
    bool done = ui_input_text("##text", buf, cap, ImGuiInputTextFlags_EnterReturnsTrue, hint, label);
    if (ImGui::IsItemFocused()) g_desc_focus = desc ? tr(desc) : "", g_name_focus = tr(label);
    if (done || ui_input_text_cancelled() || (focus == 0 && !ImGui::IsItemActive() && !osk_is_open())) editing = 0;
    ImGui::PopID();
    return done;
}

void opt_end(void) {
    ImGui::PopStyleVar();
    if (const char *t = getenv("SAVAGEWIND_OPT_SCROLL")) ImGui::SetScrollY(ImGui::GetScrollMaxY() * (float)atof(t));  // (test)
    ImGui::EndChild();
    if (!g_two_panes) { ImGui::PopID(); return; }
    // the description: the hovered row (mouse) wins, else the selected one (controller), else the last shown, else the
    // page's first row
    if (!g_name_hover.empty()) g_desc_shown = g_desc_hover, g_name_shown = g_name_hover, g_img_shown = g_img_hover;
    else if (!g_name_focus.empty()) g_desc_shown = g_desc_focus, g_name_shown = g_name_focus, g_img_shown = g_img_focus;
    else if (g_name_shown.empty()) g_desc_shown = g_desc_first, g_name_shown = g_name_first, g_img_shown = DescImage();
    bool live = false;  // (a picture whose row is gone may have been freed)
    for (unsigned long long t : g_img_live) live |= t == g_img_shown.tex;
    if (!live) g_img_shown = DescImage();
    float s = g_scale;
    ImGui::SameLine(0, 0);
    ImVec2 p = ImGui::GetCursorScreenPos(), avail = ImGui::GetContentRegionAvail();
    float gap = 26 * s;
    ImDrawList *dl = ImGui::GetWindowDrawList();
    // (WSword's Glass Slate look: the description in a glass card beside the rows, under the row's name)
    ImVec2 ca(p.x + gap, p.y + 4 * s), cb(p.x + avail.x, p.y + avail.y - 4 * s);
    dl->AddRectFilled(ca, cb, IM_COL32(10, 22, 40, 235), 18 * s);
    dl->AddRect(ca, cb, IM_COL32(35, 65, 95, 255), 18 * s, 0, 1.3f * s);
    ImGui::SetCursorScreenPos(ImVec2(p.x + gap, p.y));
    ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(26 * s, 22 * s));
    ImGui::PushStyleColor(ImGuiCol_ChildBg, ImVec4(0, 0, 0, 0));
    ImGui::BeginChild("##desc", ImVec2(0, avail.y), ImGuiChildFlags_AlwaysUseWindowPadding, ImGuiWindowFlags_NoNav);
    ImGui::PopStyleColor();
    ImGui::PopStyleVar();
    dl = ImGui::GetWindowDrawList();
    ImGui::PushTextWrapPos(0);
    ImGui::TextColored(ImVec4(0.918f, 0.949f, 0.98f, 1), "%s", g_name_shown.c_str());
    ImGui::PopTextWrapPos();
    {
        ImVec2 q = ImGui::GetCursorScreenPos();
        float w = ImGui::GetContentRegionAvail().x, y = q.y + 8 * s;
        dl->AddLine(ImVec2(q.x, y), ImVec2(q.x + w, y), IM_COL32(28, 53, 80, 255), 1.2f * s);
        ImGui::Dummy(ImVec2(w, 20 * s));
    }
    if (g_img_shown.tex && g_img_shown.w > 0) {  // the picture of the selected row, above its text
        ImVec2 at = ImGui::GetCursorScreenPos();
        float w = ImGui::GetContentRegionAvail().x, h = w * g_img_shown.h / g_img_shown.w;
        ImGui::Dummy(ImVec2(w, h + 8 * s));
        dl->AddImageRounded((ImTextureID)g_img_shown.tex, at, ImVec2(at.x + w, at.y + h), ImVec2(0, 0), ImVec2(1, 1),
                            IM_COL32_WHITE, 8 * s);
    }
    ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(0.73f, 0.80f, 0.86f, 1));
    ImGui::PushTextWrapPos(0);
    ImGui::TextUnformatted(g_desc_shown.c_str());
    ImGui::PopTextWrapPos();
    ImGui::PopStyleColor();
    ImGui::EndChild();
    ImGui::PopID();
}
