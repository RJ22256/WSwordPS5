// (WSword) The player's own ReShade, loaded by WSword (reshade.h)
#include "reshade.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>
#include <zlib.h>

#include "../../paths.h"
#include "../../settings.h"
#include "dlss_bridge.h"
#include "vk.h"

#define LAYER_NAME "VK_LAYER_reshade"  // (ReShade's own manifest's name, setup/ReShade64.json)

static struct {
    wchar_t old_layer_path[4096];  // (VK_LAYER_PATH as it was, put back after the instance)
    bool set_layer_path;
    bool tried;     // this run looked at the setting (at the instance)
    bool layer;     // the layer was asked for
    bool loaded;    // ReShade's module is in the process
    bool attached;  // the bridge's add-on is registered: WSword's depth for its effects
    bool own_depth; // ReShade's Generic Depth asked for instead
    char why[400];
    char base[1100];  // where its ReShade.ini is (its base path)
    PFN_wsrs_depth depth;
    PFN_wsrs_effects effects;
    PFN_wsrs_frame_end frame_end;
    uint64_t view;
} g;

const char *reshade_dir(void) {
    static char p[1100];
    if (!p[0]) snprintf(p, sizeof p, "%s/reshade", rt_exe_dir());
    return p;
}

const char *reshade_dll_path(void) {
    static char p[1100];
    if (!p[0]) snprintf(p, sizeof p, "%s/ReShade64.dll", reshade_dir());
    return p;
}

bool reshade_dll_present(void) {
    struct stat st;
    return stat(reshade_dll_path(), &st) == 0;
}

bool reshade_loaded(void) { return g.loaded; }
bool reshade_depth_active(void) { return g.attached; }

// ---------------------------------------------------------------- the DLL from the start screen (reshade_import)

static unsigned char *read_all(const char *path, size_t *n) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    unsigned char *b = sz > 0 && sz < (256L << 20) ? malloc((size_t)sz) : NULL;
    if (b && fread(b, 1, (size_t)sz, f) != (size_t)sz) free(b), b = NULL;
    fclose(f);
    *n = b ? (size_t)sz : 0;
    return b;
}

static uint32_t u16(const unsigned char *p) { return p[0] | p[1] << 8; }
static uint32_t u32(const unsigned char *p) { return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24; }

static bool has_bytes(const unsigned char *b, size_t n, const char *s) {
    size_t k = strlen(s);
    for (size_t i = 0; i + k <= n; i++)
        if (b[i] == (unsigned char)s[0] && !memcmp(b + i, s, k)) return true;
    return false;
}

// A 64-bit Windows DLL (its PE header's machine: x64)
static bool pe_x64(const unsigned char *b, size_t n) {
    if (n < 0x40 || b[0] != 'M' || b[1] != 'Z') return false;
    uint32_t pe = u32(b + 0x3c);
    return pe + 6 <= n && !memcmp(b + pe, "PE\0\0", 4) && u16(b + pe + 4) == 0x8664;
}

// ReShade's setup program is the program with a ZIP archive appended (its offsets the archive's own): its
// ReShade64.dll, inflated. NULL: not there.
static unsigned char *zip_entry(const unsigned char *b, size_t n, const char *want, size_t *out_n) {
    if (n < 22) return NULL;
    size_t lo = n > 65557 ? n - 65557 : 0, e = n - 22 + 1;
    while (e-- > lo)
        if (u32(b + e) == 0x06054b50) break;
    if (e < lo || u32(b + e) != 0x06054b50) return NULL;
    uint32_t cd_size = u32(b + e + 12), cd_off = u32(b + e + 16), count = u16(b + e + 10);
    if (cd_size > e) return NULL;
    size_t cd = e - cd_size;
    if (cd < cd_off) return NULL;
    size_t shift = cd - cd_off;  // (where the archive starts in the file)
    size_t p = cd;
    for (uint32_t i = 0; i < count && p + 46 <= e; i++) {
        if (u32(b + p) != 0x02014b50) return NULL;
        uint32_t method = u16(b + p + 10), csize = u32(b + p + 20), usize = u32(b + p + 24);
        uint32_t nl = u16(b + p + 28), xl = u16(b + p + 30), cl = u16(b + p + 32), loc = u32(b + p + 42);
        const char *name = (const char *)b + p + 46;
        const char *base = name;  // (its file name, without folders)
        for (uint32_t k = 0; k < nl; k++)
            if (name[k] == '/' || name[k] == '\\') base = name + k + 1;
        if ((size_t)(name + nl - base) == strlen(want) && !strncasecmp(base, want, strlen(want))) {
            size_t lh = shift + loc;
            if (lh + 30 > n || u32(b + lh) != 0x04034b50) return NULL;
            size_t data = lh + 30 + u16(b + lh + 26) + u16(b + lh + 28);
            if (data + csize > n || usize > (128u << 20)) return NULL;
            unsigned char *o = malloc(usize ? usize : 1);
            if (!o) return NULL;
            if (method == 0 && csize == usize) {
                memcpy(o, b + data, usize);
            } else if (method == 8) {
                z_stream z = {0};
                z.next_in = (Bytef *)(b + data), z.avail_in = csize, z.next_out = o, z.avail_out = usize;
                bool ok = inflateInit2(&z, -MAX_WBITS) == Z_OK && inflate(&z, Z_FINISH) == Z_STREAM_END && z.total_out == usize;
                inflateEnd(&z);
                if (!ok) { free(o); return NULL; }
            } else {
                free(o);
                return NULL;
            }
            *out_n = usize;
            return o;
        }
        p += 46 + nl + xl + cl;
    }
    return NULL;
}

