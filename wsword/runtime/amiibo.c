// (WSword) Virtual amiibo: the figures (amiibo_list.inc), the player's choices and the game's data for each figure
// (amiibo/), and nfp:user - the game's NFC service - with one reader that finds the figure tapped in the amiibo bar.
// See amiibo.h.
//
// nfp:user's IUser (the commands, their structures and results as the console's: Ryujinx's and yuzu's NFP services):
//   0 Initialize, 1 Finalize, 2 ListDevices, 3 StartDetection, 4 StopDetection, 5 Mount, 6 Unmount,
//   7 OpenApplicationArea, 8 GetApplicationArea, 9 SetApplicationArea, 10 Flush, 11 Restore, 12 CreateApplicationArea,
//   13 GetTagInfo, 14 GetRegisterInfo, 15 GetCommonInfo, 16 GetModelInfo, 17 AttachActivateEvent,
//   18 AttachDeactivateEvent, 19 GetState, 20 GetDeviceState, 21 GetNpadId, 22 GetApplicationAreaSize,
//   23 AttachAvailabilityChangeEvent, 24 RecreateApplicationArea
#include <errno.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>

#include "amiibo.h"
#include "hle.h"
#include "ipc.h"

#include "amiibo_list.inc"

enum { NFP_MODULE = 115 };
#define NFP_ERR(desc) MAKE_RESULT(NFP_MODULE, desc)
enum {   // (the console's results)
    ERR_DEVICE_NOT_FOUND = 64, ERR_WRONG_DEVICE_STATE = 73, ERR_TAG_NOT_FOUND = 97, ERR_AREA_NULL = 128,
    ERR_ACCESS_ID_MISMATCH = 152, ERR_AREA_EXISTS = 168, ERR_AREA_TOO_LARGE = 178
};
enum { DEV_INITIALIZED, DEV_SEARCHING, DEV_TAG_FOUND, DEV_TAG_REMOVED, DEV_TAG_MOUNTED, DEV_UNAVAILABLE, DEV_FINALIZED };
enum { AREA_SIZE = 0xd8 };

static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;

// ------------------------------------------------------------------ the list
int amiibo_count(void) { return (int)(sizeof k_amiibo / sizeof *k_amiibo); }
const AmiiboDef *amiibo_at(int i) { return i >= 0 && i < amiibo_count() ? &k_amiibo[i] : NULL; }
int amiibo_index(uint64_t id) {
    for (int i = 0; i < amiibo_count(); i++) if (k_amiibo[i].id == id) return i;
    return -1;
}
const char *amiibo_group_name(int g) {
    return g >= 0 && g < (int)(sizeof k_amiibo_groups / sizeof *k_amiibo_groups) ? k_amiibo_groups[g] : "";
}

// ------------------------------------------------------------------ the player's choices (amiibo/amiibo.ini)
enum { MAX_FAV = 64, MAX_USED = 256 };
static bool g_loaded, g_daily = true;
static uint64_t g_fav[MAX_FAV];
static int g_nfav;
static struct { uint64_t id; int date; } g_used[MAX_USED];   // (date: yyyymmdd, the day it was last tapped)
static int g_nused;
static uint64_t g_last;

static void today(int *y, int *m, int *d) {
    time_t t = time(NULL);
    struct tm tm;
#ifdef __PROSPERO__
    // (a title's libc knows no time zone: the console's own offset, as services/time.c)
    int sceSystemServiceParamGetInt(int id, int *value);
    int zone = 0, summer = 0;
    if (sceSystemServiceParamGetInt(4, &zone) != 0) zone = 0;
    if (sceSystemServiceParamGetInt(5, &summer) != 0) summer = 0;
    t += (time_t)zone * 60 + (summer ? 3600 : 0);
    gmtime_r(&t, &tm);
#else
    localtime_r(&t, &tm);
#endif
    *y = tm.tm_year + 1900, *m = tm.tm_mon + 1, *d = tm.tm_mday;
}
static int today_n(void) { int y, m, d; today(&y, &m, &d); return y * 10000 + m * 100 + d; }

