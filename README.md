# WSword PS5

**WSword - the Breath of the Wild recompilation (from [SheikahSlate](https://github.com/RJ22256/SheikahSlate)) - as a native title for a jailbroken PS5:** a raw title folder, `PPSA99777`, with its `eboot.bin`, that ShadowMountPlus puts on the home screen.

> **Status: milestone 1 - the console check.** This build is not the game yet. It boots as WSword's PS5 title, draws on the PS5's GPU, and checks what the port needs on *your* console; its report tells the next steps what works there. See [the plan](docs/PLAN.md).

No game files, keys or game code come with WSword PS5. The game code is built on your PC from your own dump, as WSword for PC does.

## What you need

- A PS5 running homebrew: an enabler (etaHEN / kstuff), [ShadowMountPlus](https://github.com/drakmor/ShadowMountPlus) loaded at boot, and an FTP server (ftpsrv on port 2121, or etaHEN's).
- (Later milestones) WSword for PC and your own *Breath of the Wild* dump, for the PS5 export.

## Milestone 1: the console check

1. Download `WSwordPS5-PPSA99777.zip` from the [releases](../../releases) and unzip it.
2. Copy the `PPSA99777` folder to the console over FTP: `/data/homebrew/PPSA99777/`.
3. Reboot or let ShadowMountPlus pick it up: **WSword** appears on the home screen. Start it.
4. It shows a lantern (the GPU working) and, in its window (OPTIONS / the touch pad shows and hides it), **WSword PS5 - console check**: how many checks passed and what's missing.
5. Send back `/data/homebrew/PPSA99777/wsword-check.txt` (over FTP). Quit from the window, or with the PS button.

The check looks at:

- **The GPU:** the Vulkan version and every extension and feature WSword's PC renderer uses (transform feedback, push descriptors, custom border colours, ray queries for Ray-Tracing...), on the PS5's RADV driver.
- **Memory:** WSword keeps the game's memory at a fixed address (0x7000000000-0x7320000000, as on PC). The check reserves that range and backs 3.5 GB of it.
- **The CPU:** the AVX2 / FMA / BMI2 the game code is built for.
- **The title folder:** where the game files will go, and how fast it writes.

## How it's built

On GitHub Actions ([.github/workflows/build.yml](.github/workflows/build.yml)): the payload SDK fork, PS5_Vulkan's RADV release archive (Mesa's Vulkan driver for the PS5 GPU, built from PS5_Mesa), its native tool (which signs `eboot.bin`) and `libc.prx`, then the title. Locally, on Linux/WSL: `ps5/tools/bootstrap.sh` once, then `ps5/tools/build.sh` (`dist/PPSA99777/`).

The title starts from [mihawk-99's PS5 Vulkan Template](https://github.com/mihawk-99/PS5_VulkanTemplate) (at `91179df7`): Sascha Willems' Vulkan example base with its PS5 hooks, and the PS5 layer (launch, pad, klog, exit). Its original README is in [docs/TEMPLATE-README.md](docs/TEMPLATE-README.md).

## Credits and licences

- [Mihawk](https://github.com/mihawk-99): PS5_Vulkan, PS5_Mesa (RADV for the PS5), the PS5 Vulkan Template, PS5_PayloadSDK's platform layer.
- John Törnblom: the [PS5 payload SDK](https://github.com/ps5-payload-dev/sdk).
- Sascha Willems: the Vulkan examples' base (MIT).
- Mesa / RADV (MIT), the payload SDK's platform layer (GPL-3.0-or-later): the title links them, so the title as built is GPL-3.0-or-later. The foundation's own files keep their MIT notices (`LICENSE.md`).
- WSword is built on [Savage Wind Recomp](https://github.com/Revivedx/SavageWindRecomp) (MIT).

WSword PS5 is not affiliated with Sony, Nintendo, NVIDIA or the projects above.
