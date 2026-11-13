// (WSword) The amiibo bar: while the game looks for a figure (the amiibo rune, runtime/amiibo.h) a row of every
// amiibo across the middle of the screen, in the look of the game's own weapon and rune bars - square slots, the
// figure's name above, white corner brackets on the chosen one, the stick's hint below. The player's favourites
// first, then Breath of the Wild's figures, the rest of the Zelda series and every other amiibo by series.
//
//   R stick / d-pad left, right   the next figure (held: on and on, faster)
//   d-pad down, up                 the next / previous series
//   A                              tap the figure: the game finds it
//   X                              favourite on / off
//   B                              the game's own: it leaves the amiibo rune, and the bar goes
//
// A figure tapped today (with the game's once-a-day rule on) shows amber brackets and a clock; it can still be
// tapped - the game itself says no.
#include <float.h>
#include <math.h>
#include <stdio.h>
#include <string.h>
#include <string>
#include <vector>

#include "imgui.h"

#include "../amiibo.h"
#include "menu.h"
#include "option_rows.h"

// ------------------------------------------------------------------ state
namespace {
std::vector<int> g_order;   // indices into amiibo_at, as shown (favourites first)
int g_nfav;
int g_sel;
bool g_was_up;
double g_open_at;
float g_scroll;             // the row's position, gliding to g_sel
int g_rep_dir;              // the stick held to one side: its direction, and when it moves next
double g_rep_next;
double g_fav_flash_at = -10;
bool g_fav_flash_on;

void build_order(uint64_t keep) {
    g_order.clear();
    uint64_t fav[64];
    g_nfav = amiibo_favourites(fav, 64);
    for (int i = 0; i < g_nfav; i++) {
        int k = amiibo_index(fav[i]);
        if (k >= 0) g_order.push_back(k);
    }
    g_nfav = (int)g_order.size();
    for (int i = 0; i < amiibo_count(); i++) {
        bool f = false;
        for (int j = 0; j < g_nfav; j++) if (g_order[j] == i) f = true;
        if (!f) g_order.push_back(i);
    }
    g_sel = 0;
    if (keep) {
        int at = amiibo_index(keep);
        // the same figure, in its favourite place if it has one
        for (int i = 0; i < (int)g_order.size(); i++) if (g_order[i] == at) { g_sel = i; break; }
    }
}

int group_of(int pos) { return pos < g_nfav ? -1 : amiibo_at(g_order[pos])->group; }

std::string initials(const char *name) {
    std::string out;
    bool start = true;
    for (const char *p = name; *p && out.size() < 2; p++) {
        unsigned char c = (unsigned char)*p;
        if (c == ' ' || c == '-' || c == '&' || c == '(' || c == '.') { start = true; continue; }
        if (start && c < 0x80) out += (char)(c >= 'a' && c <= 'z' ? c - 32 : c);
        start = false;
    }
    return out.empty() ? std::string("?") : out;
}

ImU32 group_colour(int g) {   // (the ring: the Zelda series green, the others from a set of their own)
    static const ImU32 pal[] = {IM_COL32(159, 211, 168, 255), IM_COL32(242, 196, 110, 255), IM_COL32(140, 196, 240, 255),
                                IM_COL32(236, 150, 150, 255), IM_COL32(196, 168, 236, 255), IM_COL32(240, 220, 120, 255),
                                IM_COL32(150, 220, 220, 255), IM_COL32(236, 170, 210, 255)};
    return g == 0 ? pal[0] : pal[1 + (g * 7) % 7];
}

ImU32 fade(ImU32 c, float a) {
    int al = (int)((c >> IM_COL32_A_SHIFT & 0xff) * (a < 0 ? 0 : a > 1 ? 1 : a) + 0.5f);
    return (c & ~IM_COL32_A_MASK) | ((ImU32)al << IM_COL32_A_SHIFT);
}
float ease(float x) { x = x < 0 ? 0 : x > 1 ? 1 : x; float u = 1 - x; return 1 - u * u * u; }

void corner_brackets(ImDrawList *dl, ImVec2 a, ImVec2 b, float len, float t, ImU32 c) {
    dl->AddLine(ImVec2(a.x, a.y), ImVec2(a.x + len, a.y), c, t), dl->AddLine(ImVec2(a.x, a.y), ImVec2(a.x, a.y + len), c, t);
    dl->AddLine(ImVec2(b.x, a.y), ImVec2(b.x - len, a.y), c, t), dl->AddLine(ImVec2(b.x, a.y), ImVec2(b.x, a.y + len), c, t);
    dl->AddLine(ImVec2(a.x, b.y), ImVec2(a.x + len, b.y), c, t), dl->AddLine(ImVec2(a.x, b.y), ImVec2(a.x, b.y - len), c, t);
    dl->AddLine(ImVec2(b.x, b.y), ImVec2(b.x - len, b.y), c, t), dl->AddLine(ImVec2(b.x, b.y), ImVec2(b.x, b.y - len), c, t);
}

void star(ImDrawList *dl, ImVec2 c, float r, ImU32 col) {
    ImVec2 pts[10];
    for (int i = 0; i < 10; i++) {
        float a = -1.5708f + i * 0.6283f, rr = i % 2 ? r * 0.45f : r;
        pts[i] = ImVec2(c.x + cosf(a) * rr, c.y + sinf(a) * rr);
    }
    dl->AddConcavePolyFilled(pts, 10, col);
}

void clock_badge(ImDrawList *dl, ImVec2 c, float r, ImU32 col) {
    dl->AddCircleFilled(c, r, IM_COL32(29, 29, 32, 255), 20);
    dl->AddCircle(c, r * 0.8f, col, 20, r * 0.18f);
    dl->AddLine(c, ImVec2(c.x, c.y - r * 0.5f), col, r * 0.18f);
    dl->AddLine(c, ImVec2(c.x + r * 0.35f, c.y + r * 0.2f), col, r * 0.18f);
}

// a button's mark for the prompts: the PS5's shapes on the console, the Switch's letters (the game's own) elsewhere
void button_mark(ImDrawList *dl, ImFont *f, ImVec2 c, float r, int which, ImU32 col) {   // 0 A, 1 B, 2 X
    dl->AddCircle(c, r, col, 24, r * 0.12f);
#ifdef __PROSPERO__
    float k = r * 0.5f, w = r * 0.16f;
    if (which == 0) dl->AddLine(ImVec2(c.x - k, c.y - k), ImVec2(c.x + k, c.y + k), col, w), dl->AddLine(ImVec2(c.x - k, c.y + k), ImVec2(c.x + k, c.y - k), col, w);
    else if (which == 1) dl->AddCircle(c, k, col, 20, w);
    else dl->AddRect(ImVec2(c.x - k * 0.8f, c.y - k * 0.8f), ImVec2(c.x + k * 0.8f, c.y + k * 0.8f), col, 0, 0, w);
    (void)f;
#else
    const char *t = which == 0 ? "A" : which == 1 ? "B" : "X";
    float fs = r * 1.2f;
    ImVec2 ts = f->CalcTextSizeA(fs, FLT_MAX, 0, t);
    dl->AddText(f, fs, ImVec2(c.x - ts.x * 0.5f, c.y - ts.y * 0.5f), col, t);
#endif
}
}  // namespace

