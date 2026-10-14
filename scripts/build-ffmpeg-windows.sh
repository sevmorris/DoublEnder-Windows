#!/usr/bin/env bash
# Builds the minimal LGPL ffmpeg.exe the Windows package ships for AAC, from
# the source pinned in Vendor/ffmpeg-manifest.env.
#
# Cross-compiles with mingw-w64: CI runs it on Ubuntu (apt: mingw-w64 nasm),
# and it runs on a Mac with Homebrew's mingw-w64 and nasm. Static, so the exe
# needs nothing but Windows' own DLLs.
#
#   scripts/build-ffmpeg-windows.sh [output-dir]
#       ffmpeg.exe, ffmpeg-LICENSE.txt and ffmpeg-SOURCE.txt in output-dir
#       (default build/ffmpeg-windows); package-windows.ps1 ships all three.
#   scripts/build-ffmpeg-windows.sh --native [output-dir]
#       the same components built for this machine, to try AACEncoder's
#       command where a Windows exe can't run (default build/ffmpeg-native).
set -euo pipefail
cd "$(dirname "$0")/.."

native=0
if [ "${1:-}" = "--native" ]; then
    native=1
    shift
fi
out="${1:-build/ffmpeg-$([ $native = 1 ] && echo native || echo windows)}"
mkdir -p "$out"
out="$(cd "$out" && pwd)"

# shellcheck source=../Vendor/ffmpeg-manifest.env
. Vendor/ffmpeg-manifest.env

# A fixed path, not mktemp: configure records its paths in the binary, so a
# random one would make every build differ.
work=/tmp/doublender-ffmpeg-build
rm -rf "$work"
mkdir -p "$work"
trap 'rm -rf "$work"' EXIT

sha256() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi | awk '{print $1}'
}

echo "▶ FFmpeg $FFMPEG_VERSION source"
curl -fL --retry 3 --retry-delay 2 -o "$work/ffmpeg.tar.xz" "$FFMPEG_SOURCE_URL"
got="$(sha256 "$work/ffmpeg.tar.xz")"
if [ "$got" != "$FFMPEG_SOURCE_SHA256" ]; then
    echo "checksum mismatch for $FFMPEG_SOURCE_URL: $got" >&2
    exit 1
fi
tar -xf "$work/ffmpeg.tar.xz" -C "$work"
cd "$work/ffmpeg-$FFMPEG_VERSION"

# Exactly what AACEncoder's command needs: read a file of raw Float32 mono,
# resample to 48 kHz, encode with the native AAC encoder, write an M4A
# (FFmpeg's "ipod" muxer), and report progress on stdout (-progress pipe:1,
# hence the pipe protocol). The ffmpeg program pulls in the few filters it
# always uses (aformat, anull, ...); aresample is named because it converts.
components=(
    --disable-everything --disable-autodetect --disable-network
    --disable-doc --disable-debug --disable-ffplay --disable-ffprobe --disable-avdevice
    --enable-protocol=file --enable-protocol=pipe
    --enable-demuxer=pcm_f32le --enable-decoder=pcm_f32le
    --enable-filter=aresample --enable-filter=aformat --enable-filter=anull
    --enable-encoder=aac
    --enable-muxer=ipod
)

# -ffp-contract=off: the same audio from the same source whichever compiler
# version builds it (see ClipHack's build-ffmpeg.sh).
cflags="-ffp-contract=off"
ldflags=""
if [ $native = 1 ]; then
    target=()
    exe=ffmpeg
    # macOS clang's default -fstack-check breaks FFmpeg's codegen.
    if [ "$(uname -s)" = Darwin ]; then
        cflags="$cflags -fno-stack-check"
    fi