bool reshade_import(const char *src, char *msg, size_t n) {
    size_t sz = 0, dn = 0;
    unsigned char *b = read_all(src, &sz), *dll = NULL;
    if (!b) { snprintf(msg, n, "That file couldn't be read."); return false; }
    if (sz < 2 || b[0] != 'M' || b[1] != 'Z') {
        free(b);
        snprintf(msg, n, "That isn't ReShade: choose ReShade64.dll, or ReShade's setup program (ReShade_Setup_....exe).");
        return false;
    }
    bool from_setup = false;
    if ((dll = zip_entry(b, sz, "ReShade64.dll", &dn))) {
        from_setup = true;
        free(b);
    } else {
        dll = b, dn = sz;
    }
    if (!has_bytes(dll, dn, "ReShadeRegisterAddon")) {
        free(dll);
        snprintf(msg, n, "That isn't ReShade: choose ReShade64.dll, or ReShade's setup program (ReShade_Setup_....exe).");
        return false;
    }
    if (!pe_x64(dll, dn)) {
        free(dll);
        snprintf(msg, n, "That's the 32-bit ReShade (ReShade32.dll): WSword needs ReShade64.dll.");
        return false;
    }
    mkdir(reshade_dir(), 0755);
    char part[1200];
    snprintf(part, sizeof part, "%s.part", reshade_dll_path());
    FILE *f = fopen(part, "wb");
    bool ok = f && fwrite(dll, 1, dn, f) == dn;
    if (f && fclose(f) != 0) ok = false;
    free(dll);
    if (ok) {
        remove(reshade_dll_path());  // (Windows' rename doesn't replace)
        ok = rename(part, reshade_dll_path()) == 0;
    }
    if (!ok) {
        remove(part);
        snprintf(msg, n, "Copying it failed: is WSword running? Close it, then add ReShade again.");
        return false;
    }
    fprintf(stderr, "[reshade] ReShade64.dll added from %s%s (%zu bytes)\n", src, from_setup ? " (its setup program)" : "", dn);
    snprintf(msg, n, "ReShade added%s. Turn it on in Settings > Video > ReShade, then restart WSword.",
             from_setup ? " (ReShade64.dll, from its setup program)" : "");
    return true;
}

#ifdef _WIN32
#include <windows.h>

void *dlss_bridge_proc(const char *name);  // (dlss.c: wsword_dlss.dll's export, after its ABI check)

static void wpath(const char *u, wchar_t *w, int n) {
    MultiByteToWideChar(CP_UTF8, 0, u, -1, w, n);
    for (wchar_t *p = w; *p; p++)
        if (*p == L'/') *p = L'\\';
}

static bool file_is(const char *path, const char *text) {  // (the file holds exactly `text`)
    size_t n = 0;
    unsigned char *b = read_all(path, &n);
    bool same = b && n == strlen(text) && !memcmp(b, text, n);
    free(b);
    return same;
}

static bool write_text(const char *path, const char *text) {
    FILE *f = fopen(path, "wb");
    if (!f) return false;
    bool ok = fwrite(text, 1, strlen(text), f) == strlen(text);
    return fclose(f) == 0 && ok;
}

