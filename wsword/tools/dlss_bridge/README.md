# wsword_dlss.dll

WSword's bridge to NVIDIA DLSS for its Vulkan renderer: DLSS upscaling (Super Resolution, `wsword_dlss.cpp`) and DLSS frame generation (`wsword_sl.cpp`), and the game's depth for the player's own ReShade (`wsword_reshade.cpp`). The runtime loads it (`runtime/nvn/vulkan/dlss.c`, `dlssg.c`, `reshade.c`); the C interface is `runtime/nvn/vulkan/dlss_bridge.h`.

- **Why a DLL of its own:** NVIDIA's NGX library comes as an MSVC static library (`nvsdk_ngx_s.lib`), which the MinGW-built `WSword.exe` can't link, and Streamline's interface is MSVC C++. So this DLL is built with MSVC.
- **Built by** `.github/workflows/build-windows.yml`:
  - NVIDIA's DLSS SDK is fetched from <https://github.com/NVIDIA/DLSS>: its `include/`, `lib/Windows_x86_64/x64/nvsdk_ngx_s.lib` and `LICENSE.txt`.
  - NVIDIA's Streamline SDK release is fetched from <https://github.com/NVIDIA-RTX/Streamline> (MIT): its headers for this DLL, and its signed production `sl.interposer.dll`, `sl.common.dll`, `sl.dlss_g.dll`, `sl.reflex.dll` and `sl.pcl.dll` (and `NvLowLatencyVk.dll` when it has one) for the zip's `streamline` folder, with its licence.
  - It is compiled with `cl /MT` (the static CRT, as the NGX library is).
  - `make dist` puts it in the zip with the DLSS SDK's licence (`NVIDIA-DLSS-LICENSE.txt`), and Streamline's files in `streamline\`.
- **Streamline is loaded at run time** (`LoadLibrary`, after checking the interposer's NVIDIA signature), only when the player chose NVIDIA DLSS frame generation. Without its files, DLSS upscaling works as before.
- **ReShade** (`wsword_reshade.cpp`, `wsrs_*`): when WSword loaded the player's ReShade as a Vulkan layer, the bridge registers with it as an add-on through ReShade's add-on API (its headers: `third_party/reshade`, BSD-3-Clause, compiled in; the zip has their licence as `ReShade-API-LICENSE.md`) and binds WSword's depth image to the `DEPTH` semantic its effects sample. ReShade itself isn't linked or included: it is found in the process by its exports.
- **Not included:** the DLSS models, `nvngx_dlss.dll` and `nvngx_dlssg.dll`. They are the player's own:
  - Settings > Files > NVIDIA DLSS copies `nvngx_dlss.dll` next to `WSword.exe`, where NGX looks for it.
  - Settings > Files > NVIDIA DLSS frame generation copies `nvngx_dlssg.dll` into `streamline\`, where Streamline looks for it.

By hand, from a "x64 Native Tools" prompt in `pc/`:

```bat
cl /nologo /O2 /MT /EHsc /LD /std:c++17 /I <DLSS>\include /I <Vulkan-Headers>\include /I <Streamline>\include ^
   /I third_party\reshade\include tools\dlss_bridge\wsword_dlss.cpp tools\dlss_bridge\wsword_sl.cpp ^
   tools\dlss_bridge\wsword_reshade.cpp /Fe:build\wsword_dlss.dll /Fo:build\ ^
   /link <DLSS>\lib\Windows_x86_64\x64\nvsdk_ngx_s.lib advapi32.lib user32.lib shell32.lib ole32.lib version.lib ^
   setupapi.lib cfgmgr32.lib gdi32.lib wintrust.lib crypt32.lib
```
