// (WSword) The amiibo bar's pictures: each figure's own picture in its slot, from AmiiboAPI's database of amiibo
// (github.com/N3evin/AmiiboAPI, its images/icon_<head>-<tail>.png - Nintendo's product photos). Nothing ships with
// WSword: Controls > amiibo > Pictures downloads them to this device when the player asks, four at a time, each made
// small (at most 160 px a side, a PNG of ~35 KB) into amiibo/images/<id>.png; a picture of the player's own put there
// under that name is shown the same way. Without one a slot draws its figure as before (ui/amiibo_bar.mm).
//
// The download, by platform: Android - the activity's httpGet (Java's HttpURLConnection, SheikahSlateActivity);
// the PS5 - the console's own HTTP/2 library (libSceHttp2, loaded when needed); Windows / Linux - curl (Windows 10's
// own C:\Windows\System32\curl.exe).
#include <math.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <atomic>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

#include <SDL3/SDL.h>

#include "imgui.h"

#define STB_IMAGE_STATIC
#define STB_IMAGE_IMPLEMENTATION
#define STBI_ONLY_PNG
#define STBI_ONLY_JPEG
#include "../../third_party/stb/stb_image.h"
#define STB_IMAGE_WRITE_STATIC
#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "../../third_party/stb/stb_image_write.h"

#include "../amiibo.h"
#include "option_rows.h"
extern "C" {
#include "../platform.h"
uint64_t vk_imgui_texture_rgba(const void *rgba, int w, int h);  // runtime/nvn/vulkan/imgui_glue.cpp
}
#ifdef __ANDROID__
#include <jni.h>
#endif

