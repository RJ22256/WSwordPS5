// (WSword) The amiibo bar: while the game looks for a figure (the amiibo rune, runtime/amiibo.h) a row of every
// amiibo across the screen, made as the game's own weapon, bow, shield and rune bars are - translucent dark square
// slots on a faint band, the chosen one in white corner brackets that spring into place, the figure's name above it in
// italics over a dotted rule, the right stick's mark under it - with their motion (the row gliding, the bar easing in
// and out) and their ticks (ui sounds made here: a click a step, a chime for the tap). The player's favourites first,
// then Breath of the Wild's figures, the rest of the Zelda series and every other amiibo by series. (No Nintendo
// artwork: each slot draws a figure on its stand in its series' colour, and its initials in the game's count badge.)
//
//   R stick / d-pad left, right   the next figure (held: on and on, faster)
//   d-pad down, up                 the next / previous series
//   A                              tap the figure: the game finds it
//   X                              favourite on / off
//   B                              the game's own: it leaves the amiibo rune, and the bar goes
//
// A figure tapped today (with the game's once-a-day rule on) shows amber brackets and a clock; it can still be
// tapped - the game itself says no.
//
// Android (the tablet): the bar by touch too - drag the row to scroll it, touch a figure to choose it and touch the
// chosen one again to tap it; the prompts are buttons (Series: its top half the previous, its bottom half the next;
// Cancel presses the game's B). ui/touch_controls.mm hands the bar the fingers that land on it
// (amiibo_bar_touch_event).
#include <float.h>
#include <math.h>
#include <stdio.h>
#include <string.h>
#include <atomic>
#include <mutex>
#include <string>
#include <vector>

#include <SDL3/SDL.h>

#include "imgui.h"

#include "../amiibo.h"
#include "menu.h"
#include "option_rows.h"
extern "C" {
#include "../settings.h"
}

// ------------------------------------------------------------------ the bar's sounds
// Short UI sounds in the manner of the game's selector: a soft wooden click each step, a lighter one for a series, a
// rising pair for a favourite (falling: taken out), a bright two-note chime for the tap, a breath of air as the bar
// opens. Made here (no game audio is copied), 48 kHz stereo, played on a stream of their own at the game's volume.
namespace {
enum { SND_OPEN, SND_STEP, SND_SERIES, SND_FAV_ON, SND_FAV_OFF, SND_TAP };
SDL_AudioStream *g_snd_stream;
bool g_snd_tried;
std::mutex g_snd_mu;

void tone(std::vector<float> &b, float start_s, float freq, float len_s, float amp, float decay, float freq_end = -1) {
    const float sr = 48000;
    int s0 = (int)(start_s * sr), n = (int)(len_s * sr);
    if ((int)b.size() < s0 + n) b.resize(s0 + n, 0);
    float ph = 0;
    for (int i = 0; i < n; i++) {
        float t = i / sr, f = freq_end > 0 ? freq + (freq_end - freq) * (t / len_s) : freq;
        ph += 6.2831853f * f / sr;
        float env = expf(-t * decay) * fminf(1.0f, t * 2000);   // (a 0.5 ms attack: no click of its own)
        b[s0 + i] += sinf(ph) * amp * env;
    }
}
void noise(std::vector<float> &b, float len_s, float amp) {   // a breath: filtered noise, swelling and fading
    const float sr = 48000;
    int n = (int)(len_s * sr);
    if ((int)b.size() < n) b.resize(n, 0);
    uint32_t r = 0x9e3779b9u;
    float lp = 0, lp2 = 0;
    for (int i = 0; i < n; i++) {
        r ^= r << 13, r ^= r >> 17, r ^= r << 5;
        float w = (float)(r & 0xffff) / 32768.0f - 1, t = (float)i / n;
        float cut = 0.04f + 0.10f * t;   // (opening up as it goes)
        lp += (w - lp) * cut, lp2 += (lp - lp2) * cut;
        b[i] += lp2 * amp * sinf(3.14159f * t) * 3.0f;
    }
}
void play(int which) {
    std::lock_guard<std::mutex> l(g_snd_mu);
    if (!g_snd_stream && !g_snd_tried) {
        g_snd_tried = true;
        SDL_AudioSpec spec = {SDL_AUDIO_F32, 2, 48000};
        g_snd_stream = SDL_OpenAudioDeviceStream(SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK, &spec, NULL, NULL);
        if (g_snd_stream) SDL_ResumeAudioStreamDevice(g_snd_stream);
    }
    if (!g_snd_stream) return;
    std::vector<float> m;
    switch (which) {
    case SND_OPEN: noise(m, 0.16f, 0.22f); tone(m, 0.02f, 1320, 0.09f, 0.05f, 40); break;
    case SND_STEP: tone(m, 0, 2350, 0.045f, 0.30f, 140); tone(m, 0, 1180, 0.05f, 0.16f, 110); break;
    case SND_SERIES: tone(m, 0, 1760, 0.05f, 0.26f, 120); tone(m, 0.035f, 2350, 0.05f, 0.22f, 120); break;
    case SND_FAV_ON: tone(m, 0, 1568, 0.09f, 0.20f, 45); tone(m, 0.06f, 2093, 0.14f, 0.20f, 30); break;
    case SND_FAV_OFF: tone(m, 0, 2093, 0.09f, 0.18f, 45); tone(m, 0.06f, 1568, 0.14f, 0.18f, 30); break;
    case SND_TAP:
        tone(m, 0, 1319, 0.30f, 0.20f, 12); tone(m, 0.07f, 1976, 0.40f, 0.20f, 9);
        tone(m, 0.07f, 3952, 0.25f, 0.05f, 16);
        break;
    }
    float vol = g_settings.volume > 0 ? fminf(g_settings.volume, 2.0f) : 0;
    std::vector<float> st(m.size() * 2);
    for (size_t i = 0; i < m.size(); i++) st[2 * i] = st[2 * i + 1] = fmaxf(-1, fminf(1, m[i] * vol));
    SDL_ClearAudioStream(g_snd_stream);   // (a new tick cuts the last one short, as the game's do)
    SDL_PutAudioStreamData(g_snd_stream, st.data(), (int)(st.size() * sizeof(float)));
}

// ------------------------------------------------------------------ state
std::vector<int> g_order;   // indices into amiibo_at, as shown (favourites first)
int g_nfav;
int g_sel, g_last_sel = -1;
bool g_was_up;
double g_open_at, g_sel_at = -10, g_close_at = -10;
float g_scroll;             // the row's position, gliding to g_sel
int g_rep_dir;              // the stick held to one side: its direction, and when it moves next
double g_rep_next;
double g_fav_flash_at = -10;
bool g_fav_flash_on;
uint64_t g_tapped;          // the figure just tapped (the bar fades out with it lit)
std::string g_name_prev;    // the name before the last step (it fades out under the new one)

#ifdef __ANDROID__
// touch: the event thread queues the fingers that land on the bar; the render thread (amiibo_bar_draw) plays them
struct TouchEv { int kind; float x, y; };   // 0 down, 1 move, 2 up, 3 cancelled
std::mutex g_tmu;
std::vector<TouchEv> g_tq;
bool g_tdown;
SDL_FingerID g_tfinger;
ImVec2 g_lay0, g_lay1;                      // the bar's area as last drawn (g_tmu); g_lay_on: drawn
bool g_lay_on;
// the render thread's own: the finger's start, the row's position then, whether it has moved (a drag)
ImVec2 g_t0;
float g_tbase;
bool g_tmoved;
ImVec4 g_prompt_rect[4];                    // the prompts as last drawn (x0, y0, x1, y1)
std::atomic<double> g_inject_b_until{0};    // Cancel: the game's B held until then (ImGui's clock)
std::atomic<double> g_now{0};
#endif

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
        for (int i = 0; i < (int)g_order.size(); i++) if (g_order[i] == at) { g_sel = i; break; }
    }
}