static void save_locked(void) {
    mkdir("amiibo", 0755);
    FILE *f = fopen("amiibo/amiibo.ini", "w");
    if (!f) { LOG("[amiibo] cannot write amiibo/amiibo.ini: %s\n", strerror(errno)); return; }
    fprintf(f, "# WSword's amiibo: the bar's favourites, the once-a-day rule, the day each figure was last tapped\n");
    fprintf(f, "daily = %d\nlast = %016llx\n", g_daily, (unsigned long long)g_last);
    for (int i = 0; i < g_nfav; i++) fprintf(f, "favourite = %016llx\n", (unsigned long long)g_fav[i]);
    for (int i = 0; i < g_nused; i++) fprintf(f, "used = %016llx %d\n", (unsigned long long)g_used[i].id, g_used[i].date);
    fclose(f);
}

static void load_locked(void) {
    if (g_loaded) return;
    g_loaded = true;
    FILE *f = fopen("amiibo/amiibo.ini", "r");
    if (!f) return;
    char line[256];
    while (fgets(line, sizeof line, f)) {
        unsigned long long id;
        int v;
        if (sscanf(line, " daily = %d", &v) == 1) g_daily = v != 0;
        else if (sscanf(line, " last = %llx", &id) == 1) g_last = id;
        else if (sscanf(line, " favourite = %llx", &id) == 1 && g_nfav < MAX_FAV && amiibo_index(id) >= 0) g_fav[g_nfav++] = id;
        else if (sscanf(line, " used = %llx %d", &id, &v) == 2 && g_nused < MAX_USED) g_used[g_nused].id = id, g_used[g_nused++].date = v;
    }
    fclose(f);
}

bool amiibo_favourite(uint64_t id) {
    pthread_mutex_lock(&g_mu);
    load_locked();
    bool on = false;
    for (int i = 0; i < g_nfav; i++) if (g_fav[i] == id) on = true;
    pthread_mutex_unlock(&g_mu);
    return on;
}
void amiibo_set_favourite(uint64_t id, bool on) {
    pthread_mutex_lock(&g_mu);
    load_locked();
    int at = -1;
    for (int i = 0; i < g_nfav; i++) if (g_fav[i] == id) at = i;
    if (on && at < 0 && g_nfav < MAX_FAV) g_fav[g_nfav++] = id;
    if (!on && at >= 0) memmove(&g_fav[at], &g_fav[at + 1], sizeof *g_fav * (size_t)(--g_nfav - at));
    save_locked();
    pthread_mutex_unlock(&g_mu);
}
int amiibo_favourites(uint64_t *out, int max) {
    pthread_mutex_lock(&g_mu);
    load_locked();
    int n = g_nfav < max ? g_nfav : max;
    memcpy(out, g_fav, sizeof *out * (size_t)n);
    pthread_mutex_unlock(&g_mu);
    return n;
}
void amiibo_clear_favourites(void) {
    pthread_mutex_lock(&g_mu);
    load_locked();
    g_nfav = 0;
    save_locked();
    pthread_mutex_unlock(&g_mu);
}
bool amiibo_daily(void) {
    pthread_mutex_lock(&g_mu);
    load_locked();
    bool on = g_daily;
    pthread_mutex_unlock(&g_mu);
    return on;
}
void amiibo_set_daily(bool on) {
    pthread_mutex_lock(&g_mu);
    load_locked();
    g_daily = on;
    save_locked();
    pthread_mutex_unlock(&g_mu);
}
bool amiibo_used_today(uint64_t id) {
    pthread_mutex_lock(&g_mu);
    load_locked();
    int t = today_n();
    bool used = false;
    if (g_daily)
        for (int i = 0; i < g_nused; i++) if (g_used[i].id == id && g_used[i].date == t) used = true;
    pthread_mutex_unlock(&g_mu);
    return used;
}
uint64_t amiibo_last(void) {
    pthread_mutex_lock(&g_mu);
    load_locked();
    uint64_t id = g_last;
    pthread_mutex_unlock(&g_mu);
    return id;
}

