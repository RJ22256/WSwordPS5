// PS5 host layer (runtime/platform.h), for the jailbroken console's homebrew titles (WSwordPS5: the PS5 payload SDK,
// prospero-clang, RADV on the console's GPU). Modelled on linux.c, with the differences the console makes:
//  - guest memory is direct memory: a title's anonymous mappings are charged to its ~1 GB flexible budget, so the
//    12.5 GB window is a reserved virtual range (ps5platform/shm.h) committed in 64 KiB units, per region
//    (plat_commit from the loader / kernel) and, like Windows, on the first touch of anything outside one
//  - no child processes, no re-exec: the game code is built on the PC (WSword Configuration's PS5 export)
//  - no terminal: stderr goes to WSword.log in the title folder (/app0, as WSword.log next to WSword.exe)
#include <SDL3/SDL.h>
#include <errno.h>
#include <fcntl.h>
#include <dirent.h>
#include <pthread.h>
#include <sched.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/ucontext.h>
#include <time.h>
#include <unistd.h>

#include <ps5platform/exec.h>
#include <ps5platform/shm.h>

#include "../gamelib.h"
#include "../platform.h"

// ---- guest address space
// Which 64 KiB units of the window are backed (ps5_vrange_commit): a fault on one that isn't is a first touch, to
// back read/write; a fault on one that is was a protection the runtime set (the data watchpoint, runtime/dispatch.c)
// or a real crash. (ps5_vrange_commit on a backed unit only changes its protection, so it can't tell them apart.)
#define UNIT 0x10000ull
static uint64_t g_lo, g_hi;
static _Atomic uint64_t *g_backed;  // one bit per unit

static bool unit_backed(uint64_t a) {
    uint64_t u = (a - g_lo) / UNIT;
    return atomic_load_explicit(&g_backed[u >> 6], memory_order_acquire) >> (u & 63) & 1;
}

static void mark_backed(uint64_t a, uint64_t e) {
    for (uint64_t u = (a - g_lo) / UNIT, end = (e - g_lo + UNIT - 1) / UNIT; u < end; u++)
        atomic_fetch_or_explicit(&g_backed[u >> 6], 1ull << (u & 63), memory_order_release);
}

static void mark_unbacked(uint64_t a, uint64_t e) {  // (whole units only)
    for (uint64_t u = (a - g_lo + UNIT - 1) / UNIT, end = (e - g_lo) / UNIT; u < end; u++)
        atomic_fetch_and_explicit(&g_backed[u >> 6], ~(1ull << (u & 63)), memory_order_release);
}

static bool in_window(uint64_t a) { return g_backed && a >= g_lo && a < g_hi; }

static bool backing(uint64_t a, uint64_t size, int prot) {
    int r = ps5_vrange_commit((void *)(uintptr_t)a, size, prot);
    if (r) {
        fprintf(stderr, "[plat] guest memory %llx+%llx: no direct memory for it (%x)\n", (unsigned long long)a,
                (unsigned long long)size, r);
        return false;
    }
    mark_backed(a & ~(UNIT - 1), a + size);
    return true;
}

// A first touch outside the committed regions (from the crash handler): the unit read/write, as on Windows.
static bool lazy_commit(uint64_t fa) {
    if (!in_window(fa) || unit_backed(fa)) return false;
    return backing(fa & ~(UNIT - 1), UNIT, PS5_SHM_READ | PS5_SHM_WRITE);
}

bool plat_reserve_guest(uint64_t lo, uint64_t hi) {
    if (ps5_vrange_reserve_at((void *)(uintptr_t)lo, hi - lo)) return false;
    g_backed = calloc((hi - lo) / UNIT / 64 + 1, sizeof *g_backed);
    if (!g_backed) { ps5_vrange_release((void *)(uintptr_t)lo, hi - lo); return false; }
    g_lo = lo, g_hi = hi;
    return true;
}