int group_of(int pos) { return pos < g_nfav ? -1 : amiibo_at(g_order[pos])->group; }
bool is_card(uint64_t id) { return ((id >> 32) & 0xff) == 0x01; }   // (the id's type byte: 00 figure, 01 card, 02 yarn)

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

ImU32 group_colour(int g) {   // (a figure's paint: the Zelda series green, the others from a set of their own)
    static const ImU32 pal[] = {IM_COL32(125, 186, 140, 255), IM_COL32(222, 170, 92, 255), IM_COL32(112, 168, 222, 255),
                                IM_COL32(214, 120, 118, 255), IM_COL32(170, 140, 218, 255), IM_COL32(222, 198, 96, 255),
                                IM_COL32(110, 196, 196, 255), IM_COL32(218, 140, 186, 255)};
    return g == 0 ? pal[0] : pal[1 + (g * 7) % 7];
}

ImU32 fade(ImU32 c, float a) {
    int al = (int)((c >> IM_COL32_A_SHIFT & 0xff) * (a < 0 ? 0 : a > 1 ? 1 : a) + 0.5f);
    return (c & ~IM_COL32_A_MASK) | ((ImU32)al << IM_COL32_A_SHIFT);
}
ImU32 shade(ImU32 c, float k) {   // darker (k < 1) or lighter (k > 1)
    int r = (int)((c >> IM_COL32_R_SHIFT & 0xff) * k), g = (int)((c >> IM_COL32_G_SHIFT & 0xff) * k), b = (int)((c >> IM_COL32_B_SHIFT & 0xff) * k);
    r = r > 255 ? 255 : r, g = g > 255 ? 255 : g, b = b > 255 ? 255 : b;
    return IM_COL32(r, g, b, c >> IM_COL32_A_SHIFT & 0xff);
}
float ease(float x) { x = x < 0 ? 0 : x > 1 ? 1 : x; float u = 1 - x; return 1 - u * u * u; }
float ease_back(float x) {   // a small overshoot (the brackets springing onto a slot)
    x = x < 0 ? 0 : x > 1 ? 1 : x;
    const float c1 = 1.9f, c3 = c1 + 1;
    return 1 + c3 * powf(x - 1, 3) + c1 * powf(x - 1, 2);
}

