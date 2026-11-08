// (WSword) Game mods (mods.h), from WSword 0.2.8's
#include "mods.h"

#include <ctype.h>
#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>

#include "settings.h"

static bool has_ci(const char *s, const char *what) {  // (case-insensitive strstr)
    size_t n = strlen(what);
    for (; *s; s++) {
        size_t i = 0;
        while (i < n && s[i] && tolower((unsigned char)s[i]) == tolower((unsigned char)what[i])) i++;
        if (i == n) return true;
    }
    return false;
}

static bool is_off(const char *name) {  // (mods_off: names separated by '|')
    size_t n = strlen(name);
    for (const char *s = g_settings.mods_off; *s;) {
        const char *e = strchr(s, '|');
        size_t l = e ? (size_t)(e - s) : strlen(s);
        if (l == n && !strncmp(s, name, n)) return true;
        if (!e) break;
        s = e + 1;
    }
    return false;
}

static bool is_dir(const char *p) {
    struct stat sb;
    return stat(p, &sb) == 0 && S_ISDIR(sb.st_mode);
}

// A mod's folder: mods/<name>, or the folder mods/<name>.link names (as 0.2.8 kept a mod used in place). false: neither.
static bool mod_base(const char *name, char *out, size_t cap) {
    char p[1200];
    snprintf(out, cap, "mods/%s", name);
    snprintf(p, sizeof p, "%s/romfs", out);
    if (is_dir(p)) return true;
    snprintf(p, sizeof p, "mods/%s.link", name);
    FILE *f = fopen(p, "rb");
    if (!f) return false;
    size_t n = fread(out, 1, cap - 1, f);
    fclose(f);
    out[n] = 0;
    while (n && (out[n - 1] == '\n' || out[n - 1] == '\r' || out[n - 1] == '/' || out[n - 1] == '\\')) out[--n] = 0;
    snprintf(p, sizeof p, "%s/romfs", out);
    return n && is_dir(p);
}

static int by_name(const void *a, const void *b) { return strcmp(((const ModInfo *)a)->name, ((const ModInfo *)b)->name); }

int mods_list(ModInfo *out, int max) {
    DIR *d = opendir("mods");  // (the data folder is the working directory: paths.h)
    if (!d) return 0;
    int n = 0;
    struct dirent *e;
    while ((e = readdir(d)) && n < max) {
        char name[sizeof out->name], base[1024];
        size_t l = strlen(e->d_name);
        if (e->d_name[0] == '.' || l >= sizeof name) continue;
        memcpy(name, e->d_name, l + 1);
        if (l > 5 && !strcasecmp(name + l - 5, ".link")) name[l - 5] = 0;  // (in place)
        if (!mod_base(name, base, sizeof base)) continue;
        bool dup = false;  // (a folder and a .link of one name: once)
        for (int k = 0; k < n && !dup; k++) dup = !strcmp(out[k].name, name);
        if (dup) continue;
        snprintf(out[n].name, sizeof out[n].name, "%s", name);
        out[n].on = !is_off(name);
        out[n].dlc = has_ci(name, "01007EF00011F001");
        n++;
    }
    closedir(d);
    qsort(out, (size_t)n, sizeof *out, by_name);
    return n;
}

void mods_set(const char *name, bool on) {
    char list[sizeof g_settings.mods_off] = "";
    for (const char *s = g_settings.mods_off; *s;) {  // the others as they were
        const char *e = strchr(s, '|');
        size_t l = e ? (size_t)(e - s) : strlen(s);
        if (l && !(l == strlen(name) && !strncmp(s, name, l))) {
            size_t k = strlen(list);
            if (k + l + 2 < sizeof list) snprintf(list + k, sizeof list - k, "%s%.*s", k ? "|" : "", (int)l, s);
        }
        if (!e) break;
        s = e + 1;
    }
    size_t k = strlen(list);
    if (!on && k + strlen(name) + 2 < sizeof list) snprintf(list + k, sizeof list - k, "%s%s", k ? "|" : "", name);
    snprintf(g_settings.mods_off, sizeof g_settings.mods_off, "%s", list);
}

int mods_roots(bool dlc, char (*out)[1100], int max) {
    ModInfo m[MODS_MAX];
    int n = mods_list(m, MODS_MAX), k = 0;
    for (int i = 0; i < n && k < max; i++) {
        char b[1024];
        if (!m[i].on || !mod_base(m[i].name, b, sizeof b)) continue;
        if (m[i].dlc) {  // (the DLC's own files: never over the game's of the same paths, #65)
            if (dlc) snprintf(out[k++], 1100, "%s/romfs/", b);
        } else if (!dlc) {
            snprintf(out[k++], 1100, "%s/romfs/", b);
        } else {
            char p[1100];
            snprintf(p, sizeof p, "%s/romfs/aoc/0010", b);
            if (is_dir(p)) snprintf(out[k++], 1100, "%s/romfs/aoc/0010/", b);
        }
    }
    return k;
}

const char *mods_note(const char *name, char *buf, size_t cap) {
    buf[0] = 0;
    char dirp[1024];
    if (!mod_base(name, dirp, sizeof dirp)) return buf;
    DIR *d = opendir(dirp);
    if (!d) return buf;
    struct dirent *e;
    while ((e = readdir(d))) {
        size_t l = strlen(e->d_name);
        if (l < 5 || strcasecmp(e->d_name + l - 4, ".txt")) continue;
        char p[1400];
        snprintf(p, sizeof p, "%s/%s", dirp, e->d_name);
        FILE *f = fopen(p, "rb");
        if (!f) continue;
        size_t n = fread(buf, 1, cap - 1, f);
        fclose(f);
        buf[n] = 0;
        size_t o = 0;  // (printable text only; a UTF-8 BOM and control characters left out)
        for (size_t i = 0; i < n; i++) {
            unsigned char c = (unsigned char)buf[i];
            if (i < 3 && (c == 0xEF || c == 0xBB || c == 0xBF)) continue;
            if (c < 0x20 && c != '\n' && c != '\t') continue;
            buf[o++] = (char)c;
        }
        buf[o] = 0;
        break;
    }
    closedir(d);
    return buf;
}
