// Data root and shipped resources (runtime/paths.h).
#include <SDL3/SDL.h>
#include <dirent.h>
#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#ifdef _WIN32
#include <windows.h>
#endif

#include "game_files.h"
#include "imageload.h"
#include "paths.h"
#include "settings.h"
#include "platform.h"

static char g_root[1024], g_start[1024], g_exe_dir[1024];

#ifdef _WIN32
#define SEP "\\"
static bool is_link(const char *p) {  // symlink or junction
    DWORD a = GetFileAttributesA(p);
    return a != INVALID_FILE_ATTRIBUTES && (a & FILE_ATTRIBUTE_REPARSE_POINT);
}
static bool resolve(const char *p, char *out, size_t n) { return _fullpath(out, p, n) != NULL; }
#define path_eq(a, b) (_stricmp(a, b) == 0)
#else
#define SEP "/"
static bool is_link(const char *p) {
    struct stat st;
    return lstat(p, &st) == 0 && S_ISLNK(st.st_mode);
}
static bool resolve(const char *p, char *out, size_t n) {
    char buf[PATH_MAX];
    if (!realpath(p, buf)) return false;
    snprintf(out, n, "%s", buf);
    return true;
}
#define path_eq(a, b) (strcmp(a, b) == 0)
#endif

static bool is_dir(const char *p) {
    struct stat st;
    return stat(p, &st) == 0 && S_ISDIR(st.st_mode);
}

static bool exists(const char *p) {
    struct stat st;
    return stat(p, &st) == 0;
}

static void mkdirs(const char *path) {
    char p[1024];
    snprintf(p, sizeof p, "%s", path);
    for (char *c = p + 1; *c; c++)
        if (*c == '/' || *c == '\\') { char s = *c; *c = 0; mkdir(p, 0755); *c = s; }
    mkdir(p, 0755);
}

static bool writable(const char *dir) {
    char t[1100];
    snprintf(t, sizeof t, "%s" SEP ".write_test", dir);
    FILE *f = fopen(t, "wb");
    if (!f) return false;
    fclose(f);
    remove(t);
    return true;
}

static void fail(const char *msg) {
    fprintf(stderr, "%s\n", msg);
    SDL_ShowSimpleMessageBox(SDL_MESSAGEBOX_ERROR, "WSword", msg, NULL);
    exit(1);
}

static bool g_dev;  // the data root is the starting folder because it has extracted/ (a source checkout)
bool rt_dev_mode(void) { return g_dev; }

#ifdef _WIN32
// (WSword PC 0.3.0) The folder of an older WSword (0.2.8-pc.x, on LAS Recomp's layout): each game version set up in a
// folder of its own - v182 / v190, game_version.txt naming the one in use - with its extracted/ (exefs/, romfs/) and
// save/ in it. Unzipped over that folder, WSword keeps using that version's folder as its data folder: the game files
// (no new copy - the old romfs.bin beside romfs/ is removed, launcher.mm remove_old_image) and the saves are there.
// Only where the exe's folder has no game files of its own.
static void wsword_older_root(char *root, size_t n) {
    char p[1200];
    snprintf(p, sizeof p, "%s" SEP "extracted" SEP "exefs", root);
    if (is_dir(p)) return;
    int want = 0;
    snprintf(p, sizeof p, "%s" SEP "game_version.txt", root);
    FILE *f = fopen(p, "rb");
    if (f) {
        if (fscanf(f, "%d", &want) != 1) want = 0;
        fclose(f);
    }
    const int order[3] = {want, 190, 182};  // (the one in use, else the newest set up)
    for (int i = 0; i < 3; i++) {
        if (order[i] != 182 && order[i] != 190) continue;
        char d[1100];
        snprintf(d, sizeof d, "%s" SEP "v%d", root, order[i]);
        snprintf(p, sizeof p, "%s" SEP "extracted" SEP "exefs" SEP "main", d);
        if (!exists(p) || (size_t)snprintf(root, n, "%s", d) >= n) continue;
        fprintf(stderr, "[paths] an older WSword's folder: game version %d.%d.%d's game files and saves (v%d)\n",
                order[i] / 100, order[i] / 10 % 10, order[i] % 10, order[i]);
        return;
    }
}
#endif

