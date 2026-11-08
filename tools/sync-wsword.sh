#!/usr/bin/env bash
# tools/sync-wsword.sh <SheikahSlate checkout>/pc - copies the WSword PC runtime's sources into wsword/: the console
# build compiles the same runtime as the PC (runtime/platform/ps5.c is its PS5 host layer, the rest is shared, with
# __PROSPERO__ where the console differs). wsword/SOURCE records the commit it came from.
set -euo pipefail
src=$(cd -- "${1:?usage: tools/sync-wsword.sh <SheikahSlate>/pc}" && pwd)
dst=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/wsword
[[ -f $src/runtime/platform/ps5.c ]] || { echo "$src: no runtime/platform/ps5.c (not a WSword PC tree with the PS5 layer)" >&2; exit 1; }
rm -rf "$dst/runtime" "$dst/third_party" "$dst/tools" "$dst/assets"
mkdir -p "$dst"
# (the PC's own platform layers and the macOS renderer are left out: the console build compiles neither)
cp -R "$src/runtime" "$dst/runtime"
rm -f "$dst"/runtime/platform/{windows,macos,linux}* "$dst"/runtime/nvn/*.m
cp -R "$src/third_party" "$dst/third_party"
cp -R "$src/assets" "$dst/assets"  # (WSword's own art: the start screen, the icons)
cp "$src/docs/icon/wsword_1024.png" "$dst/assets/icon.png"
cp -R "$src/tools" "$dst/tools"  # (the game code's id is made from the generator's sources: runtime/gamelib.h)
cp "$src/Makefile" "$dst/Makefile.pc"  # (reference: the PC build's flags and generated files)
{
    git -C "$src" log -1 --format='SheikahSlate %H (%cs) %s' 2>/dev/null || echo "SheikahSlate (unknown commit)"
    [[ -z $(git -C "$src" status --porcelain -- runtime third_party 2>/dev/null) ]] || echo "with local changes"
} > "$dst/SOURCE"
grep -m1 'SAVAGEWIND_VERSION' "$src/runtime/ui/launcher.mm" > /dev/null && \
    sed -n 's/.*#define SAVAGEWIND_VERSION "\(.*\)".*/\1/p' "$src/runtime/ui/launcher.mm" | head -1 > "$dst/VERSION"
echo "wsword/: $(cat "$dst/SOURCE" | head -1), version $(cat "$dst/VERSION" 2>/dev/null)"
