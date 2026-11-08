// (WSword, from 0.2.8) Settings > Mods: the game mods in mods/ (runtime/mods.h), each on or off with its own note (its
// .txt: the authors, the credits) as the description; Import a mod folder (the folder picker, then a copy into mods/ on
// a thread of its own); Open the mods folder. On or off applies when the game starts again.
#include "mods_tab.h"

#include <SDL3/SDL.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>
#include <string>

#include "i18n.h"
#include "imgui.h"
#include "option_rows.h"

extern "C" {
#include "../mods.h"
#include "../paths.h"
#include "../romfs_build.h"
#include "../rt.h"
#include "../settings.h"
}

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static std::string g_msg;  // the last import's outcome: "1|<name>" imported, "0|<reason>" failed, "2|" cancelled
static bool g_busy;
static std::string g_pick;

// The folder picked: the one with a romfs folder inside, or the folder around a picked romfs, copied into mods/
static void *copy_mod(void *) {
    std::string src = g_pick;
    for (char &c : src) if (c == '\\') c = '/';
    while (src.size() > 3 && src.back() == '/') src.pop_back();
    struct stat st;
    std::string base = src.substr(src.find_last_of('/') + 1), msg;
    if (!strcasecmp(base.c_str(), "romfs")) {  // (romfs itself picked: its folder is the mod)
        src = src.substr(0, src.find_last_of('/'));
        base = src.substr(src.find_last_of('/') + 1);
    }
    if (stat((src + "/romfs").c_str(), &st) != 0 || !S_ISDIR(st.st_mode)) {
        msg = "0|That folder has no romfs folder inside: pick the mod's own folder (extracted from its ZIP / RAR / 7z).";
    } else {
        std::string dst = std::string(rt_data_root()) + "/mods";
        mkdir(dst.c_str(), 0755);
        dst += "/" + base;
        msg = romfs_copy_tree(src.c_str(), dst.c_str(), NULL) ? "1|" + base : "0|Copying the mod failed (disk full?).";
        fprintf(stderr, "[mods] import %s -> %s: %s\n", src.c_str(), dst.c_str(), msg[0] == '1' ? "done" : "failed");
    }
    pthread_mutex_lock(&g_lock);
    g_msg = msg;
    g_busy = false;
    pthread_mutex_unlock(&g_lock);
    return NULL;
}

static void SDLCALL picked_mod(void *, const char *const *files, int) {
    pthread_mutex_lock(&g_lock);
    bool go = files && files[0];
    if (go) g_pick = files[0];
    else g_busy = false, g_msg = "2|";
    pthread_mutex_unlock(&g_lock);
    if (!go) return;
    pthread_t t;
    if (pthread_create(&t, NULL, copy_mod, NULL) == 0) pthread_detach(t);
}

static void import_mod(void) {
    pthread_mutex_lock(&g_lock);
    g_busy = true, g_msg.clear();
    pthread_mutex_unlock(&g_lock);
    SDL_ShowOpenFolderDialog(picked_mod, NULL, NULL, NULL, false);
}

static void open_mods_folder(void) {
    std::string path = std::string(rt_data_root()) + "/mods";
    mkdir(path.c_str(), 0755);
    std::string url = "file://";
    if (path[0] != '/') url += "/";  // (Windows: file:///C:/...)
    for (char ch : path) {
        if (ch == '\\') ch = '/';
        if (ch == ' ') url += "%20";
        else if (ch == '%') url += "%25";
        else if (ch == '#') url += "%23";
        else url += ch;
    }
    SDL_OpenURL(url.c_str());
}

void mods_tab_draw(float scale, bool in_game) {
    opt_begin("##mods", scale);
    opt_section("Mods");
    ImGui::PushTextWrapPos(0);
    ImGui::TextDisabled("%s", tr("Mods replace the game's files and add new ones: each is a folder with a romfs folder inside, "
                                 "laid out as for Ryujinx, Yuzu or Eden (made for your game version). Where two mods have "
                                 "the same file, the one first in this list wins. A mod's DLC files go in its romfs\\aoc\\0010, "
                                 "or in a mod folder named 01007EF00011F001 (as BCML makes them)."));
    if (in_game)
        ImGui::TextColored(ImVec4(1.0f, 0.75f, 0.3f, 1.0f), "%s",
                           tr("Turning one on or off applies when the game starts again: Quit > Return to the start screen, "
                              "then Play."));
    ImGui::PopTextWrapPos();
    ImGui::Spacing();
    static ModInfo mods[MODS_MAX];
    static int n = -1;
    static double at;
    double now = SDL_GetTicks() / 1000.0;
    if (n < 0 || now - at > 1) n = mods_list(mods, MODS_MAX), at = now;  // (once a second: a copy can land meanwhile)
    if (!n) ImGui::TextDisabled("%s", tr("No mods yet. Import one below, or put its folder into the mods folder."));
    bool dlc_mod = false;
    for (int i = 0; i < n; i++) {
        static char notes[MODS_MAX][1600];
        static char note_of[MODS_MAX][96];
        if (strcmp(note_of[i], mods[i].name)) {  // (read once per mod)
            mods_note(mods[i].name, notes[i], sizeof notes[i]);
            if (!notes[i][0]) snprintf(notes[i], sizeof notes[i], "%s", tr(mods[i].dlc ? "The DLC's files." : "No notes in its folder."));
            snprintf(note_of[i], sizeof note_of[i], "%s", mods[i].name);
        }
        bool on = mods[i].on;
        if (opt_toggle(mods[i].name, &on, true, notes[i])) {
            mods_set(mods[i].name, on);
            mods[i].on = on;
            settings_save();
        }
        dlc_mod |= mods[i].on && mods[i].dlc;
    }
    if (dlc_mod && !fs_aoc_present(1)) {  // (Relics of the Past and other DLC mods close the game at the title without it)
        ImGui::Spacing();
        ImGui::PushTextWrapPos(0);
        ImGui::TextColored(ImVec4(1.0f, 0.75f, 0.3f, 1.0f), "%s",
                           tr("A mod for the DLC is on, but the DLC isn't set up (Settings > Files). Mods made with it close "
                              "the game at the title screen without it."));
        ImGui::PopTextWrapPos();
    }
    ImGui::Spacing();
    pthread_mutex_lock(&g_lock);
    bool busy = g_busy;
    std::string msg = g_msg;
    pthread_mutex_unlock(&g_lock);
    ImGui::BeginDisabled(busy);
    if (opt_button("Import a mod folder", "Pick the mod's folder (the one with romfs inside, already extracted from its ZIP / "
                                          "RAR / 7z): it's copied into the mods folder."))
        import_mod();
    ImGui::EndDisabled();
    if (opt_button("Open the mods folder", "The mods folder in WSword's data folder: put mod folders here yourself, or take "
                                           "them out."))
        open_mods_folder();
    if (busy) ImGui::TextDisabled("%s", tr("Copying the mod..."));
    else if (msg.size() > 1) {
        char line[400];
        if (msg[0] == '1') snprintf(line, sizeof line, tr("Imported %s. It's on from the game's next start."), msg.c_str() + 2);
        else if (msg[0] == '2') snprintf(line, sizeof line, "%s", tr("Import cancelled."));
        else snprintf(line, sizeof line, tr("Import failed: %s"), tr(msg.c_str() + 2));
        ImGui::PushTextWrapPos(0);
        ImGui::TextUnformatted(line);
        ImGui::PopTextWrapPos();
    }
    opt_end();
}
