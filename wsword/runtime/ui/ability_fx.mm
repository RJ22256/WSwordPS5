// (WSword) Slow Time's look and sound (runtime/ability.c): as it starts, a ring of light sweeps out from the middle of
// the screen and the edges cool to a Sheikah blue; while it runs, a thin arc by the top of the screen drains; as it ends
// the colour warms back. A low "whoom" going in, a rising chime coming out (made here, as the amiibo bar's sounds). And
// the row for Settings > Controls > Abilities.
#include <math.h>
#include <stdio.h>
#include <string.h>
#include <mutex>
#include <vector>

#include <SDL3/SDL.h>

#include "imgui.h"

#include "../ability.h"
#include "option_rows.h"
extern "C" {
#include "../settings.h"
}

namespace {
SDL_AudioStream *g_stream;
bool g_tried;
std::mutex g_mu;

void tone(std::vector<float> &b, float start_s, float f0, float f1, float len_s, float amp, float decay) {
    const float sr = 48000;
    int s0 = (int)(start_s * sr), n = (int)(len_s * sr);
    if ((int)b.size() < s0 + n) b.resize(s0 + n, 0);
    float ph = 0;
    for (int i = 0; i < n; i++) {
        float t = i / sr, f = f0 + (f1 - f0) * (t / len_s);
        ph += 6.2831853f * f / sr;
        float env = expf(-t * decay) * fminf(1.0f, t * 400);
        b[s0 + i] += sinf(ph) * amp * env;
    }
}
void play(bool in) {
    std::lock_guard<std::mutex> l(g_mu);
    if (!g_stream && !g_tried) {
        g_tried = true;
        SDL_AudioSpec spec = {SDL_AUDIO_F32, 2, 48000};
        g_stream = SDL_OpenAudioDeviceStream(SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK, &spec, NULL, NULL);
        if (g_stream) SDL_ResumeAudioStreamDevice(g_stream);
    }
    if (!g_stream) return;
    std::vector<float> m;
    if (in) {   // a low sweep down, a shimmer over it
        tone(m, 0, 320, 90, 0.7f, 0.35f, 3.5f);
        tone(m, 0, 1760, 880, 0.5f, 0.06f, 5);
        tone(m, 0.05f, 2637, 1318, 0.45f, 0.04f, 6);
    } else {    // rising back up
        tone(m, 0, 140, 420, 0.35f, 0.25f, 6);
        tone(m, 0.12f, 1318, 1976, 0.4f, 0.07f, 7);
    }
    float vol = g_settings.volume > 0 ? fminf(g_settings.volume, 2.0f) : 0;
    std::vector<float> st(m.size() * 2);
    for (size_t i = 0; i < m.size(); i++) st[2 * i] = st[2 * i + 1] = fmaxf(-1, fminf(1, m[i] * vol));
    SDL_PutAudioStreamData(g_stream, st.data(), (int)(st.size() * sizeof(float)));
}
float ease(float x) { x = x < 0 ? 0 : x > 1 ? 1 : x; float u = 1 - x; return 1 - u * u * u; }
bool g_was_running;
double g_started_at = -10, g_ended_at = -10;
}  // namespace

bool ability_fx_visible(void) {
    return ability_running() || g_was_running || (ImGui::GetCurrentContext() && ImGui::GetTime() - g_ended_at < 0.6);
}

// Each frame (ui/menu.mm menu_render), over the game and under the menus
void ability_fx_draw(ImGuiIO &io, float scale) {
    bool run = ability_running();
    double now = ImGui::GetTime();
    if (run && !g_was_running) g_started_at = now, play(true);
    if (!run && g_was_running) g_ended_at = now, play(false);
    g_was_running = run;
    float W = io.DisplaySize.x, H = io.DisplaySize.y, s = scale;
    ImDrawList *dl = ImGui::GetBackgroundDrawList();   // (under the menus and the amiibo bar, over the game)
    float in = ease((float)(now - g_started_at) / 0.35f), out = run ? 1 : 1 - ease((float)(now - g_ended_at) / 0.5f);
    float a = run ? in : out;
    if (a <= 0.003f) return;
    // the edges cooled to a Sheikah blue: four soft bands inward
    ImU32 edge = IM_COL32(40, 150, 210, (int)(115 * a)), clear = IM_COL32(40, 150, 210, 0);
    float bw = W * 0.16f, bh = H * 0.2f;
    dl->AddRectFilledMultiColor(ImVec2(0, 0), ImVec2(bw, H), edge, clear, clear, edge);
    dl->AddRectFilledMultiColor(ImVec2(W - bw, 0), ImVec2(W, H), clear, edge, edge, clear);
    dl->AddRectFilledMultiColor(ImVec2(0, 0), ImVec2(W, bh), edge, edge, clear, clear);
    dl->AddRectFilledMultiColor(ImVec2(0, H - bh), ImVec2(W, H), clear, clear, edge, edge);
    dl->AddRectFilled(ImVec2(0, 0), io.DisplaySize, IM_COL32(20, 70, 110, (int)(28 * a)));   // (a faint cool wash)
    // the ring sweeping out as it starts
    float rt = (float)(now - g_started_at) / 0.6f;
    if (run && rt < 1) {
        float r = ease(rt) * sqrtf(W * W + H * H) * 0.55f;
        dl->AddCircle(ImVec2(W * 0.5f, H * 0.5f), r, IM_COL32(170, 235, 255, (int)(170 * (1 - rt))), 96, 6 * s * (1 - rt) + 1);
        dl->AddCircle(ImVec2(W * 0.5f, H * 0.5f), r * 0.92f, IM_COL32(120, 210, 250, (int)(90 * (1 - rt))), 96, 3 * s);
    }
    // the time left: a thin arc at the top middle, draining
    float p = ability_progress();
    if (run && p > 0) {
        ImVec2 c(W * 0.5f, 70 * s);
        float r = 22 * s, a0 = -1.5708f, a1 = a0 + 6.2832f * (1 - p);
        dl->AddCircle(c, r, IM_COL32(255, 255, 255, (int)(50 * a)), 40, 3 * s);
        dl->PathArcTo(c, r, a0, a1, 40);
        dl->PathStroke(IM_COL32(190, 240, 255, (int)(230 * a)), 0, 3.5f * s);
        // an hourglass in the middle
        float h = 8 * s, w = 6 * s;
        ImU32 ic = IM_COL32(220, 245, 255, (int)(230 * a));
        dl->AddTriangleFilled(ImVec2(c.x - w, c.y - h), ImVec2(c.x + w, c.y - h), ImVec2(c.x, c.y), ic);
        dl->AddTriangleFilled(ImVec2(c.x, c.y), ImVec2(c.x - w, c.y + h), ImVec2(c.x + w, c.y + h), ic);
    }
}

// Settings > Controls: the abilities
void ability_settings_rows(void) {
    opt_section("Abilities");
    bool on = ability_enabled();
    if (opt_toggle("Slow Time (L3 + R3)", &on, true,
                   "Press both sticks in together: the whole world slows to a third of its speed for seven seconds - "
                   "Link with it, as the game's own slow motion when you aim in mid-air, but whenever you like. Then it "
                   "rests for 20 seconds. Never in the menus or the cutscenes. A WSword ability, not the game's."))
        ability_set_enabled(on);
}