// The layer's manifest, next to the DLL (ReShade's own, setup/ReShade64.json, as its installer writes it)
static bool write_manifest(void) {
    static const char json[] =
        "{\n"
        "\t\"file_format_version\": \"1.0.0\",\n"
        "\t\"layer\": {\n"
        "\t\t\"name\": \"" LAYER_NAME "\",\n"
        "\t\t\"type\": \"GLOBAL\",\n"
        "\t\t\"library_path\": \".\\\\ReShade64.dll\",\n"
        "\t\t\"api_version\": \"1.3.268\",\n"
        "\t\t\"implementation_version\": \"1\",\n"
        "\t\t\"description\": \"crosire's ReShade post-processing injector for 64-bit (loaded by WSword)\",\n"
        "\t\t\"device_extensions\": [\n"
        "\t\t\t{\n"
        "\t\t\t\t\"name\": \"VK_EXT_tooling_info\",\n"
        "\t\t\t\t\"spec_version\": \"1\",\n"
        "\t\t\t\t\"entrypoints\": [ \"vkGetPhysicalDeviceToolPropertiesEXT\" ]\n"
        "\t\t\t}\n"
        "\t\t],\n"
        "\t\t\"disable_environment\": {\n"
        "\t\t\t\"DISABLE_VK_LAYER_reshade_1\": \"1\"\n"
        "\t\t}\n"
        "\t}\n"
        "}\n";
    char p[1200];
    snprintf(p, sizeof p, "%s/ReShade64.json", reshade_dir());
    return file_is(p, json) || write_text(p, json);
}

// ReShade.ini's [ADDON] DisabledAddons (a comma-separated list): "Generic Depth" in it or not - ReShade's own depth
// detection, which WSword's depth replaces (and which looks at every draw the game makes: CPU time saved without it).
// A new ReShade.ini gets the search paths ReShade's installer sets (reshade-shaders\Shaders and \Textures).
static void ini_generic_depth(const char *ini, bool off) {
    size_t n = 0;
    unsigned char *b = read_all(ini, &n);
    if (!b) {
        char t[600];
        snprintf(t, sizeof t,
                 "[GENERAL]\r\nEffectSearchPaths=.\\reshade-shaders\\Shaders\\**\r\n"
                 "TextureSearchPaths=.\\reshade-shaders\\Textures\\**\r\n%s",
                 off ? "\r\n[ADDON]\r\nDisabledAddons=Generic Depth\r\n" : "");
        if (write_text(ini, t)) LOG("[reshade] %s made\n", ini);
        return;
    }
    char *s = malloc(n + 1);
    memcpy(s, b, n), s[n] = 0;
    free(b);
    // the [ADDON] section and its DisabledAddons line
    char *sec = NULL, *line = NULL, *line_end = NULL;  // (the end of [ADDON]'s heading line; its DisabledAddons line)
    bool in = false;
    for (char *p = s; *p;) {
        char *e = p + strcspn(p, "\r\n");
        while (*p == ' ' || *p == '\t') p++;
        if (*p == '[') {
            in = !strncasecmp(p, "[ADDON]", 7);
            if (in && !sec) sec = e;
        } else if (in && !strncasecmp(p, "DisabledAddons=", 15)) {
            line = p, line_end = e;
            break;
        }
        p = e;
        while (*p == '\r' || *p == '\n') p++;
    }
    char list[1024] = "";
    bool had = false;
    if (line) {  // (the others as they are)
        char *v = line + 15;
        size_t vl = (size_t)(line_end - v);
        for (size_t i = 0; i < vl;) {
            size_t j = i;
            while (j < vl && v[j] != ',') j++;
            if (j - i == 13 && !strncmp(v + i, "Generic Depth", 13)) had = true;
            else if (j > i && strlen(list) + (j - i) + 2 < sizeof list)
                snprintf(list + strlen(list), sizeof list - strlen(list), "%s%.*s", list[0] ? "," : "", (int)(j - i), v + i);
            i = j + 1;
        }
    }
    if (had == off) { free(s); return; }  // (as it should be)
    if (off) snprintf(list + strlen(list), sizeof list - strlen(list), "%sGeneric Depth", list[0] ? "," : "");
    size_t cap = n + sizeof list + 64;
    char *o = malloc(cap);
    if (line) snprintf(o, cap, "%.*sDisabledAddons=%s%s", (int)(line - s), s, list, line_end);
    else if (sec) snprintf(o, cap, "%.*s\r\nDisabledAddons=%s%s", (int)(sec - s), s, list, sec);
    else snprintf(o, cap, "%s%s[ADDON]\r\nDisabledAddons=%s\r\n", s, n && s[n - 1] != '\n' ? "\r\n\r\n" : "\r\n", list);
    if (write_text(ini, o))
        LOG("[reshade] %s: ReShade's Generic Depth add-on %s\n", ini, off ? "off (WSword's depth instead)" : "on again");
    free(o);
    free(s);
}