// ------------------------------------------------------------------ the reader (nfp:user)
static int g_state = DEV_INITIALIZED;   // DEV_*
static bool g_initialized;
static uint64_t g_tag;                   // the figure found (0: none)
static uint8_t g_uuid[7];
static KEvent *g_ev_activate, *g_ev_deactivate, *g_ev_avail;
static uint32_t g_h_activate, g_h_deactivate, g_h_avail;
// the figure's application area (amiibo/<id>.bin: its access id, then AREA_SIZE bytes) as the game has it open
static bool g_area_open, g_area_exists;
static uint32_t g_area_id;
static uint8_t g_area[AREA_SIZE];
static uint16_t g_write_counter;

static void ev_set(KEvent *e, bool on) {
    if (!e) return;
    klock();
    if (on) kernel_signal(e);
    else e->signaled = false;
    pthread_mutex_unlock(&g_klock);
}
static uint32_t ev_handle(KEvent **e, uint32_t *h) {
    if (!*e) {
        uint32_t w;
        *e = kernel_create_event_pair(&w, h);
    }
    return *h;
}

static void area_path(uint64_t id, char *out, size_t n) { snprintf(out, n, "amiibo/%016llx.bin", (unsigned long long)id); }

// the figure's data from its file (caller holds g_mu)
static void area_load(uint64_t id) {
    char p[64];
    area_path(id, p, sizeof p);
    g_area_exists = false, g_area_open = false, g_write_counter = 0;
    memset(g_area, 0, sizeof g_area);
    FILE *f = fopen(p, "rb");
    if (!f) return;
    uint8_t head[8];
    if (fread(head, 1, 8, f) == 8 && fread(g_area, 1, AREA_SIZE, f) == AREA_SIZE) {
        memcpy(&g_area_id, head, 4);
        memcpy(&g_write_counter, head + 4, 2);
        g_area_exists = true;
    }
    fclose(f);
}
static bool area_save(uint64_t id) {
    char p[64];
    area_path(id, p, sizeof p);
    mkdir("amiibo", 0755);
    FILE *f = fopen(p, "wb");
    if (!f) { LOG("[amiibo] cannot write %s: %s\n", p, strerror(errno)); return false; }
    uint8_t head[8] = {0};
    memcpy(head, &g_area_id, 4);
    memcpy(head + 4, &g_write_counter, 2);
    bool ok = fwrite(head, 1, 8, f) == 8 && fwrite(g_area, 1, AREA_SIZE, f) == AREA_SIZE;
    ok = fclose(f) == 0 && ok;
    return ok;
}

bool amiibo_waiting(void) {
    pthread_mutex_lock(&g_mu);
    bool w = g_initialized && g_state == DEV_SEARCHING;
    pthread_mutex_unlock(&g_mu);
    return w;
}

void amiibo_tap(uint64_t id) {
    pthread_mutex_lock(&g_mu);
    load_locked();
    if (!(g_initialized && g_state == DEV_SEARCHING) || amiibo_index(id) < 0) { pthread_mutex_unlock(&g_mu); return; }
    // its serial number (7 bytes, an NXP tag's first byte 04): the figure's own, always the same, while the
    // once-a-day rule is on; a new one each tap without it
    uint64_t h = id * 0x9e3779b97f4a7c15ull;
    if (!g_daily) h ^= (uint64_t)time(NULL) * 0xbf58476d1ce4e5b9ull ^ (uint64_t)clock() * 0x94d049bb133111ebull;
    h ^= h >> 31;
    g_uuid[0] = 0x04;
    for (int i = 1; i < 7; i++) g_uuid[i] = (uint8_t)(h >> (8 * i));
    g_tag = id, g_last = id, g_state = DEV_TAG_FOUND;
    area_load(id);
    int t = today_n(), at = -1;
    for (int i = 0; i < g_nused; i++) if (g_used[i].id == id) at = i;
    if (at < 0 && g_nused < MAX_USED) at = g_nused++;
    if (at < 0) memmove(&g_used[0], &g_used[1], sizeof *g_used * (MAX_USED - 1)), at = MAX_USED - 1;
    g_used[at].id = id, g_used[at].date = t;
    save_locked();
    const AmiiboDef *a = amiibo_at(amiibo_index(id));
    LOG("[amiibo] %s (%016llx) tapped%s\n", a->name, (unsigned long long)id, g_area_exists ? ", with its saved data" : "");
    pthread_mutex_unlock(&g_mu);
    ev_set(g_ev_deactivate, false);
    ev_set(g_ev_activate, true);
}