else
    target=(--enable-cross-compile --target-os=mingw32 --arch=x86_64 --cross-prefix=x86_64-w64-mingw32-)
    exe=ffmpeg.exe
    # -static: libgcc in the exe, not beside it. The PE header's timestamp
    # is the source's release date, not now, so the same toolchain rebuilds
    # the exe byte for byte: the linker leaves it out, and binutils' strip
    # (which FFmpeg's build runs) takes SOURCE_DATE_EPOCH.
    ldflags="-static -Wl,--no-insert-timestamp"
    day="$FFMPEG_SOURCE_RELEASE_DATE 00:00:00"
    SOURCE_DATE_EPOCH="$(date -u -d "$day" +%s 2>/dev/null || date -u -j -f '%Y-%m-%d %H:%M:%S' "$day" +%s)"
    export SOURCE_DATE_EPOCH
fi

echo "▶ configure ($([ $native = 1 ] && echo native || echo x86_64 Windows))"
./configure --prefix="$work/install" ${target[@]+"${target[@]}"} \
    --enable-static --disable-shared \
    --extra-cflags="$cflags" --extra-ldflags="$ldflags" \
    "${components[@]}" >"$work/configure.log" || { tail -30 "$work/configure.log" >&2; exit 1; }

jobs="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"
echo "▶ make -j$jobs"
make -j"$jobs" >"$work/make.log" 2>&1 || { tail -40 "$work/make.log" >&2; exit 1; }

# --- Verification gates (fail closed) ------------------------------------------
echo "▶ verifying"
[ -f "$exe" ] || { echo "FAIL: configure dropped the ffmpeg program" >&2; exit 1; }
# Components' switches are in config_components.h (FFmpeg 5.1 on), the rest in config.h.
config() { grep -hE "^#define CONFIG_$1 " config.h config_components.h | awk '{print $3}'; }
for flag in GPL NONFREE VERSION3; do
    [ "$(config $flag)" = 0 ] || { echo "FAIL: CONFIG_$flag is set; this build must stay LGPL-2.1" >&2; exit 1; }
done
for part in FFMPEG AAC_ENCODER IPOD_MUXER PCM_F32LE_DEMUXER PCM_F32LE_DECODER FILE_PROTOCOL PIPE_PROTOCOL ARESAMPLE_FILTER; do
    [ "$(config $part)" = 1 ] || { echo "FAIL: CONFIG_$part is missing" >&2; exit 1; }
done
if [ $native = 0 ]; then
    # Windows' own DLLs only: a libgcc or winpthread DLL would mean a guest
    # gets "missing DLL" instead of a recording.
    objdump=x86_64-w64-mingw32-objdump
    dlls="$($objdump -p "$exe" | sed -n 's/^[[:space:]]*DLL Name: //p')"
    [ -n "$dlls" ] || { echo "FAIL: no imports read from $exe" >&2; exit 1; }
    foreign="$(printf '%s\n' "$dlls" | grep -viE '^(kernel32|user32|advapi32|shell32|ole32|bcrypt|msvcrt|ucrtbase|api-ms-win-[a-z0-9-]+)\.dll$' || true)"
    [ -z "$foreign" ] || { echo "FAIL: $exe needs DLLs Windows doesn't have:" >&2; echo "$foreign" >&2; exit 1; }
fi

cp "$exe" "$out/$exe"
cp COPYING.LGPLv2.1 "$out/ffmpeg-LICENSE.txt"
configuration="$(sed -n 's/^#define FFMPEG_CONFIGURATION "\(.*\)"$/\1/p' config.h)"
cat >"$out/ffmpeg-SOURCE.txt" <<EOF
ffmpeg$([ $native = 1 ] || echo .exe) is FFmpeg $FFMPEG_VERSION, licensed under the GNU Lesser General
Public License 2.1 or later (ffmpeg-LICENSE.txt). It was built from the
unmodified upstream source:

  $FFMPEG_SOURCE_URL
  SHA-256 $FFMPEG_SOURCE_SHA256
  git tag $FFMPEG_SOURCE_GIT_TAG at https://git.ffmpeg.org/ffmpeg.git

by DoublEnder's scripts/build-ffmpeg-windows.sh, configured with:

  $configuration
EOF
echo "▶ $out/$exe ($(wc -c <"$out/$exe" | tr -d ' ') bytes)"