static void log_line(const char *line) { LOG("%s", line); }

static void restore_layer_path(void) {
    if (!g.set_layer_path) return;
    g.set_layer_path = false;
    SetEnvironmentVariableW(L"VK_LAYER_PATH", g.old_layer_path[0] ? g.old_layer_path : NULL);
}

int reshade_instance_layers(const char **names, int max) {
    if (g.tried) return 0;
    g.tried = true;
    if (!g_settings.reshade || max < 1) return 0;
    if (getenv("SAVAGEWIND_NO_RESHADE")) { snprintf(g.why, sizeof g.why, "turned off (SAVAGEWIND_NO_RESHADE)"); return 0; }
    if (!reshade_dll_present()) {
        snprintf(g.why, sizeof g.why, "add your ReShade on the start screen: Settings > Files > ReShade");
        LOG("[reshade] not loaded: no %s\n", reshade_dll_path());
        return 0;
    }
    if (!write_manifest()) {
        snprintf(g.why, sizeof g.why, "its layer manifest couldn't be written in %s", reshade_dir());
        LOG("[reshade] not loaded: %s\n", g.why);
        return 0;
    }
    // its base path: WSword's folder when ReShade's installer already put a ReShade.ini there, else the reshade folder
    char ini[1200];
    snprintf(ini, sizeof ini, "%s/ReShade.ini", rt_exe_dir());
    struct stat st;
    wchar_t w[1100];
    if (stat(ini, &st) == 0) {
        snprintf(g.base, sizeof g.base, "%s", rt_exe_dir());
    } else {
        snprintf(g.base, sizeof g.base, "%s", reshade_dir());
        wpath(g.base, w, 1100);
        SetEnvironmentVariableW(L"RESHADE_BASE_PATH_OVERRIDE", w);
        snprintf(ini, sizeof ini, "%s/ReShade.ini", g.base);
    }
    g.own_depth = g_settings.reshade_own_depth;
    ini_generic_depth(ini, !g.own_depth);
    // (as a layer ReShade loads only for programs its installer set up - a ReShade.ini there - unless told otherwise)
    SetEnvironmentVariableW(L"RESHADE_DISABLE_LOADING_CHECK", L"1");
    // the folder on the loader's layer path, before its own (VK_ADD_LAYER_PATH: Vulkan loader 1.3.234+; an older one
    // takes VK_LAYER_PATH, which replaces its explicit layers' folders - only for this instance)
    wpath(reshade_dir(), w, 1100);
    wchar_t old[4096] = L"", path[5200];
    DWORD ol = GetEnvironmentVariableW(L"VK_ADD_LAYER_PATH", old, 4096);
    _snwprintf(path, 5200, ol && ol < 4096 ? L"%ls;%ls" : L"%ls", w, old);
    path[5199] = 0;
    SetEnvironmentVariableW(L"VK_ADD_LAYER_PATH", path);
    bool found = false;
    for (int pass = 0; pass < 2 && !found; pass++) {
        if (pass == 1) {
            DWORD l = GetEnvironmentVariableW(L"VK_LAYER_PATH", g.old_layer_path, 4096);
            if (!l || l >= 4096) g.old_layer_path[0] = 0;
            g.set_layer_path = true;
            SetEnvironmentVariableW(L"VK_LAYER_PATH", w);
        }
        uint32_t nl = 0;
        vkEnumerateInstanceLayerProperties(&nl, NULL);
        VkLayerProperties *lp = calloc(nl ? nl : 1, sizeof *lp);
        vkEnumerateInstanceLayerProperties(&nl, lp);
        for (uint32_t i = 0; i < nl && !found; i++) found = !strcmp(lp[i].layerName, LAYER_NAME);
        free(lp);
        if (found) LOG("[reshade] layer found%s\n", pass ? " (VK_LAYER_PATH: an older Vulkan loader)" : "");
    }
    if (!found) {
        restore_layer_path();
        snprintf(g.why, sizeof g.why, "the Vulkan loader didn't find ReShade's layer (with WSword run as administrator "
                                      "it ignores the folder: run it normally)");
        LOG("[reshade] not loaded: %s\n", g.why);
        return 0;
    }
    g.layer = true;
    names[0] = LAYER_NAME;
    LOG("[reshade] loading %s as a Vulkan layer (its files in %s; depth: %s)\n", reshade_dll_path(), g.base,
        g.own_depth ? "ReShade's own detection" : "the game's, from WSword");
    return 1;
}