void rt_paths_init(void) {
    if (!getcwd(g_start, sizeof g_start)) g_start[0] = 0;
    if (plat_exe_path(g_exe_dir, sizeof g_exe_dir)) {
        char *s = strrchr(g_exe_dir, '/'), *b = strrchr(g_exe_dir, '\\');
        if (b > s) s = b;
        if (s) *s = 0;
    }
    char root[1024];
    const char *env = getenv("SAVAGEWIND_DATA_ROOT");
    if (env && *env) snprintf(root, sizeof root, "%s", env);
    else if (is_dir("extracted")) snprintf(root, sizeof root, "%s", g_start), g_dev = true;  // dev / portable: as before
    else {
#ifdef _WIN32
        snprintf(root, sizeof root, "%s", g_exe_dir);
        wsword_older_root(root, sizeof root);
#elif defined(__PROSPERO__)
        // the PS5: the title folder (/app0 = /data/homebrew/<title id>, writable), laid out as the Windows folder
        snprintf(root, sizeof root, "%s", g_exe_dir[0] ? g_exe_dir : "/app0");
#elif defined(__linux__)
        // (the AppImage is read-only): $XDG_DATA_HOME/savagewind, ~/.local/share/savagewind by default
        const char *xdg = getenv("XDG_DATA_HOME"), *home = getenv("HOME");
        if (xdg && *xdg == '/') snprintf(root, sizeof root, "%s/savagewind", xdg);
        else snprintf(root, sizeof root, "%s/.local/share/savagewind", home && *home ? home : "/tmp");
#else
        const char *home = getenv("HOME");
        snprintf(root, sizeof root, "%s/Library/Application Support/" RT_BUNDLE_ID, home && *home ? home : "/tmp");
#endif
    }
    mkdirs(root);
    char msg[1400];
#ifdef __PROSPERO__
    {   // (the console's sandbox: each step in the log, with why it failed - the first title builds there)
        struct stat st;
        int s = stat(root, &st), se = errno;
        bool w = writable(root);
        int we = errno;
        int c = chdir(root), ce = errno;
        char cwd[1024] = "";
        bool g = getcwd(cwd, sizeof cwd) != NULL;
        fprintf(stderr, "[paths] %s: stat %d (%s, mode %o), writable %d (%s), chdir %d (%s), cwd %s\n", root, s,
                s ? strerror(se) : "ok", s ? 0 : (unsigned)st.st_mode, w, w ? "ok" : strerror(we), c,
                c ? strerror(ce) : "ok", g ? cwd : "(unknown)");
        if (w && c == 0) {  // writable and the working directory: what the runtime needs (stat may not say dir)
            snprintf(g_root, sizeof g_root, "%s", root);
            fprintf(stderr, "[paths] data: %s\n", g_root);
            return;
        }
    }
#endif
    if (!is_dir(root) || !writable(root) || chdir(root) != 0) {
#ifdef _WIN32
        snprintf(msg, sizeof msg, "WSword can't write to its folder:\n%s\n\nIt keeps game files, saves and settings "
                 "next to the program. Move the \"WSword\" folder somewhere you can write to (e.g. Documents or "
                 "Desktop, not Program Files) and start it again.", root);
#else
        snprintf(msg, sizeof msg, "WSword can't write to its data folder:\n%s", root);
#endif
        fail(msg);
    }
    if (!getcwd(g_root, sizeof g_root)) snprintf(g_root, sizeof g_root, "%s", root);
    fprintf(stderr, "[paths] data: %s\n", g_root);
}

const char *rt_data_root(void) { return g_root; }
const char *rt_exe_dir(void) { return g_exe_dir[0] ? g_exe_dir : g_root; }

bool rt_resource(const char *name, const char *dev_rel, char *out, size_t n) {
    char c[4][1100] = {{0}};
    if (name) {
        snprintf(c[0], sizeof c[0], "%s" SEP "%s", g_exe_dir, name);
        snprintf(c[1], sizeof c[1], "%s" SEP ".." SEP "Resources" SEP "%s", g_exe_dir, name);  // .app/Contents/Resources
    }
    if (dev_rel) {
        snprintf(c[2], sizeof c[2], "%s" SEP "%s", g_start, dev_rel);
        snprintf(c[3], sizeof c[3], "%s" SEP ".." SEP "%s", g_exe_dir, dev_rel);  // build/savagewind -> repo root
    }
    for (int i = 0; i < 4; i++)
        if (c[i][0] && exists(c[i])) return (size_t)snprintf(out, n, "%s", c[i]) < n;  // (as is: a venv python must stay a link)
    return false;
}

