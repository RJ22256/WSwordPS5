# WSword PS5: the plan

WSword for PC is three parts: the **runtime** (pc/runtime in SheikahSlate: the HLE services, the Vulkan renderer, the UI), the **game code** (the game's ARM64 code recompiled to C and built on the player's PC from their own dump), and the **game files** (the dump's RomFS). On the PS5 they become:

| Part | On the PS5 |
| --- | --- |
| the runtime | `eboot.bin`, built here by CI, released ready to copy |
| the game code | `swgame.elf`, built **on the PC** by WSword Configuration's PS5 export (zig, for the console's ABI, linked for the title's in-process loader) - it can't be shipped |
| the game files | the dump's files (and the DLC), copied by the same export |

The title folder is laid out as the Windows WSword folder (`eboot.bin` in place of `WSword.exe`): the runtime's data folder is `/app0` itself, where WSword.log, the settings, the saves and the shader cache go too.

A title can't `dlopen` a module it brings (skills/ps5-porting `loading-code.md`), so the game code is loaded by an in-process ELF loader (PS5_RetroArch's core loader: code in direct memory, imports bound to the title's own), which keeps the eboot one download for everyone.

## Milestones

1. **The console check** (done, v0.1.0-m1: 54 of 54): the title builds, signs and boots from `PPSA99777` on the player's console; the report says which Vulkan extensions/features RADV gives WSword, whether the guest range reserves at 0x7000000000, the memory, the CPU, the folder.
2. **The runtime cross-built** (done): `wsword/` is the PC runtime's sources (`tools/sync-wsword.sh`, from SheikahSlate's pc-windows), compiled with the payload SDK into `build/wsword/libwsword.a` (`ps5/wsword/configure.py`: 142 objects, Zen 2, `-O2`), with FFmpeg 9.0.2 (LGPL, the PC's configuration, its assembly kept), shaderc 2026.3 and zlib built for the console (`ps5/wsword/deps.sh`). The PC sources needed little: `runtime/platform/ps5.c` (guest memory as direct memory in a reserved range, committed per region and on first touch, as Windows does; the log in the title folder; no child processes) and `__PROSPERO__` in a few places (ELF section tables, RADV's defaults, memory scans through a pipe). What the archive still needs from outside (`ps5/wsword/missing.py`, in each CI run's summary): 110 SDL3 functions, 137 Vulkan entry points (RADV) and the linker's section bounds - nothing else.
3. **The SDL3 subset and the first link** (built, v0.2.0-m3: on the console next): `ps5/wsword/sdl`, an SDL3 subset over the console (the pad - DualSense, with motion and rumble -, AudioOut, the VideoOut display through `VK_KHR_display`, properties, timers), no start screen (the game boots; F1's menu on a pad combination); the title links libwsword.a with RADV and starts the runtime up to where it looks for the game code.
4. **The game code loader and the PS5 export**: the in-process loader for `swgame.elf`; on the PC, WSword Configuration's **PS5 export** builds the game code for the console and writes the PPSA folder (the released eboot, sce_sys, the game code, the game files).
5. **First boot of the game**, then the renderer on RADV (ASTC decoded as on PC; RADV's own limits), audio, saves (/app0/wsword/save), movies (FFmpeg built for the console), performance, Ray-Tracing (RADV has ray queries).

Each milestone ends with a build on the player's console and its log.
