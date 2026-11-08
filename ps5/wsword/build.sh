#!/usr/bin/env bash
# ps5/wsword/build.sh - WSword itself as the title's eboot.bin, into dist/<TITLE_ID>/ (as ps5/tools/build.sh does for
# the template's samples): the runtime (ps5/wsword/configure.py: wsword/ with the console's SDL3 subset, Vulkan
# commands and process end) linked whole with its dependencies (ps5/wsword/deps.sh) and RADV, by the template's
# link (ps5/tools/link-title.sh: PS5_Vulkan's recipe, its CRT, the native tool that signs the eboot).
#
#   PS5_VULKAN_DIR   the PS5_Vulkan checkout (default ../PS5_Vulkan): RADV, its link recipe and tools
#   WSWORD_DEPS      the dependencies' prefix (default build/wsword-deps; built when missing)
set -euo pipefail
ps5=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
root=$(dirname "$ps5")
vulkan=$(cd -- "${PS5_VULKAN_DIR:-$root/../PS5_Vulkan}" && pwd)
sdk=$(bash "$ps5/tools/setup-sdk.sh")
deps=${WSWORD_DEPS:-$root/build/wsword-deps}
out=$root/build/wsword
work=$root/build/wsword-title
ninja=$(command -v ninja || echo "$HOME/.local/bin/ninja")
export PS5_CLANG=${PS5_CLANG:-$(command -v clang || true)}

[[ -f $deps/lib/libavcodec.a && -f $deps/lib/libshaderc_combined.a ]] ||
    bash "$ps5/wsword/deps.sh" "$sdk" "$deps" "$vulkan/.deps/native/zlib/root"
python3 "$ps5/wsword/configure.py" --sdk "$sdk" --deps "$deps" --out "$out"
"$ninja" -C "$out"

mkdir -p "$work"
printf 'wsword' > "$work/samples.txt"  # (link-title.sh's list of samples: no shaders of its own to copy)
# - the runtime whole: its HLE functions, services and reset hooks are only reached through their sections
# - main, exit, _exit and atexit wrapped: the title ends through the shell (ps5/wsword/ps5_glue.c)
# - the section bounds kept with what they bound
export LINK_EXTRA_FLAGS="--wrap=main --wrap=exit --wrap=_exit --wrap=atexit -z nostart-stop-gc"
bash "$ps5/tools/link-title.sh" "$work" "$vulkan" "$sdk" \
    --whole-archive "$out/libwsword.a" --no-whole-archive \
    "$deps/lib/libavformat.a" "$deps/lib/libavcodec.a" "$deps/lib/libswscale.a" "$deps/lib/libavutil.a" \
    "$deps/lib/libshaderc_combined.a"  # (zlib: RADV's link has PS5_Vulkan's, the same pinned build)