namespace {
const char *const kBase = "https://raw.githubusercontent.com/N3evin/AmiiboAPI/master/images/";
enum { MAX_SIDE = 160, WORKERS = 4 };

std::string pic_path(uint64_t id) {
    char p[64];
    snprintf(p, sizeof p, "amiibo/images/%016llx.png", (unsigned long long)id);
    return p;
}
bool exists(const std::string &p) { struct stat st; return stat(p.c_str(), &st) == 0 && st.st_size > 0; }

// ------------------------------------------------------------------ one file over HTTPS, to dest
#if defined(__ANDROID__)
bool http_get(const char *url, const std::string &dest) {
    JNIEnv *env = (JNIEnv *)SDL_GetAndroidJNIEnv();   // (attaches this thread)
    jobject act = (jobject)SDL_GetAndroidActivity();
    if (!env || !act) return false;
    jclass c = env->GetObjectClass(act);
    jmethodID m = env->GetStaticMethodID(c, "httpGet", "(Ljava/lang/String;Ljava/lang/String;)Z");
    bool ok = false;
    if (m) {
        char cwd[1024] = "";
        std::string abs = dest[0] == '/' ? dest : std::string(getcwd(cwd, sizeof cwd) ? cwd : ".") + "/" + dest;
        jstring ju = env->NewStringUTF(url), jp = env->NewStringUTF(abs.c_str());
        ok = env->CallStaticBooleanMethod(c, m, ju, jp);
        env->DeleteLocalRef(ju), env->DeleteLocalRef(jp);
    }
    if (env->ExceptionCheck()) env->ExceptionClear(), ok = false;
    env->DeleteLocalRef(c);
    env->DeleteLocalRef(act);
    return ok;
}
#elif defined(__PROSPERO__)
extern "C" {
int sceKernelLoadStartModule(const char *path, size_t argc, const void *argv, uint32_t flags, void *opt, int *res);
int sceKernelDlsym(int handle, const char *symbol, void **addr);
}
struct {
    bool tried, ok;
    int (*net_init)(void);
    int (*pool_create)(const char *, int, int);
    int (*ssl_init)(size_t);
    int (*http2_init)(int, int, size_t, int);
    int (*tmpl_create)(int, const char *, int, int);
    int (*req_create)(int, const char *, const char *, uint64_t);
    int (*req_delete)(int);
    int (*send)(int, const void *, size_t);
    int (*status)(int, int *);
    int (*read)(int, void *, size_t);
    int tmpl;
    std::mutex mu;
} g_h2;
int module(const char *name) {
    static const char *const dirs[] = {"/system/common/lib/", "/system/priv/lib/", ""};
    for (const char *d : dirs) {
        char path[160];
        snprintf(path, sizeof path, "%s%s", d, name);
        int res = 0, h = sceKernelLoadStartModule(path, 0, NULL, 0, NULL, &res);
        if (h >= 0) return h;
    }
    return -1;
}
bool h2_load(void) {
    std::lock_guard<std::mutex> l(g_h2.mu);
    if (g_h2.tried) return g_h2.ok;
    g_h2.tried = true;
    int hn = module("libSceNet.sprx"), hs = module("libSceSsl.sprx"), hh = module("libSceHttp2.sprx");
    if (hh < 0) { fprintf(stderr, "[amiibo] the console's HTTP library (libSceHttp2) couldn't be loaded\n"); return false; }
    if (hn >= 0) sceKernelDlsym(hn, "sceNetInit", (void **)&g_h2.net_init), sceKernelDlsym(hn, "sceNetPoolCreate", (void **)&g_h2.pool_create);
    if (hs >= 0) sceKernelDlsym(hs, "sceSslInit", (void **)&g_h2.ssl_init);
    sceKernelDlsym(hh, "sceHttp2Init", (void **)&g_h2.http2_init);
    sceKernelDlsym(hh, "sceHttp2CreateTemplate", (void **)&g_h2.tmpl_create);
    sceKernelDlsym(hh, "sceHttp2CreateRequestWithURL", (void **)&g_h2.req_create);
    sceKernelDlsym(hh, "sceHttp2DeleteRequest", (void **)&g_h2.req_delete);
    sceKernelDlsym(hh, "sceHttp2SendRequest", (void **)&g_h2.send);
    sceKernelDlsym(hh, "sceHttp2GetStatusCode", (void **)&g_h2.status);
    sceKernelDlsym(hh, "sceHttp2ReadData", (void **)&g_h2.read);
    if (!g_h2.pool_create || !g_h2.ssl_init || !g_h2.http2_init || !g_h2.tmpl_create || !g_h2.req_create || !g_h2.send ||
        !g_h2.status || !g_h2.read) {
        fprintf(stderr, "[amiibo] the console's HTTP library is missing a function\n");
        return false;
    }
    if (g_h2.net_init) g_h2.net_init();
    int pool = g_h2.pool_create("wsword_amiibo", 128 * 1024, 0), ssl = g_h2.ssl_init(512 * 1024);
    int ctx = pool >= 0 && ssl >= 0 ? g_h2.http2_init(pool, ssl, 512 * 1024, WORKERS) : -1;
    g_h2.tmpl = ctx >= 0 ? g_h2.tmpl_create(ctx, "WSword", 3, 1) : -1;   // (HTTP/2, TLS)
    if (g_h2.tmpl < 0) { fprintf(stderr, "[amiibo] HTTP/2 setup failed (%x %x %x %x)\n", pool, ssl, ctx, g_h2.tmpl); return false; }
    g_h2.ok = true;
    return true;
}
bool http_get(const char *url, const std::string &dest) {
    if (!h2_load()) return false;
    int req = g_h2.req_create(g_h2.tmpl, "GET", url, 0), status = 0;
    if (req < 0) return false;
    bool ok = g_h2.send(req, NULL, 0) == 0 && g_h2.status(req, &status) == 0 && status == 200;
    if (ok) {
        FILE *f = fopen(dest.c_str(), "wb");
        ok = f != NULL;
        char buf[16384];
        int n;
        while (ok && (n = g_h2.read(req, buf, sizeof buf)) > 0) ok = fwrite(buf, 1, (size_t)n, f) == (size_t)n;
        if (f) ok = fclose(f) == 0 && ok;
    }
    if (g_h2.req_delete) g_h2.req_delete(req);
    return ok;
}
#else
bool http_get(const char *url, const std::string &dest) {
#ifdef _WIN32
    const char *sr = getenv("SystemRoot");
    std::string curl = std::string(sr ? sr : "C:\\Windows") + "\\System32\\curl.exe";
#else
    std::string curl = "/usr/bin/curl";
#endif
    const char *av[] = {curl.c_str(), "-fsSL", "--max-time", "30", "-A", "WSword", url, NULL};
    PlatProc p = plat_spawn(av, dest.c_str(), false);   // (curl's output - the picture - is the "log")
    return p && plat_proc_wait(p, true) == 0;
}
#endif

// ------------------------------------------------------------------ the download
std::atomic<int> g_done{0}, g_failed{0}, g_total{0}, g_next{0};
std::atomic<bool> g_running{false}, g_stop{false};
std::atomic<int> g_generation{0};   // (bumped when pictures change: the bar's textures are made again)
std::vector<uint64_t> g_queue;

// a downloaded picture made small: fit in MAX_SIDE, a box filter, as a PNG at dest
bool shrink(const std::string &src, const std::string &dest) {
    int w, h, n;
    unsigned char *px = stbi_load(src.c_str(), &w, &h, &n, 4);
    if (!px) return false;
    float k = fminf(1.0f, (float)MAX_SIDE / (float)(w > h ? w : h));
    int ow = (int)fmaxf(1, roundf(w * k)), oh = (int)fmaxf(1, roundf(h * k));
    std::vector<unsigned char> out((size_t)ow * oh * 4);
    for (int y = 0; y < oh; y++)
        for (int x = 0; x < ow; x++) {
            int x0 = x * w / ow, x1 = (x + 1) * w / ow, y0 = y * h / oh, y1 = (y + 1) * h / oh;
            if (x1 <= x0) x1 = x0 + 1;
            if (y1 <= y0) y1 = y0 + 1;
            float acc[4] = {0, 0, 0, 0}, wsum = 0;
            for (int yy = y0; yy < y1 && yy < h; yy++)
                for (int xx = x0; xx < x1 && xx < w; xx++) {
                    const unsigned char *p = px + ((size_t)yy * w + xx) * 4;
                    float a = p[3] / 255.0f;   // (premultiplied while averaging: no dark fringes on the edges)
                    acc[0] += p[0] * a, acc[1] += p[1] * a, acc[2] += p[2] * a, acc[3] += a, wsum += 1;
                }
            unsigned char *o = &out[((size_t)y * ow + x) * 4];
            float al = acc[3] / wsum;
            for (int c = 0; c < 3; c++) o[c] = (unsigned char)(acc[3] > 0 ? fminf(255, acc[c] / acc[3]) : 0);
            o[3] = (unsigned char)fminf(255, al * 255 + 0.5f);
        }
    stbi_image_free(px);
    return stbi_write_png(dest.c_str(), ow, oh, 4, out.data(), ow * 4) != 0;
}

void *worker(void *arg) {
    int me = (int)(intptr_t)arg;
    std::string tmp = "amiibo/images/.download" + std::to_string(me);
    for (;;) {
        if (g_stop) break;
        int i = g_next.fetch_add(1);
        if (i >= (int)g_queue.size()) break;
        uint64_t id = g_queue[i];
        char url[256];
        snprintf(url, sizeof url, "%sicon_%08x-%08x.png", kBase, (unsigned)(id >> 32), (unsigned)(id & 0xffffffffu));
        bool ok = false;
        for (int attempt = 0; attempt < 2 && !ok && !g_stop; attempt++)
            ok = http_get(url, tmp) && shrink(tmp, pic_path(id));
        remove(tmp.c_str());
        if (ok) g_done++;
        else g_failed++;
        if ((g_done + g_failed) % 50 == 0) g_generation++;   // (the bar picks the new ones up as they come)
    }
    return NULL;
}
void *runner(void *) {
    std::vector<pthread_t> t(WORKERS);
    for (int i = 0; i < WORKERS; i++) pthread_create(&t[i], NULL, worker, (void *)(intptr_t)i);
    for (int i = 0; i < WORKERS; i++) pthread_join(t[i], NULL);
    fprintf(stderr, "[amiibo] pictures: %d downloaded, %d failed\n", g_done.load(), g_failed.load());
    g_generation++;
    g_running = false;
    return NULL;
}

int count_present(void) {
    static double at = -10;
    static int n;
    double now = ImGui::GetCurrentContext() ? ImGui::GetTime() : 0;
    if (now - at < 2 && !g_running) return n;
    at = now;
    n = 0;
    for (int i = 0; i < amiibo_count(); i++) n += exists(pic_path(amiibo_at(i)->id));
    return n;
}

// ------------------------------------------------------------------ the bar's textures (render thread)
struct Pic { ImTextureID tex; float w, h; };
std::unordered_map<uint64_t, Pic> g_pics;   // (tex 0: none on disk - tried)
int g_pics_gen = -1;
int g_loads_this_frame, g_frame = -1;
}  // namespace

