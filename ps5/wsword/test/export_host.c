// Loads export_probe's library with runtime/elfload.c (ELFLOAD_TEST) and calls it: what the console's title does.
#include "elfload.h"
#include "gamelib.h"
#include <fenv.h>
#include <math.h>
#include <setjmp.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
int rt_probe_host(int i) { return 100 * i; }
volatile int g_fnprof = 1000;
static void *ex(size_t n) {
    void *p = mmap(0, n, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    return p == MAP_FAILED ? NULL : p;
}
int main(int argc, char **argv) {
    const ElfExport e[] = {{"fegetround", (void *)fegetround}, {"g_fnprof", (void *)&g_fnprof},
                           {"memcpy", (void *)memcpy}, {"rt_probe_host", (void *)rt_probe_host},
                           {"setjmp", (void *)_setjmp}, {"sin", (void *)sin}, {"sqrtf", (void *)sqrtf}};
    ElfImage img;
    char why[300];
    if (!elf_load(argv[1], e, sizeof e / sizeof *e, ex, &img, why, sizeof why)) { printf("load: %s\n", why); return 1; }
    double (*entry)(double, int) = (double (*)(double, int))elf_symbol(&img, "probe_entry");
    int (*jmp)(void) = (int (*)(void))elf_symbol(&img, "probe_jmp");
    double got = entry(4.0, 1), want = sin(4.0) + 2 + 100 + 1 + 'o' + 1 + 1000;
    printf("probe_entry(4, 1) = %f, expected %f; jmp_buf %d bytes (the console's)\n", got, want, jmp());
    GameLibEntry tables = (GameLibEntry)elf_symbol(&img, GAMELIB_ENTRY);
    const GameLibTables *t = tables ? tables() : NULL;
    printf("swgame_tables: abi %u, id %s, version %s\n", t ? t->abi : 0, t ? t->id : "?", t ? t->version : "?");
    return fabs(got - want) < 1e-9 && t && t->abi == GAMELIB_ABI && !strcmp(t->version, "probe") ? 0 : 1;
}
