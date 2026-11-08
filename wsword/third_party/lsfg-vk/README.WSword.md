# lsfg-vk in WSword

WSword uses this code for frame generation. The frame generation itself comes from the player's own copy of Lossless Scaling's `Lossless.dll`.

The code was taken from [lsfg-vk](https://github.com/PancakeTAS/lsfg-vk), by PancakeTAS and contributors. Only two parts of it are here:

- `lsfg-vk-common`: the Vulkan wrappers.
- `lsfg-vk-backend`: reads the shaders out of `Lossless.dll` and runs the frame generation passes.

The Vulkan layer, the user interface and the configuration code were left out.

## Version and licence

The code is from GitHub PR #544, head `f4f7444` (5 August 2026). That PR is built on maintainer commit `8b0da26` (28 June 2026).

Its licence is **GPL-3.0** (`LICENSE.md`). This is the last version under that licence: on 27 August 2026 the project moved to CC BY-NC-ND 4.0, which does not allow modified copies.

**What this means for WSword's builds:**

- An APK or a PC build that contains this code is a combined work under GPL-3.0. Anyone you give it to must also be able to get the source.
- WSword's own files keep their MIT licence. Only the files that link this code carry the GPL-3.0 notice: `runtime/nvn/vulkan/framegen.cpp` and `tools/test_lsfg_dll.cpp` (Android), and in the PC build (`pc/`, on Savage Wind Recomp) `runtime/nvn/vulkan/lsfg.cpp`.

No `Lossless.dll`, and nothing extracted from one, is included anywhere in WSword. The player chooses their own copy on the start screen under Settings > Lossless Scaling (PC: Settings > Files > Lossless Scaling).

## WSword's changes

Every change is marked `(WSword)` in the code.

### `vulkan.hpp` / `vulkan.cpp`
- **A new constructor** that uses an existing device and one of its queues exactly as they are. No second device is made and no memory is shared. The caller chooses the queue family and whether FP16 is used.
- **Optional extension functions.** The file-descriptor functions are no longer required. The timeline-semaphore functions fall back to their Vulkan 1.2 core names.
- **No `vk_layer.h`.** The one declaration used from it, `PFN_vkSetDeviceLoaderData`, is written out in the file instead.

### `lsfgvk.hpp` / `lsfgvk.cpp`
- **`Instance(ExternalDevice, …)`** creates an instance on the application's device.
- **`openLocalContext`** opens a context whose images and timeline semaphore belong to the instance. Its source images can also be copied into, because they are created with `TRANSFER_DST`. All images start in `GENERAL` layout.
- **New accessors:**
  - `images`, `nextSignal` and `frameIndex`
  - `lowPrecision` and `persistCache`
- **`checkShaderDll`** checks a DLL without needing a GPU. It reports whether the full-precision and FP16 shader sets are complete. `tools/test_lsfg_dll.cpp` tests it against made-up DLLs.
- **Context construction changed.** A context is now built from images and a semaphore that were made beforehand. `openContext`, the original entry point that imports file descriptors, still works the same way.

## How WSword uses it

The runtime side is in `runtime/nvn/vulkan/device.c`, in the section headed "frame generation". On each real frame:

1. The game's finished image is copied into `source[frame % 2]`.
2. The submission that does the copy signals the timeline semaphore at `nextSignal()`.
3. `scheduleFrames` submits the backend's passes.
4. Each generated frame `i` is presented in turn. Its submission first waits for `nextSignal() + 1 + i`.
5. The real frame is presented last.

The presents are paced with `VK_GOOGLE_display_timing`, on a FIFO swapchain.