// The figure's info structures (the console's layouts)
static void write_out(IpcReq *req, const void *src, size_t n) {
    IpcBuf *b = out_buf(req, 0);
    if (!b || !b->addr) return;
    size_t m = n < b->size ? n : (size_t)b->size;
    memcpy((void *)(uintptr_t)b->addr, src, m);
}

static void tag_info(uint8_t o[0x58]) {   // TagInfo: uuid[10], its length, 21 reserved, protocol, type, 48 reserved
    memset(o, 0, 0x58);
    memcpy(o, g_uuid, 7);
    o[10] = 7;
    uint32_t protocol = 1, type = 2;   // (ISO 14443 A, NFC Forum type 2: an NTAG215)
    memcpy(o + 0x20, &protocol, 4);
    memcpy(o + 0x24, &type, 4);
}
static void common_info(uint8_t o[0x40]) {   // CommonInfo: last write date, write counter, version, area size
    int y, m, d;
    today(&y, &m, &d);
    memset(o, 0, 0x40);
    uint16_t yy = (uint16_t)y, ver = 0;
    uint32_t size = AREA_SIZE;
    memcpy(o, &yy, 2);
    o[2] = (uint8_t)m, o[3] = (uint8_t)d;
    memcpy(o + 4, &g_write_counter, 2);
    memcpy(o + 6, &ver, 2);
    memcpy(o + 8, &size, 4);
}
static void model_info(uint8_t o[0x40]) {   // ModelInfo: character (the id's bytes 0-1 as on the figure), variant, type,
    memset(o, 0, 0x40);                     //  model number (its bytes 4-5, as a number), series
    uint8_t id[8];
    for (int i = 0; i < 8; i++) id[i] = (uint8_t)(g_tag >> (56 - 8 * i));
    o[0] = id[0], o[1] = id[1], o[2] = id[2], o[3] = id[3];
    uint16_t model = (uint16_t)(id[4] << 8 | id[5]);
    memcpy(o + 4, &model, 2);
    o[6] = id[6];
}
static void register_info(uint8_t o[0x100]) {   // RegisterInfo: the owner's Mii (none), first write date, nickname
    int y, m, d;
    today(&y, &m, &d);
    memset(o, 0, 0x100);
    uint16_t yy = (uint16_t)y;
    memcpy(o + 0x58, &yy, 2);
    o[0x5a] = (uint8_t)m, o[0x5b] = (uint8_t)d;
    const AmiiboDef *a = amiibo_at(amiibo_index(g_tag));
    snprintf((char *)o + 0x5c, 11, "%s", a ? a->name : "amiibo");   // (an amiibo's nickname: 10 characters)
}

static int device_ok(IpcResp *resp, int need_min) {   // the device's state allows the command (else its result)
    if (!g_initialized) { resp->result = NFP_ERR(ERR_DEVICE_NOT_FOUND); return 0; }
    if (need_min == DEV_TAG_FOUND && g_state != DEV_TAG_FOUND && g_state != DEV_TAG_MOUNTED) {
        resp->result = NFP_ERR(ERR_TAG_NOT_FOUND);
        return 0;
    }
    if (need_min == DEV_TAG_MOUNTED && g_state != DEV_TAG_MOUNTED) { resp->result = NFP_ERR(ERR_WRONG_DEVICE_STATE); return 0; }
    return 1;
}