long plat_written_pages(uint64_t addr, uint64_t size, uint64_t *pages, size_t max) { return -1; }  // (not tracked)
int plat_any_written(uint64_t addr, uint64_t size) { return -1; }

// Everything given back: units come back zeroed at their next commit (ps5_vrange_decommit).
bool plat_reset_guest(uint64_t lo, uint64_t hi) {
    if (ps5_vrange_decommit((void *)(uintptr_t)lo, hi - lo)) return false;
    mark_unbacked(lo, hi);
    return true;
}

void plat_commit(uint64_t addr, uint64_t size) {
    if (!size || !in_window(addr)) return;
    // only the units not yet backed: committing a backed one would reset a protection the runtime set on it
    uint64_t a = addr & ~(UNIT - 1), e = (addr + size + UNIT - 1) & ~(UNIT - 1);
    while (a < e) {
        if (unit_backed(a)) { a += UNIT; continue; }
        uint64_t run = a;
        while (run < e && !unit_backed(run)) run += UNIT;
        backing(a, run - a, PS5_SHM_READ | PS5_SHM_WRITE);
        a = run;
    }
}

void plat_decommit(uint64_t addr, uint64_t size) {
    if (!in_window(addr)) return;
    uint64_t a = (addr + UNIT - 1) & ~(UNIT - 1), e = (addr + size) & ~(UNIT - 1);  // (whole units inside the range)
    if (e > a && ps5_vrange_decommit((void *)(uintptr_t)a, e - a) == 0) mark_unbacked(a, e);
}

int plat_protect(uint64_t addr, uint64_t size, int prot) {
    int p = prot == PLAT_PROT_NONE ? 0 : prot == PLAT_PROT_READ ? PS5_SHM_READ : PS5_SHM_READ | PS5_SHM_WRITE;
    if (in_window(addr)) {  // backed first, whole units read/write (as Windows' commit), then the pages' protection
        plat_commit(addr, size);
        return ps5_vrange_commit((void *)(uintptr_t)addr, size, p) ? -1 : 0;
    }
    return mprotect((void *)(uintptr_t)addr, size, prot == PLAT_PROT_NONE ? PROT_NONE
                                                   : prot == PLAT_PROT_READ ? PROT_READ : PROT_READ | PROT_WRITE);
}

// ---- the game files: the title folder's extracted/, or an external drive's
// In order: the folder game-files.txt in the title folder names (its first line, a full path), the title folder's own
// extracted/, then each USB drive and extended storage drive the console has mounted, at WSword/extracted,
// PPSA99777/extracted or extracted on it. The first with the game's exefs/main is the game files.
static bool has_game(const char *dir) {
    char p[1200];
    struct stat st;
    snprintf(p, sizeof p, "%s/exefs/main", dir);
    return stat(p, &st) == 0;
}

bool ps5_find_game_files(char *out, size_t n) {
    FILE *f = fopen("game-files.txt", "r");
    if (f) {
        char line[1024] = "";
        if (fgets(line, sizeof line, f)) {
            line[strcspn(line, "\r\n")] = 0;
            size_t k = strlen(line);
            while (k > 1 && line[k - 1] == '/') line[--k] = 0;
            if (line[0] && has_game(line)) {
                snprintf(out, n, "%s", line);
                fprintf(stderr, "[ps5] game files: %s (game-files.txt)\n", out);
                fclose(f);
                return true;
            }
            fprintf(stderr, "[ps5] game-files.txt names %s, which has no exefs/main\n", line);
        }
        fclose(f);
    }
    if (has_game("extracted")) {
        fprintf(stderr, "[ps5] game files: the title folder's extracted\n");
        return false;  // (the default: nothing to change)
    }
    static const char *const drives[] = {"/mnt/usb0", "/mnt/usb1", "/mnt/usb2", "/mnt/usb3", "/mnt/usb4", "/mnt/usb5",
                                         "/mnt/usb6", "/mnt/usb7", "/mnt/ext0", "/mnt/ext1", "/mnt/ext2"};
    static const char *const sub[] = {"WSword/extracted", "PPSA99777/extracted", "extracted"};
    for (size_t d = 0; d < sizeof drives / sizeof *drives; d++) {
        struct stat st;
        if (stat(drives[d], &st) != 0) continue;
        for (size_t i = 0; i < sizeof sub / sizeof *sub; i++) {
            char p[600];
            snprintf(p, sizeof p, "%s/%s", drives[d], sub[i]);
            if (has_game(p)) {
                snprintf(out, n, "%s", p);
                fprintf(stderr, "[ps5] game files: %s (an external drive)\n", out);
                return true;
            }
        }
        fprintf(stderr, "[ps5] %s: no WSword/extracted, PPSA99777/extracted or extracted with the game on it\n", drives[d]);
    }
    fprintf(stderr, "[ps5] game files: none found (the title folder's extracted, or WSword/extracted on a drive)\n");
    return false;
}