// Text in the game's slanted style: drawn, then its vertices sheared to the right (ImGui has no italic)
void text_italic(ImDrawList *dl, ImFont *f, float size, ImVec2 at, ImU32 col, const char *t, float slant = 0.2f) {
    int v0 = dl->VtxBuffer.Size;
    dl->AddText(f, size, at, col, t);
    float base = at.y + size;
    for (int i = v0; i < dl->VtxBuffer.Size; i++) dl->VtxBuffer[i].pos.x += (base - dl->VtxBuffer[i].pos.y) * slant;
}
// Text with the game's soft shadow under it
void text_shadowed(ImDrawList *dl, ImFont *f, float size, ImVec2 at, ImU32 col, float a, const char *t, bool italic, float s) {
    for (int k = 0; k < 2; k++) {
        ImVec2 o(at.x + (k ? 1.6f : 0.8f) * s, at.y + (k ? 1.6f : 0.8f) * s);
        if (italic) text_italic(dl, f, size, o, fade(IM_COL32(0, 0, 0, k ? 70 : 120), a), t);
        else dl->AddText(f, size, o, fade(IM_COL32(0, 0, 0, k ? 70 : 120), a), t);
    }
    if (italic) text_italic(dl, f, size, at, fade(col, a), t);
    else dl->AddText(f, size, at, fade(col, a), t);
}

void brackets(ImDrawList *dl, ImVec2 a, ImVec2 b, float len, float t, ImU32 c) {   // white L-shaped corners
    dl->AddRectFilled(ImVec2(a.x, a.y), ImVec2(a.x + len, a.y + t), c), dl->AddRectFilled(ImVec2(a.x, a.y), ImVec2(a.x + t, a.y + len), c);
    dl->AddRectFilled(ImVec2(b.x - len, a.y), ImVec2(b.x, a.y + t), c), dl->AddRectFilled(ImVec2(b.x - t, a.y), ImVec2(b.x, a.y + len), c);
    dl->AddRectFilled(ImVec2(a.x, b.y - t), ImVec2(a.x + len, b.y), c), dl->AddRectFilled(ImVec2(a.x, b.y - len), ImVec2(a.x + t, b.y), c);
    dl->AddRectFilled(ImVec2(b.x - len, b.y - t), ImVec2(b.x, b.y), c), dl->AddRectFilled(ImVec2(b.x - t, b.y - len), ImVec2(b.x, b.y), c);
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
    dl->AddCircleFilled(c, r, IM_COL32(20, 18, 16, 235), 20);
    dl->AddCircle(c, r * 0.78f, col, 20, r * 0.16f);
    dl->AddLine(c, ImVec2(c.x, c.y - r * 0.48f), col, r * 0.16f);
    dl->AddLine(c, ImVec2(c.x + r * 0.34f, c.y + r * 0.18f), col, r * 0.16f);
}

// A slot's picture: a figure on its round stand (a card for the cards), in its series' paint, lit from above
void figure_icon(ImDrawList *dl, ImVec2 c, float sz, ImU32 paint, bool card, float a, bool dim) {
    ImU32 p = fade(dim ? shade(paint, 0.55f) : paint, a), dark = fade(shade(paint, dim ? 0.3f : 0.55f), a);
    ImU32 lite = fade(dim ? shade(paint, 0.7f) : shade(paint, 1.25f), a);
    if (card) {
        ImVec2 a0(c.x - sz * 0.27f, c.y - sz * 0.36f), a1(c.x + sz * 0.27f, c.y + sz * 0.36f);
        dl->AddRectFilled(ImVec2(a0.x + sz * 0.03f, a0.y + sz * 0.03f), ImVec2(a1.x + sz * 0.03f, a1.y + sz * 0.03f), fade(IM_COL32(0, 0, 0, 90), a), sz * 0.05f);
        dl->AddRectFilled(a0, a1, fade(IM_COL32(236, 230, 214, 255), a * (dim ? 0.6f : 1)), sz * 0.05f);
        dl->AddRectFilled(ImVec2(a0.x + sz * 0.04f, a0.y + sz * 0.04f), ImVec2(a1.x - sz * 0.04f, c.y + sz * 0.12f), p, sz * 0.03f);
        dl->AddCircleFilled(ImVec2(c.x, c.y - sz * 0.10f), sz * 0.09f, lite, 20);
        dl->AddRectFilled(ImVec2(a0.x + sz * 0.06f, c.y + sz * 0.19f), ImVec2(a1.x - sz * 0.06f, c.y + sz * 0.23f), dark, sz * 0.02f);
        return;
    }
    // the stand: a disc seen from the front, its rim lighter
    float by = c.y + sz * 0.30f;
    dl->AddEllipseFilled(ImVec2(c.x, by + sz * 0.035f), ImVec2(sz * 0.30f, sz * 0.085f), fade(IM_COL32(0, 0, 0, 110), a), 0, 28);
    dl->AddEllipseFilled(ImVec2(c.x, by), ImVec2(sz * 0.29f, sz * 0.08f), fade(IM_COL32(58, 54, 50, 255), a), 0, 28);
    dl->AddEllipse(ImVec2(c.x, by), ImVec2(sz * 0.29f, sz * 0.08f), fade(IM_COL32(120, 112, 104, 255), a), 0, 28, sz * 0.015f);
    // the figure: legs, body, arms, head
    float hy = c.y - sz * 0.22f, hr = sz * 0.105f;
    dl->AddRectFilled(ImVec2(c.x - sz * 0.075f, c.y + sz * 0.10f), ImVec2(c.x - sz * 0.02f, by), dark, sz * 0.02f);
    dl->AddRectFilled(ImVec2(c.x + sz * 0.02f, c.y + sz * 0.10f), ImVec2(c.x + sz * 0.075f, by), dark, sz * 0.02f);
    ImVec2 body[] = {ImVec2(c.x - sz * 0.09f, hy + hr * 0.9f), ImVec2(c.x + sz * 0.09f, hy + hr * 0.9f),
                     ImVec2(c.x + sz * 0.13f, c.y + sz * 0.13f), ImVec2(c.x - sz * 0.13f, c.y + sz * 0.13f)};
    dl->AddConvexPolyFilled(body, 4, p);
    dl->AddLine(ImVec2(c.x - sz * 0.10f, hy + hr * 1.2f), ImVec2(c.x - sz * 0.17f, c.y + sz * 0.06f), p, sz * 0.05f);
    dl->AddLine(ImVec2(c.x + sz * 0.10f, hy + hr * 1.2f), ImVec2(c.x + sz * 0.17f, c.y + sz * 0.06f), p, sz * 0.05f);
    dl->AddLine(ImVec2(c.x - sz * 0.05f, hy + hr * 1.1f), ImVec2(c.x - sz * 0.07f, c.y + sz * 0.10f), lite, sz * 0.02f);
    dl->AddCircleFilled(ImVec2(c.x, hy), hr, p, 24);
    dl->AddCircleFilled(ImVec2(c.x - hr * 0.3f, hy - hr * 0.3f), hr * 0.38f, fade(IM_COL32(255, 255, 255, 60), a * (dim ? 0.5f : 1)), 16);
}