// ------------------------------------------------------------------ API (ui/amiibo_bar.mm)
// The figure's picture, made on first use (at most a few a frame); 0 without one. w, h: its size
ImTextureID amiibo_pic(uint64_t id, float *w, float *h) {
    if (g_pics_gen != g_generation.load()) {   // (new pictures on disk: those still missing are looked for again)
        for (auto it = g_pics.begin(); it != g_pics.end();) it = it->second.tex ? std::next(it) : g_pics.erase(it);
        g_pics_gen = g_generation.load();
    }
    auto it = g_pics.find(id);
    if (it != g_pics.end()) { *w = it->second.w, *h = it->second.h; return it->second.tex; }
    if (ImGui::GetFrameCount() != g_frame) g_frame = ImGui::GetFrameCount(), g_loads_this_frame = 0;
    if (g_loads_this_frame >= 3) { *w = *h = 0; return 0; }   // (the rest next frame: no hitch as the bar opens)
    g_loads_this_frame++;
    Pic p = {0, 0, 0};
    std::string path = pic_path(id);
    if (exists(path)) {
        int iw, ih, n;
        if (unsigned char *px = stbi_load(path.c_str(), &iw, &ih, &n, 4)) {
            p.tex = (ImTextureID)vk_imgui_texture_rgba(px, iw, ih);
            p.w = (float)iw, p.h = (float)ih;
            stbi_image_free(px);
        }
    }
    g_pics[id] = p;
    *w = p.w, *h = p.h;
    return p.tex;
}

