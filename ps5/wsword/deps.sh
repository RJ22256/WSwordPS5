#!/usr/bin/env bash
# ps5/wsword/deps.sh <payload SDK> <prefix> [<zlib root>] - the console builds of what the WSword runtime uses, into
# <prefix>/{include,lib}, from the sources the PC builds pin (wsword/tools/linux/build_deps.sh):
#   SDL3 3.4.16       headers only: the title implements the subset the runtime calls (ps5/wsword/sdl)
#   Vulkan-Headers    1.4.350.1, as the PC; the console's driver is RADV (PS5_Vulkan)
#   FFmpeg 9.0.2      static, LGPL, just what the game's movies need (the PC's configuration), Zen 2 assembly kept
#   shaderc 2026.3    static (glslang, SPIRV-Tools): the runtime's GLSL -> SPIR-V
#   zlib              PS5_Vulkan's pinned build (its setup-native-dependencies.sh), when given; otherwise 1.3.2 here
# Each part is skipped when its output exists (delete the prefix to redo).
set -euo pipefail
sdk=$(cd -- "${1:?usage: deps.sh <payload SDK> <prefix> [<zlib root>]}" && pwd)
mkdir -p "${2:?prefix}"
P=$(cd -- "$2" && pwd)
zroot=${3:-}
S=$P/src
W=$P/build
mkdir -p "$S" "$W" "$P/include" "$P/lib"
JOBS=$(nproc)

fetch() {  # url sha256 file
    [[ -f $S/$3 ]] || { curl -fsSL --retry 3 -o "$S/$3.part" "$1" && mv "$S/$3.part" "$S/$3"; }
    echo "$2  $S/$3" | sha256sum -c --quiet
}
unpack() { rm -rf "$W/$2" && mkdir -p "$W/$2" && tar -xf "$S/$1" -C "$W/$2" --strip-components 1; }

if [[ ! -f $P/include/SDL3/SDL.h ]]; then
    fetch https://github.com/libsdl-org/SDL/releases/download/release-3.4.16/SDL3-3.4.16.tar.gz \
        7322236cd12090c3eb40b9728be4d49c76f66ad17d04369584d4ecad5cf77c68 SDL3-3.4.16.tar.gz
    unpack SDL3-3.4.16.tar.gz sdl
    cp -R "$W/sdl/include/SDL3" "$P/include/"
fi

if [[ ! -f $P/include/vulkan/vulkan.h ]]; then
    fetch https://github.com/KhronosGroup/Vulkan-Headers/archive/refs/tags/vulkan-sdk-1.4.350.1.tar.gz \
        6d1bb65e49520344cc0a48af3dc02e993781efff14c7ebdcb8ae9fa23ddf7e83 Vulkan-Headers-1.4.350.1.tar.gz
    unpack Vulkan-Headers-1.4.350.1.tar.gz vulkan-headers
    cp -R "$W/vulkan-headers/include/vulkan" "$W/vulkan-headers/include/vk_video" "$P/include/"
fi

if [[ ! -f $P/lib/libz.a ]]; then
    if [[ -n $zroot && -f $zroot/usr/include/zlib.h ]]; then
        cp "$zroot"/usr/include/zlib.h "$zroot"/usr/include/zconf.h "$P/include/"
        cp "$(find "$zroot" -name libz.a -print -quit)" "$P/lib/"
    else
        fetch https://zlib.net/fossils/zlib-1.3.2.tar.gz \
            bb329a0a2cd0274d05519d61c667c062e06990d72e125ee2dfa8de64f0119d16 zlib-1.3.2.tar.gz
        unpack zlib-1.3.2.tar.gz zlib
        (cd "$W/zlib" && CC="$sdk/bin/prospero-clang" AR="$sdk/bin/prospero-ar" RANLIB="$sdk/bin/prospero-ranlib" \
            CFLAGS="-O2 -march=znver2" ./configure --static --prefix="$P" && make -j"$JOBS" libz.a && make install)
    fi
fi