// The game's count badge (black, rounded, white text) at a slot's bottom right: here, the figure's initials
void count_badge(ImDrawList *dl, ImFont *f, ImVec2 slot_br, float s, const char *t, float a, bool dim) {
    float fs = 21 * s, tw = f->CalcTextSizeA(fs, FLT_MAX, 0, t).x, w = fmaxf(tw + 14 * s, 30 * s), h = 27 * s;
    ImVec2 b1(slot_br.x - 3 * s, slot_br.y - 3 * s), b0(b1.x - w, b1.y - h);
    dl->AddRectFilled(b0, b1, fade(IM_COL32(8, 8, 8, 235), a), 5 * s);
    dl->AddText(f, fs, ImVec2(b0.x + (w - tw) * 0.5f, b0.y + (h - fs) * 0.5f - 0.5f * s), fade(dim ? IM_COL32(170, 170, 170, 255) : IM_COL32(255, 255, 255, 255), a), t);
}

// The right stick's mark under the bar: R in a grey disc in a white ring, a small arrow either side
void stick_mark(ImDrawList *dl, ImFont *f, ImVec2 c, float s, float a) {
    float r = 13 * s;
    dl->AddCircleFilled(c, r + 3 * s, fade(IM_COL32(0, 0, 0, 60), a), 28);
    dl->AddCircle(c, r + 2 * s, fade(IM_COL32(255, 255, 255, 210), a), 28, 1.6f * s);
    dl->AddCircleFilled(c, r - 1 * s, fade(IM_COL32(118, 116, 112, 235), a), 28);
    float fs = 17 * s;
    ImVec2 ts = f->CalcTextSizeA(fs, FLT_MAX, 0, "R");
    dl->AddText(f, fs, ImVec2(c.x - ts.x * 0.5f, c.y - ts.y * 0.5f), fade(IM_COL32(255, 255, 255, 255), a), "R");
    for (int sg = -1; sg <= 1; sg += 2) {
        float x = c.x + sg * (r + 10 * s), t = 5 * s;
        dl->AddTriangleFilled(ImVec2(x + sg * t, c.y), ImVec2(x, c.y - t * 1.1f), ImVec2(x, c.y + t * 1.1f), fade(IM_COL32(255, 255, 255, 230), a));
    }
}