void reshade_instance_made(bool with_layer) {
    if (!g.layer) return;
    restore_layer_path();
    if (!with_layer) {
        g.layer = false;
        snprintf(g.why, sizeof g.why, "the Vulkan instance failed with ReShade: WSword started without it (ReShade.log in %s)", g.base);
        LOG("[reshade] %s\n", g.why);
        return;
    }
    g.loaded = GetModuleHandleW(L"ReShade64.dll") != NULL;
    if (!g.loaded) {
        snprintf(g.why, sizeof g.why, "ReShade didn't load (its ReShade.log in %s may say why)", g.base);
        LOG("[reshade] %s\n", g.why);
        return;
    }
    LOG("[reshade] ReShade is loaded: its menu opens with the Home key\n");
    if (g.own_depth) return;
    PFN_wsrs_attach attach = (PFN_wsrs_attach)dlss_bridge_proc("wsrs_attach");
    g.depth = (PFN_wsrs_depth)dlss_bridge_proc("wsrs_depth");
    if (!attach || !g.depth) {
        snprintf(g.why, sizeof g.why, "wsword_dlss.dll is missing or from another WSword: ReShade finds its depth itself");
        LOG("[reshade] no game depth for it: %s\n", g.why);
        return;
    }
    if (!attach(log_line, g.why, sizeof g.why)) {
        LOG("[reshade] no game depth for it: %s\n", g.why);
        return;
    }
    g.attached = true;
    g.effects = (PFN_wsrs_effects)dlss_bridge_proc("wsrs_effects");
    g.frame_end = (PFN_wsrs_frame_end)dlss_bridge_proc("wsrs_frame_end");
}

bool reshade_can_draw(void) { return g.attached && g.effects && g.frame_end; }

bool reshade_draw(uint64_t rtv, uint64_t rtv_srgb, uint64_t depth) {
    if (!reshade_can_draw()) return false;
    g.view = depth;  // (the present's own view is bound again when it differs: reshade_set_depth)
    return g.effects(rtv, rtv_srgb, depth) != 0;
}

void reshade_frame_end(void) {
    if (reshade_can_draw()) g.frame_end();
}

void reshade_set_depth(VkImageView view) {
    if (!g.attached || (uint64_t)view == g.view) return;
    g.view = (uint64_t)view;
    g.depth((uint64_t)view);
}

void reshade_status(char *out, size_t n) {
    struct stat st;
    bool have = stat(reshade_dll_path(), &st) == 0;
    if (g.loaded)
        snprintf(out, n, "ReShade: running - its menu opens with the Home key. Depth for its effects: %s.",
                 g.attached ? "the game's, from WSword"
                 : g.own_depth ? "ReShade's own detection (Generic Depth)"
                               : "ReShade's own detection, as WSword's couldn't be given");
    else if (g.layer || (g.tried && g_settings.reshade && g.why[0]))
        snprintf(out, n, "ReShade: not running - %s.", g.why[0] ? g.why : "it didn't load");
    else if (!have)
        snprintf(out, n, "ReShade: not added. Add your ReShade on the start screen: Settings > Files > ReShade.");
    else if (g_settings.reshade)
        snprintf(out, n, "ReShade: added (%.1f MB) - on from WSword's next start.", st.st_size / 1048576.0);
    else
        snprintf(out, n, "ReShade: added (%.1f MB), off.", st.st_size / 1048576.0);
    if (g.loaded && !g_settings.reshade) snprintf(out + strlen(out), n - strlen(out), " Off from WSword's next start.");
}

#else  // (ReShade on Windows only)

int reshade_instance_layers(const char **names, int max) { (void)names, (void)max; return 0; }
bool reshade_can_draw(void) { return false; }
bool reshade_draw(uint64_t rtv, uint64_t rtv_srgb, uint64_t depth) { (void)rtv, (void)rtv_srgb, (void)depth; return false; }
void reshade_frame_end(void) {}
void reshade_instance_made(bool with_layer) { (void)with_layer; }
void reshade_set_depth(VkImageView view) { (void)view; }
void reshade_status(char *out, size_t n) {
    snprintf(out, n, "ReShade: WSword loads ReShade on Windows.%s", reshade_dll_present() ? " (ReShade64.dll added.)" : "");
}

#endif