// ---- guest thread stacks (runtime/kernel.c thread_start)
// 256 MB each, reserved in direct memory (a title's own thread stacks come from its small flexible budget), the top
// STACK_FIRST backed now and the rest a megabyte at a time as the thread reaches it (the crash handler: each thread
// has its own signal stack, plat_crash_handler_install).
#define STACK_FIRST (8ull << 20)
static struct { uint64_t lo, hi; } g_stacks[256];
static _Atomic int g_nstacks;

bool ps5_guest_stack(size_t size, void **base) {
    void *b = NULL;
    if (ps5_vrange_reserve(size, NULL, 0x10000, &b)) return false;
    if (ps5_vrange_commit((char *)b + size - STACK_FIRST, STACK_FIRST, PS5_SHM_READ | PS5_SHM_WRITE)) {
        ps5_vrange_release(b, size);
        return false;
    }
    int i = atomic_fetch_add(&g_nstacks, 1);
    if (i < 256) g_stacks[i].lo = (uint64_t)(uintptr_t)b, g_stacks[i].hi = (uint64_t)(uintptr_t)b + size;
    *base = b;
    return true;
}

static bool stack_grow(uint64_t fa) {
    int n = atomic_load(&g_nstacks);
    for (int i = 0; i < n && i < 256; i++)
        if (fa >= g_stacks[i].lo + 0x10000 && fa < g_stacks[i].hi) {  // (the lowest 64 KiB stays a guard)
            uint64_t a = fa & ~0xFFFFFull;
            if (a < g_stacks[i].lo + 0x10000) a = g_stacks[i].lo + 0x10000;
            return ps5_vrange_commit((void *)(uintptr_t)a, 0x100000 - (a & 0xFFFFF), PS5_SHM_READ | PS5_SHM_WRITE) == 0;
        }
    return false;
}

// The game code's memory (runtime/elfload.c): direct memory, read, write and execute (ps5platform/exec.h), placed
// anywhere outside the GPU window.
void *plat_exec_alloc(size_t bytes) {
    struct ps5_exec_request rq = {.bytes = bytes};
    struct ps5_exec_region rg;
    int r = ps5_exec_alloc(&rq, &rg);
    if (r) { fprintf(stderr, "[plat] executable memory, %zu MB: %x\n", bytes >> 20, r); return NULL; }
    return rg.base;
}

// ---- time
uint64_t plat_now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000u + (uint64_t)ts.tv_nsec;
}

void plat_sleep_until_ns(uint64_t t) {
    for (;;) {  // (nanosleep: the kernel's own; relative, so measured again after an interruption)
        uint64_t now = plat_now_ns();
        if (now >= t) return;
        uint64_t d = t - now;
        struct timespec ts = {.tv_sec = (time_t)(d / 1000000000u), .tv_nsec = (long)(d % 1000000000u)};
        nanosleep(&ts, NULL);
    }
}

void plat_cpu_placement(void) {}  // (the console's 8 cores / 16 threads: the scheduler's placement)

void plat_thread_realtime(uint64_t period_ns) {
    (void)period_ns;
    struct sched_param sp = {.sched_priority = 1};
    pthread_setschedparam(pthread_self(), SCHED_FIFO, &sp);  // (refused quietly where a title may not)
}