// ---- game files
// game_dir must be <data root>/extracted, a real folder (a dev worktree's symlinked extracted/ is refused)
static bool game_dir_ok(const char *game_dir) {
    char want[1100], got[1100];
    snprintf(want, sizeof want, "%s" SEP "extracted", g_root);
    if (!g_root[0] || is_link(game_dir) || !resolve(game_dir, got, sizeof got)) return false;
    return path_eq(want, got);
}

bool rt_remove_game_file(const char *game_dir, const char *name) {
    bool known = false;
    for (size_t i = 0; i < sizeof GAME_FILES / sizeof *GAME_FILES; i++) known |= !strcmp(name, GAME_FILES[i]);
    if (!known || !game_dir_ok(game_dir)) {
        fprintf(stderr, "[paths] refusing to delete %s/%s (not app-created game files in the data root)\n", game_dir, name);
        return false;
    }
    char p[1100];
    snprintf(p, sizeof p, "%s" SEP "%s", game_dir, name);
    if (!exists(p) && !is_link(p)) return true;
    if (is_link(p)) {
        fprintf(stderr, "[paths] refusing to delete %s (a link)\n", p);
        return false;
    }
    return is_dir(p) ? plat_remove_tree(p) : remove(p) == 0;  // (plat_remove_tree doesn't follow links inside)
}

bool rt_is_link(const char *p) { return is_link(p); }

bool rt_remove_game_files(const char *game_dir) {
    if (!game_dir_ok(game_dir)) {
        fprintf(stderr, "[paths] refusing to delete game files in %s (not <data root>/extracted)\n", game_dir);
        return false;
    }
    bool ok = true;
    for (size_t i = 0; i < sizeof GAME_FILES / sizeof *GAME_FILES; i++) ok &= rt_remove_game_file(game_dir, GAME_FILES[i]);
    rmdir(game_dir);  // only if empty: anything else in there stays
    return ok;
}

// The player's own start screen picture (runtime/ui/splash.mm): splash.jpg / splash.jpeg / splash.png in the data root
// (next to the exe; a source checkout's root). Never shipped and never tracked (.gitignore): whatever the player puts
// there, for themselves.
bool rt_user_splash(char *out, size_t n) {
    static const char *const names[] = {"splash.jpg", "splash.jpeg", "splash.png"};
    char p[1100];
    for (size_t i = 0; i < sizeof names / sizeof *names; i++) {
        snprintf(p, sizeof p, "%s" SEP "%s", g_root, names[i]);
        if (exists(p)) return (size_t)snprintf(out, n, "%s", p) < n;
    }
    return false;
}

// Window / Dock icon: icon.png shipped next to the exe or in the .app (none for a plain source build). (WSword) Or the
// one chosen on the start screen (Settings > Files > Look: settings.h app_icon, rt_window_icons), the window's and the
// taskbar's; the exe's own (windows.rc) stays the Sword.
const char *const rt_window_icons[RT_WINDOW_ICONS] = {"icon.png", "app-icon-slate.png", "app-icon-midnight.png",
                                                      "app-icon-dawn.png", "app-icon-ancient.png", "app-icon-forest.png"};
static bool window_icon_file(SDL_Window *w, const char *name) {
    char p[1100];
    if (!rt_resource(name, NULL, p, sizeof p)) return false;
    int iw, ih;
    unsigned char *px = rt_image_rgba(p, &iw, &ih);  // (not SDL_LoadPNG: that is SDL 3.4, the distributions ship 3.2)
    if (!px) return false;
    SDL_Surface *s = SDL_CreateSurfaceFrom(iw, ih, SDL_PIXELFORMAT_RGBA32, px, iw * 4);
    if (s) SDL_SetWindowIcon(w, s), SDL_DestroySurface(s);
    rt_image_free(px);
    return s != NULL;
}
void rt_window_icon(SDL_Window *w) {
    int k = g_settings.app_icon > 0 && g_settings.app_icon < RT_WINDOW_ICONS ? g_settings.app_icon : 0;
    if (!window_icon_file(w, rt_window_icons[k]) && k) window_icon_file(w, rt_window_icons[0]);
}
