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
# - the registration tables in the data segment (ps5/wsword/sections.ld)
export LINK_EXTRA_FLAGS="--wrap=main --wrap=exit --wrap=_exit --wrap=atexit -z nostart-stop-gc -T $ps5/wsword/sections.ld"
trap '[[ -f $work/link/llvm-pie.elf ]] && "$(command -v llvm-readelf-18 || command -v llvm-readelf || echo readelf)" -lSW "$work/link/llvm-pie.elf" | grep -vE "^\s*$" | head -120' ERR
bash "$ps5/tools/link-title.sh" "$work" "$vulkan" "$sdk" \
    --whole-archive "$out/libwsword.a" --no-whole-archive \
    "$deps/lib/libavformat.a" "$deps/lib/libavcodec.a" "$deps/lib/libswscale.a" "$deps/lib/libavutil.a" \
    "$deps/lib/libshaderc_combined.a"  # (zlib: RADV's link has PS5_Vulkan's, the same pinned build)

# What the PC's folder ships beside WSword.exe (the PC Makefile's dist): the fonts, WSword's art, the colour LUTs,
# the notices - beside eboot.bin, where the runtime looks for them (runtime/paths.c rt_resource: the program's folder)
app="$root/dist/$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["titleId"])' "$ps5/sce_sys/param.json")"
w=$root/wsword
cp "$w"/third_party/fonts/FiraSans/FiraSans-SemiBold.ttf "$w"/third_party/fonts/FiraSans/FiraSans-Medium.ttf \
    "$w"/third_party/fonts/NotoSansThai/NotoSansThai-Medium.ttf "$w"/third_party/fonts/Inter/Inter-Bold.otf \
    "$w"/third_party/fonts/Inter/Inter-Medium.otf "$w"/third_party/fonts/ChakraPetch/ChakraPetch-Bold.ttf "$app/"
for f in FiraSans NotoSansThai Inter ChakraPetch; do cp "$w/third_party/fonts/$f/OFL.txt" "$app/$f-OFL.txt"; done
cp "$w"/assets/launcher-background.png "$w"/assets/app-icon-*.png "$w"/assets/icon.png "$app/"
mkdir -p "$app/colour-luts" && cp "$w"/third_party/luts/*.cube "$w"/third_party/luts/README.md "$app/colour-luts/"
cp "$w/third_party/lsfg-vk/LICENSE.md" "$app/lsfg-vk-LICENSE.md"
cp "$w/third_party/FidelityFX/LICENSE.txt" "$app/FidelityFX-LICENSE.txt"
rm -rf "$app/assets" "$app/shaders"  # (the template's samples' assets, not WSword's)
echo "==> WSword $(cat "$w/VERSION") for the PS5: $app"