extern "C" bool amiibo_bar_up(void) { return amiibo_waiting() && !menu_is_open(); }

bool amiibo_bar_visible(void) { return amiibo_bar_up() || g_was_up; }

// Each frame the bar is up (ui/menu.mm menu_render)
void amiibo_bar_draw(ImGuiIO &io, float scale, ImFont *font) {
    bool up = amiibo_bar_up();
    double now = ImGui::GetTime();
    if (up && !g_was_up) {   // opened: on the figure tapped last
        build_order(amiibo_last());
        g_open_at = now, g_scroll = (float)g_sel, g_rep_dir = 0;
        amiibo_bar_input_pressed();   // (what was pressed before is not for the bar)
    }
    g_was_up = up;
    if (!up || g_order.empty()) return;
    int n = (int)g_order.size();
    // the controls
    uint64_t held = amiibo_bar_input_held(), pressed = amiibo_bar_input_pressed();
    enum { A = 1 << 0, X = 1 << 2, LEFT = 1 << 12, UP = 1 << 13, RIGHT = 1 << 14, DOWN = 1 << 15 };
    int step = 0;
    if (pressed & LEFT) step = -1;
    if (pressed & RIGHT) step = 1;
    float rx = amiibo_bar_input_rx() / 32767.0f;
    int dir = rx > 0.5f ? 1 : rx < -0.5f ? -1 : (held & LEFT) ? -1 : (held & RIGHT) ? 1 : 0;
    if (dir != g_rep_dir) {
        if (dir && !step && rx * dir > 0.5f) step = dir;   // (the stick's flick: one figure)
        g_rep_dir = dir, g_rep_next = now + 0.32;
    } else if (dir && now >= g_rep_next) {
        step = dir, g_rep_next = now + 0.075;   // (held: on and on)
    }
    if (step) g_sel = (g_sel + step + n) % n;
    if (pressed & (UP | DOWN)) {   // the next / previous series
        int g = group_of(g_sel), i = g_sel, d = (pressed & DOWN) ? 1 : -1;
        if (d > 0) { while (i < n && group_of(i) == g) i++; if (i >= n) i = 0; }
        else {
            while (i > 0 && group_of(i - 1) == g) i--;   // (to its first; then the one before's first)
            if (i == g_sel || i == 0) { i = i == 0 ? n - 1 : i - 1; int h = group_of(i); while (i > 0 && group_of(i - 1) == h) i--; }
        }
        g_sel = i;
    }
    const AmiiboDef *cur = amiibo_at(g_order[g_sel]);
    if (pressed & X) {   // favourite on / off: the bar's order follows, the cursor stays on the figure
        bool on = !amiibo_favourite(cur->id);
        amiibo_set_favourite(cur->id, on);
        build_order(cur->id);
        g_scroll = (float)g_sel;
        g_fav_flash_at = now, g_fav_flash_on = on;
        cur = amiibo_at(g_order[g_sel]);
    }
    if (pressed & A) {
        amiibo_tap(cur->id);
        return;
    }
    // drawing
    float k = io.DeltaTime > 0 ? 1 - expf(-io.DeltaTime * 18) : 1;
    float d = (float)g_sel - g_scroll;
    if (fabsf(d) > n / 2.0f) g_scroll += d > 0 ? n : -n;   // (wrapped around: glide the short way)
    g_scroll += ((float)g_sel - g_scroll) * k;
    if (fabsf(g_scroll - g_sel) < 0.001f) g_scroll = (float)g_sel;
    float a = ease((float)(now - g_open_at) / 0.18f);
    float s = scale, W = io.DisplaySize.x, H = io.DisplaySize.y;
    float slot = 96 * s, gap = 12 * s, cy = H * 0.40f, cx = W * 0.5f;
    ImDrawList *dl = ImGui::GetForegroundDrawList();
    ImFont *f = font ? font : ImGui::GetFont();
    bool used = amiibo_used_today(cur->id);
    const ImU32 white = IM_COL32(242, 242, 243, 255), amber = IM_COL32(240, 184, 90, 255);
    // the name above
    float nfs = 30 * s;
    ImVec2 ns = f->CalcTextSizeA(nfs, FLT_MAX, 0, cur->name);
    float ny = cy - slot * 0.5f - 22 * s - ns.y;
    dl->AddText(f, nfs, ImVec2(cx - ns.x * 0.5f + 1.5f * s, ny + 1.5f * s), fade(IM_COL32(0, 0, 0, 170), a), cur->name);
    dl->AddText(f, nfs, ImVec2(cx - ns.x * 0.5f, ny), fade(used ? IM_COL32(216, 216, 220, 255) : white, a), cur->name);
    // the slots: those that fit beside the chosen one, fading at the ends
    int side = (int)((W * 0.36f) / (slot + gap));
    for (int o = -side - 1; o <= side + 1; o++) {
        int pos = ((int)floorf(g_scroll + 0.5f) + o) % n;
        if (pos < 0) pos += n;
        float x = cx + ((float)((int)floorf(g_scroll + 0.5f) + o) - g_scroll) * (slot + gap);
        float edge = fabsf(x - cx) / ((side + 0.5f) * (slot + gap));
        float sa = a * (edge > 1 ? 0 : edge > 0.7f ? 1 - (edge - 0.7f) / 0.3f * 0.75f : 1);
        if (sa <= 0.01f) continue;
        const AmiiboDef *fig = amiibo_at(g_order[pos]);
        bool sel = pos == g_sel, fav = pos < g_nfav, u = amiibo_used_today(fig->id);
        ImVec2 p0(x - slot * 0.5f, cy - slot * 0.5f), p1(x + slot * 0.5f, cy + slot * 0.5f);
        dl->AddRectFilled(p0, p1, fade(IM_COL32(29, 29, 32, sel ? 222 : 184), sa));
        dl->AddRect(p0, p1, fade(sel ? IM_COL32(255, 255, 255, 200) : IM_COL32(255, 255, 255, 52), sa), 0, 0, 1.2f * s);
        ImU32 ring = u ? IM_COL32(125, 138, 127, 255) : group_colour(fig->group);
        dl->AddCircle(ImVec2(x, cy), slot * 0.31f, fade(ring, sa), 40, 2.8f * s);
        std::string ini = initials(fig->name);
        float ifs = slot * 0.24f;
        ImVec2 is = f->CalcTextSizeA(ifs, FLT_MAX, 0, ini.c_str());
        dl->AddText(f, ifs, ImVec2(x - is.x * 0.5f, cy - is.y * 0.5f), fade(u ? IM_COL32(161, 161, 168, 255) : white, sa), ini.c_str());
        if (fav) star(dl, ImVec2(p0.x + 13 * s, p0.y + 13 * s), 7 * s, fade(IM_COL32(240, 210, 122, 255), sa));
        if (u) clock_badge(dl, ImVec2(p1.x - 14 * s, p1.y - 14 * s), 10 * s, fade(amber, sa));
        if (sel) corner_brackets(dl, ImVec2(p0.x - 7 * s, p0.y - 7 * s), ImVec2(p1.x + 7 * s, p1.y + 7 * s), 18 * s, 3 * s,
                                 fade(u ? amber : IM_COL32(255, 255, 255, 255), a));
        // a thin line where the favourites end
        if (pos == g_nfav - 1 && g_nfav > 0 && g_nfav < n)
            dl->AddLine(ImVec2(p1.x + gap * 0.5f, cy - slot * 0.4f), ImVec2(p1.x + gap * 0.5f, cy + slot * 0.4f), fade(IM_COL32(255, 255, 255, 128), sa), 2 * s);
    }
    // the stick's hint below, then the series and the state
    float hy = cy + slot * 0.5f + 26 * s, hr = 14 * s;
    dl->AddCircleFilled(ImVec2(cx, hy), hr, fade(white, a), 24);
    ImVec2 rs = f->CalcTextSizeA(hr * 1.2f, FLT_MAX, 0, "R");
    dl->AddText(f, hr * 1.2f, ImVec2(cx - rs.x * 0.5f, hy - rs.y * 0.5f), fade(IM_COL32(29, 29, 32, 255), a), "R");
    for (int sgn = -1; sgn <= 1; sgn += 2) {
        float ax = cx + sgn * (hr + 9 * s), t = 5 * s;
        dl->AddTriangleFilled(ImVec2(ax + sgn * t, hy), ImVec2(ax, hy - t), ImVec2(ax, hy + t), fade(white, a));
    }
    char line[200];
    const char *grp = g_sel < g_nfav ? "Favourites" : amiibo_group_name(cur->group);
    int gfirst = g_sel, glast = g_sel;
    while (gfirst > 0 && group_of(gfirst - 1) == group_of(g_sel)) gfirst--;
    while (glast < n - 1 && group_of(glast + 1) == group_of(g_sel)) glast++;
    snprintf(line, sizeof line, "%s  \xc2\xb7  %d of %d  \xc2\xb7  %s", grp, g_sel - gfirst + 1, glast - gfirst + 1,
             used ? "tapped today: the game takes each figure once a day" : "ready");
    if (now - g_fav_flash_at < 1.6)
        snprintf(line, sizeof line, "%s", g_fav_flash_on ? "Added to your favourites: first in the bar" : "Taken out of your favourites");
    float lfs = 19 * s;
    ImVec2 ls = f->CalcTextSizeA(lfs, FLT_MAX, 0, line);
    float ly = hy + hr + 12 * s;
    dl->AddText(f, lfs, ImVec2(cx - ls.x * 0.5f + 1.2f * s, ly + 1.2f * s), fade(IM_COL32(0, 0, 0, 190), a), line);
    dl->AddText(f, lfs, ImVec2(cx - ls.x * 0.5f, ly), fade(used && now - g_fav_flash_at >= 1.6 ? IM_COL32(246, 207, 138, 255) : white, a), line);
    // the prompts: a strip along the bottom
    struct P { int mark; const char *label; } pr[] = {{-1, "Series"}, {0, "Tap"}, {2, amiibo_favourite(cur->id) ? "Unfavourite" : "Favourite"}, {1, "Cancel"}};
    float pfs = 19 * s, py = H - 64 * s, total = 0, pr_r = 13 * s;
    float widths[4];
    for (int i = 0; i < 4; i++) widths[i] = 2 * pr_r + 10 * s + f->CalcTextSizeA(pfs, FLT_MAX, 0, pr[i].label).x, total += widths[i];
    total += 34 * s * 3;
    dl->AddRectFilled(ImVec2(cx - total * 0.5f - 26 * s, py - 24 * s), ImVec2(cx + total * 0.5f + 26 * s, py + 24 * s), fade(IM_COL32(10, 10, 11, 178), a), 24 * s);
    float x = cx - total * 0.5f;
    for (int i = 0; i < 4; i++) {
        ImVec2 c(x + pr_r, py);
        if (pr[i].mark < 0) {   // the d-pad's up / down
            float t = 6 * s;
            dl->AddTriangleFilled(ImVec2(c.x, c.y - pr_r), ImVec2(c.x - t, c.y - pr_r + t * 1.2f), ImVec2(c.x + t, c.y - pr_r + t * 1.2f), fade(white, a));
            dl->AddTriangleFilled(ImVec2(c.x, c.y + pr_r), ImVec2(c.x - t, c.y + pr_r - t * 1.2f), ImVec2(c.x + t, c.y + pr_r - t * 1.2f), fade(white, a));
        } else button_mark(dl, f, c, pr_r, pr[i].mark, fade(white, a));
        dl->AddText(f, pfs, ImVec2(x + 2 * pr_r + 10 * s, py - pfs * 0.55f), fade(IM_COL32(220, 220, 224, 255), a), pr[i].label);
        x += widths[i] + 34 * s;
    }
}

// The amiibo rows of WSword's settings (Controls)
void amiibo_settings_rows(void) {
    opt_section("amiibo");
    bool daily = amiibo_daily();
    if (opt_toggle("One scan a day per figure", &daily, true,
                   "The game's own rule: each amiibo gives its items once a day. Off, every tap is a new figure to the "
                   "game, as many times as you like."))
        amiibo_set_daily(daily);
    uint64_t fav[64];
    int nf = amiibo_favourites(fav, 64);
    char v[48];
    snprintf(v, sizeof v, nf == 1 ? "1 figure" : "%d figures", nf);
    if (opt_action("Clear favourites", v, "Your favourites come first in the amiibo bar. Add or take one out there with "
                   "X (Square on the PS5). This empties the list.", false) && nf)
        amiibo_clear_favourites();
    opt_action("Open the amiibo bar", "amiibo rune", "Choose the amiibo rune and use it, as with a figure: the bar of "
               "every amiibo comes up. Pick one with the right stick and tap it with A (Cross on the PS5).", false);
}
