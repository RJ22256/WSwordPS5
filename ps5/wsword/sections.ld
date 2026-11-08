/* ps5/wsword/sections.ld - the runtime's registration tables (runtime/hle.h, runtime/ipc.h: HLE functions, services,
 * reset hooks; the linker's __start_ / __stop_ bounds) in the data segment, after .data. Left to the linker as
 * orphans they landed in the RELRO segment's gap that the native converter fills with the process parameters. */
SECTIONS {
    hle_impls : { KEEP(*(hle_impls)) }
    services : { KEEP(*(services)) }
    resets : { KEEP(*(resets)) }
} INSERT AFTER .data;