static void nfp_user(Service *s, IpcReq *req, IpcResp *resp) {
    (void)s;
    pthread_mutex_lock(&g_mu);
    load_locked();
    switch (req->cmd) {
    case 0:   // Initialize
        g_initialized = true, g_state = DEV_INITIALIZED, g_tag = 0;
        LOG("[amiibo] the game's NFC service: one reader (player 1); amiibo from WSword's amiibo bar\n");
        break;
    case 1: g_initialized = false, g_state = DEV_FINALIZED; break;   // Finalize
    case 2: {   // ListDevices: player 1's controller
        IpcBuf *b = out_buf(req, 0);
        uint64_t handle = 0;
        if (b && b->addr && b->size >= 8) memcpy((void *)(uintptr_t)b->addr, &handle, 8);
        OUT(int32_t, 0) = g_initialized ? 1 : 0;
        resp_size(resp, 4);
        break;
    }
    case 3:   // StartDetection: the bar comes up
        if (!device_ok(resp, DEV_INITIALIZED)) break;
        g_state = DEV_SEARCHING, g_tag = 0, g_area_open = false;
        LOG("[amiibo] the game looks for a figure: the amiibo bar is up\n");
        pthread_mutex_unlock(&g_mu);
        ev_set(g_ev_activate, false);
        pthread_mutex_lock(&g_mu);
        break;
    case 4: {   // StopDetection
        if (!device_ok(resp, DEV_INITIALIZED)) break;
        bool had = g_tag != 0;
        g_state = DEV_INITIALIZED, g_tag = 0, g_area_open = false;
        pthread_mutex_unlock(&g_mu);
        if (had) ev_set(g_ev_deactivate, true);
        ev_set(g_ev_activate, false);
        pthread_mutex_lock(&g_mu);
        break;
    }
    case 5:   // Mount
        if (device_ok(resp, DEV_TAG_FOUND)) g_state = DEV_TAG_MOUNTED;
        break;
    case 6:   // Unmount
        if (device_ok(resp, DEV_TAG_MOUNTED)) g_state = DEV_TAG_FOUND, g_area_open = false;
        break;
    case 7: {   // OpenApplicationArea(access id)
        if (!device_ok(resp, DEV_TAG_MOUNTED)) break;
        uint32_t access = IN(uint32_t, 8);
        if (!g_area_exists) resp->result = NFP_ERR(ERR_AREA_NULL);
        else if (access != g_area_id) resp->result = NFP_ERR(ERR_ACCESS_ID_MISMATCH);
        else g_area_open = true;
        break;
    }
    case 8: {   // GetApplicationArea -> its bytes, their size
        if (!device_ok(resp, DEV_TAG_MOUNTED)) break;
        if (!g_area_open) { resp->result = NFP_ERR(ERR_AREA_NULL); break; }
        write_out(req, g_area, AREA_SIZE);
        OUT(uint32_t, 0) = AREA_SIZE;
        resp_size(resp, 4);
        break;
    }
    case 9: {   // SetApplicationArea(bytes)
        if (!device_ok(resp, DEV_TAG_MOUNTED)) break;
        if (!g_area_open) { resp->result = NFP_ERR(ERR_AREA_NULL); break; }
        IpcBuf *b = in_buf(req, 0);
        if (!b || b->size > AREA_SIZE) { resp->result = NFP_ERR(ERR_AREA_TOO_LARGE); break; }
        memset(g_area, 0, sizeof g_area);
        memcpy(g_area, (const void *)(uintptr_t)b->addr, (size_t)b->size);
        break;
    }
    case 10: case 11:   // Flush / Restore: to the figure's file
        if (!device_ok(resp, DEV_TAG_MOUNTED)) break;
        if (req->cmd == 10 && g_area_exists) g_write_counter++, area_save(g_tag);
        break;
    case 12: case 24: {   // CreateApplicationArea / RecreateApplicationArea(access id, bytes)
        if (!device_ok(resp, DEV_TAG_MOUNTED)) break;
        if (req->cmd == 12 && g_area_exists) { resp->result = NFP_ERR(ERR_AREA_EXISTS); break; }
        IpcBuf *b = in_buf(req, 0);
        if (!b || b->size > AREA_SIZE) { resp->result = NFP_ERR(ERR_AREA_TOO_LARGE); break; }
        g_area_id = IN(uint32_t, 8);
        memset(g_area, 0, sizeof g_area);
        memcpy(g_area, (const void *)(uintptr_t)b->addr, (size_t)b->size);
        g_area_exists = true, g_write_counter++;
        area_save(g_tag);
        LOG("[amiibo] the game made its data on the figure (access id %08x)\n", g_area_id);
        break;
    }
    case 13: {   // GetTagInfo
        if (!device_ok(resp, DEV_TAG_FOUND)) break;
        uint8_t o[0x58];
        tag_info(o);
        write_out(req, o, sizeof o);
        break;
    }
    case 14: {   // GetRegisterInfo
        if (!device_ok(resp, DEV_TAG_MOUNTED)) break;
        uint8_t o[0x100];
        register_info(o);
        write_out(req, o, sizeof o);
        break;
    }
    case 15: {   // GetCommonInfo
        if (!device_ok(resp, DEV_TAG_MOUNTED)) break;
        uint8_t o[0x40];
        common_info(o);
        write_out(req, o, sizeof o);
        break;
    }
    case 16: {   // GetModelInfo
        if (!device_ok(resp, DEV_TAG_MOUNTED)) break;
        uint8_t o[0x40];
        model_info(o);
        write_out(req, o, sizeof o);
        break;
    }
    case 17: resp->copy_handles[resp->ncopy++] = ev_handle(&g_ev_activate, &g_h_activate); break;
    case 18: resp->copy_handles[resp->ncopy++] = ev_handle(&g_ev_deactivate, &g_h_deactivate); break;
    case 23: resp->copy_handles[resp->ncopy++] = ev_handle(&g_ev_avail, &g_h_avail); break;
    case 19: OUT(uint32_t, 0) = g_initialized ? 1 : 0; resp_size(resp, 4); break;   // GetState
    case 20: OUT(uint32_t, 0) = g_initialized ? (uint32_t)g_state : DEV_UNAVAILABLE; resp_size(resp, 4); break;
    case 21: OUT(uint32_t, 0) = 0; resp_size(resp, 4); break;   // GetNpadId: player 1
    case 22: OUT(uint32_t, 0) = AREA_SIZE; resp_size(resp, 4); break;
    default: LOG("[amiibo] nfp IUser cmd %u (ok)\n", req->cmd); resp_size(resp, 0x10);
    }
    static int nlog;
    if (nlog < 200 && getenv("WSWORD_AMIIBO_LOG"))
        nlog++, LOG("[amiibo] cmd %u -> %#x (state %d)\n", req->cmd, resp->result, g_state);
    pthread_mutex_unlock(&g_mu);
}

