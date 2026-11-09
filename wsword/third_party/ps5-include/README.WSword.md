# ps5-include

The C library headers the game code is compiled against for the PS5 (WSword Configuration's PS5 export:
runtime/gamebuild.c): the console's libc is FreeBSD's, and the game code calls it (memcpy, the math functions,
fegetround, setjmp) once it is loaded on the console (runtime/elfload.c), so it is built with the console's own
declarations and types (jmp_buf, fenv_t), not the PC's.

These are FreeBSD's headers as the PS5 payload SDK (ps5-payload-dev/sdk v0.42, mihawk-99's fork at 611893f) installs
them: the closure of what cpu.h, simd.h, setjmp.h and gamelib.h include. Each keeps its own copyright and licence
notice (BSD-style licences: FreeBSD, the University of California, Sun Microsystems); nothing here is changed.
