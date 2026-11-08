# WSword PS5: the plan

WSword for PC is three parts: the **runtime** (pc/runtime in SheikahSlate: the HLE services, the Vulkan renderer, the UI), the **game code** (the game's ARM64 code recompiled to C and built on the player's PC from their own dump), and the **game files** (the dump's RomFS). On the PS5 they become:

| Part | On the PS5 |
| --- | --- |
| the runtime | `eboot.bin`, built here by CI, released ready to copy |
| the game code | `wsword/swgame.elf`, built **on the PC** by WSword Configuration's PS5 export (zig, for the console's ABI, linked for the title's in-process loader) - it can't be shipped |
| the game files | `wsword/romfs/` (and the DLC), copied by the same export |

A title can't `dlopen` a module it brings (skills/ps5-porting `loading-code.md`), so the game code is loaded by an in-process ELF loader (PS5_RetroArch's core loader: code in direct memory, imports bound to the title's own), which keeps the eboot one download for everyone.

## Milestones

1. **The console check** (this): the title builds, signs and boots from `PPSA99777` on the player's console; the report says which Vulkan extensions/features RADV gives WSword, whether the guest range reserves at 0x7000000000, the memory, the CPU, the folder.
2. **The runtime cross-built**: pc/runtime compiled with the payload SDK as a static archive; the errors list the platform code to replace.
3. **The platform layer**: `platform/ps5.c` (threads, time, files under /app0, the guest range through `ps5_vrange_*` with commit-on-fault, the crash handler), and an SDL3 subset over the console (the pad - DualSense, with motion and rumble -, AudioOut, the VideoOut display through `VK_KHR_display`, properties, timers), no start screen (the game boots; F1's menu on a pad combination).
4. **The game code loader and the PS5 export**: the in-process loader for `swgame.elf`; on the PC, WSword Configuration's **PS5 export** builds the game code for the console and writes the PPSA folder (the released eboot, sce_sys, the game code, the game files).
5. **First boot of the game**, then the renderer on RADV (ASTC decoded as on PC; RADV's own limits), audio, saves (/app0/wsword/save), movies (FFmpeg built for the console), performance, Ray-Tracing (RADV has ray queries).

Each milestone ends with a build on the player's console and its log.