SERVICE("nfp:user", nfp_user_manager) {
    (void)s;
    if (req->cmd == 0) ipc_return_object(resp, service_new("IUser(nfp)", nfp_user, NULL));  // CreateUserInterface
    else LOG("[amiibo] nfp IUserManager cmd %u (ok)\n", req->cmd);
}

// ------------------------------------------------------------------ the bar's controls (hle/input.c)
// Switch buttons (hle/input.c's BTN_*): A 0, X 2, the d-pad 12-15
enum { B_A = 1u << 0, B_X = 1u << 2, B_DPAD = 0xfu << 12 };
static _Atomic uint64_t g_bar_held, g_bar_pressed;
static _Atomic int32_t g_bar_rx;

void amiibo_bar_filter(uint64_t *buttons, int32_t *rx, int32_t *ry) {
    if (!amiibo_bar_up()) {
        atomic_store(&g_bar_held, 0);
        atomic_store(&g_bar_rx, 0);
        return;
    }
    uint64_t mine = *buttons & (B_A | B_X | B_DPAD);
    uint64_t was = atomic_exchange(&g_bar_held, mine);
    atomic_fetch_or(&g_bar_pressed, mine & ~was);
    atomic_store(&g_bar_rx, *rx);
    *buttons &= ~(uint64_t)(B_A | B_X | B_DPAD);
    *rx = 0, *ry = 0;
}
uint64_t amiibo_bar_input_held(void) { return atomic_load(&g_bar_held); }
uint64_t amiibo_bar_input_pressed(void) { return atomic_exchange(&g_bar_pressed, 0); }
int32_t amiibo_bar_input_rx(void) { return atomic_load(&g_bar_rx); }
