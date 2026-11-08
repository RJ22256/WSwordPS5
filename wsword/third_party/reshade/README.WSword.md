# ReShade's add-on API headers

`include/` is `include/` of [ReShade](https://github.com/crosire/reshade) 6.8.0 by Patrick Mours (BSD-3-Clause, `LICENSE.md`; the headers: BSD-3-Clause OR MIT), unchanged.

WSword's MSVC bridge (`tools/dlss_bridge/wsword_reshade.cpp`, in `wsword_dlss.dll`) uses them to register with the player's own ReShade, loaded by WSword as a Vulkan layer (`runtime/nvn/vulkan/reshade.c`), and give its effects the game's depth. No part of ReShade itself ships with WSword.