void amiibo_pics_download(void) {
    if (g_running) return;
    mkdir("amiibo", 0755);
    mkdir("amiibo/images", 0755);
    g_queue.clear();
    for (int i = 0; i < amiibo_count(); i++)
        if (!exists(pic_path(amiibo_at(i)->id))) g_queue.push_back(amiibo_at(i)->id);
    g_total = (int)g_queue.size(), g_done = 0, g_failed = 0, g_next = 0, g_stop = false;
    if (g_queue.empty()) return;
    g_running = true;
    pthread_t t;
    pthread_attr_t at;
    pthread_attr_init(&at);
    pthread_attr_setdetachstate(&at, PTHREAD_CREATE_DETACHED);
    if (pthread_create(&t, &at, runner, NULL) != 0) g_running = false;
    pthread_attr_destroy(&at);
    fprintf(stderr, "[amiibo] downloading %d pictures from AmiiboAPI\n", g_total.load());
}

void amiibo_pics_delete(void) {
    if (g_running) return;
    for (int i = 0; i < amiibo_count(); i++) remove(pic_path(amiibo_at(i)->id).c_str());
    g_generation++;
}

// The rows for Controls > amiibo: Pictures (download / its progress), Delete pictures
void amiibo_pics_rows(void) {
    int have = count_present(), all = amiibo_count();
    char v[96];
    if (g_running)
        snprintf(v, sizeof v, "%d / %d", g_done.load() + g_failed.load(), g_total.load());
    else if (have >= all)
        snprintf(v, sizeof v, "All %d", all);
    else if (have > 0)
        snprintf(v, sizeof v, "%d of %d: download the rest", have, all);
    else
        snprintf(v, sizeof v, "Download");
    if (opt_action("Pictures", v,
                   "Each amiibo's own picture in the amiibo bar. They come from AmiiboAPI's online database of amiibo "
                   "(Nintendo's product photos): downloaded to this device when you choose this - about 30 MB, made small "
                   "for the bar - and never shipped with WSword. A picture of your own in amiibo/images/<the figure's id>.png "
                   "is shown the same way. Without one, a slot draws its figure.",
                   false) &&
        !g_running && have < all)
        amiibo_pics_download();
    if (!g_running && g_failed > 0 && g_total > 0) {
        char f[96];
        snprintf(f, sizeof f, "%d not downloaded", g_failed.load());
        if (opt_action("Download the missing pictures again", f, "Some pictures didn't come (no connection, or the database "
                       "doesn't have them). This tries those again.", false))
            amiibo_pics_download();
    }
    if (have > 0 && !g_running) {
        if (opt_action("Delete pictures", "", "Deletes the downloaded pictures from this device (amiibo/images). The bar draws "
                       "each figure again.", false))
            amiibo_pics_delete();
    }
}