// ---- process
static char g_log_path[1024];

static void log_to_title_folder(void) {
    const char *dir = getenv("SAVAGEWIND_DATA_ROOT");
    snprintf(g_log_path, sizeof g_log_path, "%s/WSword.log", dir && *dir ? dir : "/app0");
    char prev[1100];  // (the last run's log stays as WSword.prev.log)
    snprintf(prev, sizeof prev, "%.*s.prev.log", (int)strlen(g_log_path) - 4, g_log_path);
    rename(g_log_path, prev);
    if (!freopen(g_log_path, "w", stderr)) { g_log_path[0] = 0; return; }
    dup2(STDERR_FILENO, STDOUT_FILENO);
}

static void require_cpu(void) {  // (the console's Zen 2 runs the x86-64-v3 game code: kept for the message)
    const char *need = gamelib_cpu_problem();
    if (!need) return;
    fprintf(stderr, "FATAL: WSword needs %s.\n", need);
    exit(1);
}

void plat_init(void) {
    log_to_title_folder();
    require_cpu();
}

bool plat_exe_path(char *buf, size_t size) {
    const char *dir = getenv("SAVAGEWIND_DATA_ROOT");
    snprintf(buf, size, "%s/eboot.bin", dir && *dir ? dir : "/app0");
    return true;
}

void plat_exec(char *const argv[]) { (void)argv; }  // (no re-exec on the console: the caller carries on / reports it)

// ---- diagnostics
// A title carries no symbol table to answer dladdr from: WSword.sym beside eboot.bin does (WSwordPS5's build writes it:
// "address kind name" per line, as linked), read once, slid by where the title was loaded (plat_symbol's own address).
static struct { uint64_t addr; char *name; } *g_syms;
static size_t g_nsyms;

static void syms_load(void) {
    static bool tried;
    if (tried) return;
    tried = true;
    char path[1100];
    const char *dir = getenv("SAVAGEWIND_DATA_ROOT");
    snprintf(path, sizeof path, "%s/WSword.sym", dir && *dir ? dir : "/app0");
    FILE *f = fopen(path, "r");
    if (!f) return;
    size_t cap = 0;
    char line[600];
    int64_t slide = 0;
    bool slid = false;
    while (fgets(line, sizeof line, f)) {
        unsigned long long a;
        char kind, name[512];
        if (sscanf(line, "%llx %c %511[^\n]", &a, &kind, name) != 3) continue;
        if (g_nsyms == cap) {
            cap = cap ? cap * 2 : 16384;
            void *n = realloc(g_syms, cap * sizeof *g_syms);
            if (!n) break;
            g_syms = n;
        }
        if (!slid && !strcmp(name, "plat_symbol")) slide = (int64_t)(uintptr_t)plat_symbol - (int64_t)a, slid = true;
        g_syms[g_nsyms].addr = a;
        g_syms[g_nsyms++].name = strdup(name);
    }
    fclose(f);
    for (size_t i = 0; i < g_nsyms; i++) g_syms[i].addr += (uint64_t)slide;  // (sorted by address already: nm -n)
}

const char *plat_symbol(uint64_t pc, uint64_t *offset) {
    syms_load();
    size_t lo = 0, hi = g_nsyms;
    while (lo < hi) {  // the last symbol at or below pc
        size_t mid = (lo + hi) / 2;
        if (g_syms[mid].addr <= pc) lo = mid + 1;
        else hi = mid;
    }
    if (!lo || pc - g_syms[lo - 1].addr > 0x100000) return NULL;  // (beyond the image's functions)
    if (offset) *offset = pc - g_syms[lo - 1].addr;
    return g_syms[lo - 1].name;
}