// a button's mark for the prompts: the PS5's shapes on the console, the Switch's letters (the game's own) elsewhere
void button_mark(ImDrawList *dl, ImFont *f, ImVec2 c, float r, int which, ImU32 col) {   // 0 A, 1 B, 2 X
    dl->AddCircleFilled(c, r, fade(IM_COL32(0, 0, 0, 90), (col >> IM_COL32_A_SHIFT & 0xff) / 255.0f), 24);
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

bool amiibo_bar_visible(void) { return amiibo_bar_up() || g_was_up || ImGui::GetCurrentContext() && ImGui::GetTime() - g_close_at < 0.24; }

// Each frame the bar is up (ui/menu.mm menu_render)
void amiibo_bar_draw(ImGuiIO &io, float scale, ImFont *font) {
    bool up = amiibo_bar_up();
    double now = ImGui::GetTime();
    if (up && !g_was_up) {   // opened: on the figure tapped last
        build_order(amiibo_last());
        g_open_at = now, g_scroll = (float)g_sel, g_rep_dir = 0, g_last_sel = g_sel, g_sel_at = -10, g_tapped = 0;
        g_name_prev.clear();
        amiibo_bar_input_pressed();   // (what was pressed before is not for the bar)
        play(SND_OPEN);
    }
    if (!up && g_was_up) g_close_at = now;   // closed (tapped, or the game stopped looking): it fades out
    g_was_up = up;
    if (g_order.empty()) return;
    float closing = up ? 0 : (float)((now - g_close_at) / 0.22);
    if (!up && closing >= 1) return;
    int n = (int)g_order.size();
    float s = scale, W = io.DisplaySize.x, H = io.DisplaySize.y;
    // the game's bar at 1080 lines: 113 px slots, 141 apart, across the screen a little above the middle
    float slot = 113 * s, step_px = 141 * s, cy = H * 0.367f, cx = W * 0.5f;
    if (up) {
        uint64_t held = amiibo_bar_input_held(), pressed = amiibo_bar_input_pressed();
        enum { A = 1 << 0, X = 1 << 2, LEFT = 1 << 12, UP = 1 << 13, RIGHT = 1 << 14, DOWN = 1 << 15 };
#ifdef __ANDROID__
        g_now = now;
        {   // the fingers on the bar: a drag scrolls the row; a touch chooses a figure, the chosen one taps it
            std::vector<TouchEv> q;
            { std::lock_guard<std::mutex> l(g_tmu); q.swap(g_tq); }
            for (const TouchEv &t : q) {
                if (t.kind == 0) { g_t0 = ImVec2(t.x, t.y), g_tbase = g_scroll, g_tmoved = false; continue; }
                float dx = t.x - g_t0.x;
                if (t.kind == 1) {
                    if (!g_tmoved && fabsf(dx) > 14 * s && fabsf(g_t0.y - cy) <= slot) g_tmoved = true;
                    if (g_tmoved) {
                        g_scroll = g_tbase - dx / step_px;
                        g_sel = (((int)floorf(g_scroll + 0.5f)) % n + n) % n;
                    }
                    continue;
                }
                if (t.kind == 3 || g_tmoved) { g_tmoved = false; continue; }
                if (fabsf(t.y - cy) <= slot * 0.5f + 10 * s) {
                    int pos = (((int)floorf(g_scroll + (t.x - cx) / step_px + 0.5f)) % n + n) % n;
                    if (pos == g_sel) pressed |= A;
                    else g_sel = pos;
                    continue;
                }
                for (int i = 0; i < 4; i++) {
                    const ImVec4 &r = g_prompt_rect[i];
                    if (t.x < r.x || t.x > r.z || t.y < r.y || t.y > r.w) continue;
                    if (i == 0) pressed |= t.y < (r.y + r.w) * 0.5f ? UP : DOWN;
                    else if (i == 1) pressed |= A;
                    else if (i == 2) pressed |= X;
                    else g_inject_b_until = now + 0.15;   // (the game's own cancel: it leaves the amiibo rune)
                }
            }
        }
#endif
        int stp = 0;
        if (pressed & LEFT) stp = -1;
        if (pressed & RIGHT) stp = 1;
        float rx = amiibo_bar_input_rx() / 32767.0f;
        int dir = rx > 0.5f ? 1 : rx < -0.5f ? -1 : (held & LEFT) ? -1 : (held & RIGHT) ? 1 : 0;
        if (dir != g_rep_dir) {
            if (dir && !stp && rx * dir > 0.5f) stp = dir;   // (the stick's flick: one figure)
            g_rep_dir = dir, g_rep_next = now + 0.32;
        } else if (dir && now >= g_rep_next) {
            stp = dir, g_rep_next = now + 0.075;   // (held: on and on)
        }
        if (stp) g_sel = (g_sel + stp + n) % n;
        bool series = false;
        if (pressed & (UP | DOWN)) {   // the next / previous series
            int g = group_of(g_sel), i = g_sel, d = (pressed & DOWN) ? 1 : -1;
            if (d > 0) { while (i < n && group_of(i) == g) i++; if (i >= n) i = 0; }
            else {
                while (i > 0 && group_of(i - 1) == g) i--;
                if (i == g_sel || i == 0) { i = i == 0 ? n - 1 : i - 1; int h = group_of(i); while (i > 0 && group_of(i - 1) == h) i--; }
            }
            g_sel = i, series = true;
        }
        const AmiiboDef *cur = amiibo_at(g_order[g_sel]);
        if (pressed & X) {   // favourite on / off: the bar's order follows, the cursor stays on the figure
            bool on = !amiibo_favourite(cur->id);
            amiibo_set_favourite(cur->id, on);
            build_order(cur->id);
            g_scroll = (float)g_sel, g_last_sel = g_sel;
            g_fav_flash_at = now, g_fav_flash_on = on;
            cur = amiibo_at(g_order[g_sel]);
            play(on ? SND_FAV_ON : SND_FAV_OFF);
        }
        if (g_sel != g_last_sel) {   // a step: the brackets spring onto the new slot, the name changes, the tick
            if (g_last_sel >= 0 && g_last_sel < n) g_name_prev = amiibo_at(g_order[g_last_sel])->name;
            g_last_sel = g_sel, g_sel_at = now;
            play(series ? SND_SERIES : SND_STEP);
        }
        if (pressed & A) {
            g_tapped = cur->id;
            play(SND_TAP);
            amiibo_tap(cur->id);   // (the game finds it: the bar fades out with it lit)
        }
    }
    // ---- drawing
    float k = io.DeltaTime > 0 ? 1 - expf(-io.DeltaTime * 20) : 1;
    float d = (float)g_sel - g_scroll;
    if (fabsf(d) > n / 2.0f) g_scroll += d > 0 ? n : -n;   // (wrapped around: glide the short way)
    g_scroll += ((float)g_sel - g_scroll) * k;
    if (fabsf(g_scroll - g_sel) < 0.001f) g_scroll = (float)g_sel;
    float a = ease((float)(now - g_open_at) / 0.16f) * (1 - ease(closing));
    float rise = 10 * s * (1 - ease((float)(now - g_open_at) / 0.2f));
    ImDrawList *dl = ImGui::GetForegroundDrawList();
    ImFont *f = font ? font : ImGui::GetFont();
    const AmiiboDef *cur = amiibo_at(g_order[g_sel]);
    bool used = amiibo_used_today(cur->id);
    const ImU32 white = IM_COL32(255, 255, 255, 255), amber = IM_COL32(240, 184, 90, 255);
    float ccy = cy + rise;
    // the band behind the bar: a faint light haze, as the game's
    int side = 3;
    float bw = (side + 0.36f) * step_px;
    dl->AddRectFilledMultiColor(ImVec2(cx - bw, ccy - slot * 0.5f - 18 * s), ImVec2(cx, ccy + slot * 0.5f + 15 * s),
                                fade(IM_COL32(255, 248, 236, 0), a), fade(IM_COL32(255, 248, 236, 34), a),
                                fade(IM_COL32(255, 248, 236, 34), a), fade(IM_COL32(255, 248, 236, 0), a));
    dl->AddRectFilledMultiColor(ImVec2(cx, ccy - slot * 0.5f - 18 * s), ImVec2(cx + bw, ccy + slot * 0.5f + 15 * s),
                                fade(IM_COL32(255, 248, 236, 34), a), fade(IM_COL32(255, 248, 236, 0), a),
                                fade(IM_COL32(255, 248, 236, 0), a), fade(IM_COL32(255, 248, 236, 34), a));
    // the name above, slanted, over a dotted rule; the last one fading out under it as the bar steps
    {
        float nfs = 31 * s, ny = ccy - slot * 0.5f - 54 * s;
        float ne = ease((float)(now - g_sel_at) / 0.14f);
        if (ne < 1 && !g_name_prev.empty()) {
            ImVec2 ps = f->CalcTextSizeA(nfs, FLT_MAX, 0, g_name_prev.c_str());
            text_shadowed(dl, f, nfs, ImVec2(cx - ps.x * 0.5f, ny), white, a * (1 - ne), g_name_prev.c_str(), true, s);
        }
        ImVec2 ns = f->CalcTextSizeA(nfs, FLT_MAX, 0, cur->name);
        text_shadowed(dl, f, nfs, ImVec2(cx - ns.x * 0.5f, ny + 3 * s * (1 - ne)), used ? IM_COL32(222, 218, 210, 255) : white,
                      a * (0.2f + 0.8f * ne), cur->name, true, s);
        float dy = ny + nfs + 8 * s, dw = 92 * s;
        for (float x = -dw; x <= dw + 0.1f; x += 5.5f * s) {
            float edge = 1 - fabsf(x) / (dw * 1.15f);
            dl->AddCircleFilled(ImVec2(cx + x, dy), 1.1f * s, fade(IM_COL32(255, 255, 255, 150), a * edge), 6);
        }
    }
    // the slots: three either side of the chosen one, the outer ones fading
    int base = (int)floorf(g_scroll + 0.5f);
    for (int o = -side - 1; o <= side + 1; o++) {
        int pos = ((base + o) % n + n) % n;
        float x = cx + ((float)(base + o) - g_scroll) * step_px;
        float edge = fabsf(x - cx) / ((side + 0.5f) * step_px);
        float open_e = ease((float)(now - g_open_at - fabsf((float)o) * 0.025f) / 0.18f);
        float sa = a * open_e * (edge > 1 ? 0 : edge > 0.72f ? 1 - (edge - 0.72f) / 0.28f : 1);
        if (sa <= 0.01f) continue;
        float sy = ccy + 8 * s * (1 - open_e);
        const AmiiboDef *fig = amiibo_at(g_order[pos]);
        bool sel = pos == g_sel, fav = pos < g_nfav, u = amiibo_used_today(fig->id);
        ImVec2 p0(x - slot * 0.5f, sy - slot * 0.5f), p1(x + slot * 0.5f, sy + slot * 0.5f);
        dl->AddRectFilled(p0, p1, fade(IM_COL32(34, 26, 18, sel ? 168 : 138), sa));
        dl->AddRect(p0, p1, fade(IM_COL32(18, 14, 10, 150), sa), 0, 0, 1.6f * s);
        dl->AddRect(ImVec2(p0.x + 1.6f * s, p0.y + 1.6f * s), ImVec2(p1.x - 1.6f * s, p1.y - 1.6f * s), fade(IM_COL32(255, 240, 220, 22), sa), 0, 0, 1.0f * s);
        figure_icon(dl, ImVec2(x, sy - 6 * s), slot, group_colour(fig->group), is_card(fig->id), sa, u);
        std::string ini = initials(fig->name);
        count_badge(dl, f, p1, s, ini.c_str(), sa, u);
        if (fav) {   // (the game's small mark at a slot's top left: here a favourite's star)
            star(dl, ImVec2(p0.x + 15 * s, p0.y + 15 * s), 10 * s, fade(IM_COL32(60, 44, 0, 200), sa));
            star(dl, ImVec2(p0.x + 14 * s, p0.y + 14 * s), 9 * s, fade(IM_COL32(250, 214, 64, 255), sa));
        }
        if (u) clock_badge(dl, ImVec2(p1.x - 16 * s, p0.y + 16 * s), 11 * s, fade(amber, sa));
        if (sel && g_tapped == fig->id && !up) {   // tapped: the slot lights up as the bar fades
            float fl = 1 - ease(closing);
            dl->AddRectFilled(p0, p1, fade(IM_COL32(255, 250, 230, 120), sa * fl));
        }
        if (pos == g_nfav - 1 && g_nfav > 0 && g_nfav < n)   // a thin line where the favourites end
            dl->AddLine(ImVec2(p1.x + (step_px - slot) * 0.5f, sy - slot * 0.42f), ImVec2(p1.x + (step_px - slot) * 0.5f, sy + slot * 0.42f),
                        fade(IM_COL32(255, 255, 255, 110), sa), 1.6f * s);
    }
    {   // the brackets on the chosen slot: they spring in from a little wider as it's chosen
        float be = ease_back((float)(now - g_sel_at) / 0.2f), open_b = ease_back((float)(now - g_open_at) / 0.24f);
        float grow = (1 - fminf(be, open_b)) * 9 * s + 4 * s;
        float sx = cx + ((float)g_sel - g_scroll) * step_px;
        if (fabsf(sx - cx) > step_px * 0.5f) sx = cx;   // (wrapping: on the middle slot)
        ImVec2 b0(sx - slot * 0.5f - grow, ccy - slot * 0.5f - grow), b1(sx + slot * 0.5f + grow, ccy + slot * 0.5f + grow);
        ImU32 bc = fade(used ? amber : white, a);
        brackets(dl, ImVec2(b0.x + 1.5f * s, b0.y + 1.5f * s), ImVec2(b1.x + 1.5f * s, b1.y + 1.5f * s), 15 * s, 3.2f * s, fade(IM_COL32(0, 0, 0, 90), a));
        brackets(dl, b0, b1, 15 * s, 3.2f * s, bc);
    }
    // the right stick's mark under the bar, then the series and the buttons (small, as the game's prompts)
    float hy = ccy + slot * 0.5f + 25 * s;
    stick_mark(dl, f, ImVec2(cx, hy), s, a);
    char line[200];
    const char *grp = g_sel < g_nfav ? "Favourites" : amiibo_group_name(cur->group);
    int gfirst = g_sel, glast = g_sel;
    while (gfirst > 0 && group_of(gfirst - 1) == group_of(g_sel)) gfirst--;
    while (glast < n - 1 && group_of(glast + 1) == group_of(g_sel)) glast++;
    if (now - g_fav_flash_at < 1.6)
        snprintf(line, sizeof line, "%s", g_fav_flash_on ? "Added to your favourites" : "Taken out of your favourites");
    else if (used)
        snprintf(line, sizeof line, "%s   %d / %d   \xc2\xb7   used today", grp, g_sel - gfirst + 1, glast - gfirst + 1);
    else
        snprintf(line, sizeof line, "%s   %d / %d", grp, g_sel - gfirst + 1, glast - gfirst + 1);
    float lfs = 19 * s, ly = hy + 24 * s;
    ImVec2 ls = f->CalcTextSizeA(lfs, FLT_MAX, 0, line);
    text_shadowed(dl, f, lfs, ImVec2(cx - ls.x * 0.5f, ly), used && now - g_fav_flash_at >= 1.6 ? IM_COL32(246, 207, 138, 255) : IM_COL32(236, 232, 224, 255),
                  a, line, false, s);
    // the prompts: no panel, white on the game with a shadow, as the game's own
    struct P { int mark; const char *label; } pr[] = {{-1, "Series"}, {0, "Tap"}, {2, amiibo_favourite(cur->id) ? "Unfavourite" : "Favourite"}, {1, "Cancel"}};
    float pfs = 18 * s, py = ly + lfs + 26 * s, total = 0, pr_r = 12 * s;
    float widths[4];
    for (int i = 0; i < 4; i++) widths[i] = 2 * pr_r + 8 * s + f->CalcTextSizeA(pfs, FLT_MAX, 0, pr[i].label).x, total += widths[i];
    total += 30 * s * 3;
    float x = cx - total * 0.5f;
    for (int i = 0; i < 4; i++) {
        ImVec2 c(x + pr_r, py);
        if (pr[i].mark < 0) {   // the d-pad's up / down
            float t = 5.5f * s;
            dl->AddTriangleFilled(ImVec2(c.x, c.y - pr_r), ImVec2(c.x - t, c.y - pr_r + t * 1.2f), ImVec2(c.x + t, c.y - pr_r + t * 1.2f), fade(white, a));
            dl->AddTriangleFilled(ImVec2(c.x, c.y + pr_r), ImVec2(c.x - t, c.y + pr_r - t * 1.2f), ImVec2(c.x + t, c.y + pr_r - t * 1.2f), fade(white, a));
        } else button_mark(dl, f, c, pr_r, pr[i].mark, fade(white, a));
        text_shadowed(dl, f, pfs, ImVec2(x + 2 * pr_r + 8 * s, py - pfs * 0.55f), IM_COL32(240, 238, 232, 255), a, pr[i].label, false, s);
#ifdef __ANDROID__
        g_prompt_rect[i] = ImVec4(x - 17 * s, py - 30 * s, x + widths[i] + 17 * s, py + 30 * s);
#endif
        x += widths[i] + 30 * s;
    }
#ifdef __ANDROID__
    {   // the bar's area, for the fingers: the name to the prompts, the row's width
        std::lock_guard<std::mutex> l(g_tmu);
        float hw = fmaxf((side + 1) * step_px, total * 0.5f + 26 * s);
        g_lay0 = ImVec2(cx - hw, ccy - slot * 0.5f - 70 * s), g_lay1 = ImVec2(cx + hw, py + 30 * s), g_lay_on = up;
    }
#endif
}

#ifdef __ANDROID__
// ui/touch_controls.mm: a finger on the bar is the bar's (true: taken - the on-screen controls don't see it). w, h: the
// screen in pixels (the fingers' 0..1 times these)
extern "C" bool amiibo_bar_touch_event(const SDL_Event *e, float w, float h) {
    std::lock_guard<std::mutex> l(g_tmu);
    if (!amiibo_bar_up()) { g_tdown = false, g_lay_on = false; return false; }
    float x = e->tfinger.x * w, y = e->tfinger.y * h;
    switch (e->type) {
    case SDL_EVENT_FINGER_DOWN:
        if (g_tdown || !g_lay_on || x < g_lay0.x || x > g_lay1.x || y < g_lay0.y || y > g_lay1.y) return false;
        g_tdown = true, g_tfinger = e->tfinger.fingerID;
        g_tq.push_back({0, x, y});
        return true;
    case SDL_EVENT_FINGER_MOTION:
        if (!g_tdown || e->tfinger.fingerID != g_tfinger) return false;
        g_tq.push_back({1, x, y});
        return true;
    case SDL_EVENT_FINGER_UP: case SDL_EVENT_FINGER_CANCELED:
        if (!g_tdown || e->tfinger.fingerID != g_tfinger) return false;
        g_tdown = false;
        g_tq.push_back({e->type == SDL_EVENT_FINGER_UP ? 2 : 3, x, y});
        return true;
    }
    return false;
}
#endif

// hle/input.c: the buttons the bar presses for the game (the touch Cancel: B)
extern "C" uint64_t amiibo_bar_injected(void) {
#ifdef __ANDROID__
    return g_now.load() < g_inject_b_until.load() ? 1u << 1 : 0;
#else
    return 0;
#endif
}

// The amiibo rows of WSword's settings (Controls)
void amiibo_settings_rows(void) {
    opt_section("amiibo");
    bool daily = amiibo_daily();
    if (opt_toggle("One scan a day per figure", &daily, false,
                   "Off (the default): no limit - every tap is a new figure to the game, as many times as you like. On: "
                   "the game's own rule, each amiibo gives its items once a day."))
        amiibo_set_daily(daily);
    uint64_t fav[64];
    int nf = amiibo_favourites(fav, 64);
    char v[48];
    snprintf(v, sizeof v, nf == 1 ? "1 figure" : "%d figures", nf);
    if (opt_action("Clear favourites", v, "Your favourites come first in the amiibo bar. Add or take one out there with "
                   "X (Square on the PS5). This empties the list.", false) && nf)
        amiibo_clear_favourites();
    opt_action("Open the amiibo bar", "amiibo rune", "Choose the amiibo rune and use it, as with a figure: the bar of "
               "every amiibo comes up. Pick one with the right stick and tap it with A (Cross on the PS5)"
#ifdef __ANDROID__
               ", or touch a figure and touch it again"
#endif
               ".", false);
}