if [[ ! -f $P/lib/libavcodec.a ]]; then
    if [[ -n ${FFMPEG_SRC:-} ]]; then rm -rf "$W/ffmpeg" && cp -R "$FFMPEG_SRC" "$W/ffmpeg"  # (a checkout of n9.0.2)
    else
        fetch https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz \
            8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e ffmpeg-9.0.2.tar.xz
        unpack ffmpeg-9.0.2.tar.xz ffmpeg
    fi
    # (FreeBSD as far as FFmpeg can tell; the SDK's wrappers bring the console's target, sysroot and libc)
    (cd "$W/ffmpeg" && ./configure --prefix="$P" --enable-cross-compile --target-os=freebsd --arch=x86_64 --cpu=znver2 \
        --cc="$sdk/bin/prospero-clang" --cxx="$sdk/bin/prospero-clang++" --ar="$sdk/bin/prospero-ar" \
        --ranlib="$sdk/bin/prospero-ranlib" --nm="$sdk/bin/prospero-nm" --strip="$sdk/bin/prospero-strip" \
        --pkg-config=false --enable-static --disable-shared --enable-pic \
        --disable-autodetect --disable-programs --disable-doc --disable-network --disable-avdevice --disable-avfilter \
        --disable-swresample --disable-everything \
        --enable-protocol=file --enable-demuxer=matroska,mov \
        --enable-decoder=vp9,vp8,vorbis,opus,h264,aac --enable-parser=vp9,vp8,vorbis,opus,h264,aac \
        --enable-pthreads > "$W/ffmpeg.configure.log" 2>&1 || { tail -40 "$W/ffmpeg/ffbuild/config.log"; exit 1; }
     make -j"$JOBS" > "$W/ffmpeg.build.log" 2>&1 || { tail -40 "$W/ffmpeg.build.log"; exit 1; }
     make install > /dev/null)
fi
grep -q 'GPL version 3\|--enable-gpl' "$P/lib/pkgconfig/libavcodec.pc" && { echo "deps: FFmpeg is not LGPL"; exit 1; }

if [[ ! -f $P/lib/libshaderc_combined.a ]]; then
    if [[ ! -d $W/shaderc/third_party/glslang ]]; then
        if [[ -n ${SHADERC_SRC:-} ]]; then rm -rf "$W/shaderc" && cp -R "$SHADERC_SRC" "$W/shaderc"  # (v2026.3)
        else
            fetch https://github.com/google/shaderc/archive/refs/tags/v2026.3.tar.gz \
                ee493ccf1b3038b4ef2fe024664c5eb2dc4bcc1f6b05b33e3909de0e19c81024 shaderc-2026.3.tar.gz
            unpack shaderc-2026.3.tar.gz shaderc
        fi
        (cd "$W/shaderc" && python3 utils/git-sync-deps)
    fi
    cmake -S "$W/shaderc" -B "$W/shaderc/build" -G Ninja -DCMAKE_TOOLCHAIN_FILE="$sdk/toolchain/prospero.cmake" \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_FLAGS="-march=znver2" -DCMAKE_CXX_FLAGS="-march=znver2" \
        -DCMAKE_VERBOSE_MAKEFILE=OFF -DCMAKE_INSTALL_PREFIX="$P" -DSHADERC_SKIP_TESTS=ON -DSHADERC_SKIP_EXAMPLES=ON \
        -DSHADERC_SKIP_COPYRIGHT_CHECK=ON -DSPIRV_SKIP_TESTS=ON -DSPIRV_SKIP_EXECUTABLES=ON \
        -DENABLE_GLSLANG_BINARIES=OFF -DSPIRV_TOOLS_BUILD_STATIC=ON -DBUILD_SHARED_LIBS=OFF \
        > "$W/shaderc.configure.log" 2>&1 || { tail -40 "$W/shaderc.configure.log"; exit 1; }
    cmake --build "$W/shaderc/build" --target shaderc_combined -j"$JOBS" > "$W/shaderc.build.log" 2>&1 \
        || { grep -E "error|FAILED" "$W/shaderc.build.log" | head -40; exit 1; }
    mkdir -p "$P/include/shaderc"
    cp "$W/shaderc/libshaderc/include/shaderc/"*.h "$P/include/shaderc/"
    cp "$W/shaderc/build/libshaderc/libshaderc_combined.a" "$P/lib/"
fi
echo "deps: $(cd "$P/lib" && ls *.a | tr '\n' ' ')"