// Fatal error: a message on the console (the SDL subset shows it as a notification); the details are in the log.
void plat_fatal_notice(void) {
    if (!g_log_path[0]) return;
    fflush(stderr);
    char text[1200];
    snprintf(text, sizeof text, "WSword stopped because of an error. Details: %s", g_log_path);
    SDL_ShowSimpleMessageBox(SDL_MESSAGEBOX_ERROR, "WSword", text, NULL);
}

void plat_print_backtrace(void) {
    // Frame pointers: the runtime and the game code keep them (-fno-omit-frame-pointer in the PS5 build).
    uint64_t *fp = __builtin_frame_address(0);
    for (int i = 0; i < 64 && fp && ((uintptr_t)fp & 7) == 0; i++) {
        uint64_t pc = fp[1], off = 0;
        if (!pc) break;
        const char *s = plat_symbol(pc, &off);
        extern const char *rt_host_fn_name(uint64_t pc, uint64_t *offset);  // runtime/dispatch.c
        if (!s) s = rt_host_fn_name(pc, &off);
        fprintf(stderr, "  #%-2d %016llx %s+%llx\n", i, (unsigned long long)pc, s ? s : "?", (unsigned long long)off);
        uint64_t *next = (uint64_t *)(uintptr_t)fp[0];
        if (next <= fp) break;
        fp = next;
    }
}

static void crash_handler(int sig, siginfo_t *si, void *ctx) {
    ucontext_t *uc = ctx;
    static volatile int depth;
    if (sig == SIGABRT && depth++ > 0) { signal(SIGABRT, SIG_DFL); abort(); }
    uint64_t fa = (uint64_t)(uintptr_t)si->si_addr;
    if ((sig == SIGSEGV || sig == SIGBUS) && (lazy_commit(fa) || stack_grow(fa))) return;
    uint64_t pc = (uint64_t)uc->uc_mcontext.mc_rip, sp = (uint64_t)uc->uc_mcontext.mc_rsp, lr = 0;
    if (sig != SIGSEGV || (fa & ~0xFFFull) != (sp & ~0xFFFull)) lr = *(uint64_t *)(uintptr_t)sp;
    g_fault_is_write = (uc->uc_mcontext.mc_err & 2) != 0;  // (x86 page fault error code: bit 1 = write)
    if (rt_fault_watch(fa, pc)) return;
    char what[32];
    snprintf(what, sizeof what, "signal %d", sig);
    rt_fault_report(what, fa, pc, lr);
}

void plat_crash_handler_reclaim(void) {}

void plat_crash_handler_install(void) {
    stack_t ss = {.ss_sp = malloc(1 << 20), .ss_size = 1 << 20};
    sigaltstack(&ss, NULL);
    struct sigaction sa = {0};
    sa.sa_sigaction = crash_handler;
    sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
    sigaction(SIGSEGV, &sa, NULL);
    sigaction(SIGBUS, &sa, NULL);
    sigaction(SIGILL, &sa, NULL);
    sigaction(SIGFPE, &sa, NULL);
    sigaction(SIGABRT, &sa, NULL);
}

// ---- child processes: none on the console (the game code generator and compiler run on the PC)
PlatProc plat_spawn(const char *const argv[], const char *log_path, bool append_log) {
    (void)argv, (void)log_path, (void)append_log;
    return 0;
}
void plat_proc_kill(PlatProc p) { (void)p; }
int plat_proc_wait(PlatProc p, bool block) { (void)p, (void)block; return 255; }

// rm -rf (the title's libc has no nftw)
bool plat_remove_tree(const char *dir) {
    struct stat st;
    if (lstat(dir, &st)) return errno == ENOENT;
    if (!S_ISDIR(st.st_mode)) return remove(dir) == 0;
    DIR *d = opendir(dir);
    if (!d) return false;
    bool ok = true;
    char path[1024];
    for (struct dirent *e; (e = readdir(d));) {
        if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
        snprintf(path, sizeof path, "%s/%s", dir, e->d_name);
        ok &= plat_remove_tree(path);
    }
    closedir(d);
    return rmdir(dir) == 0 && ok;
}

void plat_terminate(void) { _exit(0); }
