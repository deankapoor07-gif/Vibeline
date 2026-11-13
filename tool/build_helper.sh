#!/bin/bash
# Builds the analyser's own Python (standalone CPython + the packages in
# tool/helper-requirements.lock) in ~/NoodlesBuild/helper, outside iCloud.
# Run once, and again only when the packages change.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
PBS_TAG=20261021           # python-build-standalone release (a few weeks old)
PY=3.11.17
NAME="cpython-$PY+$PBS_TAG-aarch64-apple-darwin-install_only_stripped.tar.gz"
OUT="$HOME/NoodlesBuild"; mkdir -p "$OUT/download"
cd "$OUT/download"
if [ ! -f "$NAME" ]; then
  curl -fsSL -o "$NAME" "https://github.com/astral-sh/python-build-standalone/releases/download/$PBS_TAG/${NAME//+/%2B}"
  curl -fsSL -o SHA256SUMS "https://github.com/astral-sh/python-build-standalone/releases/download/$PBS_TAG/SHA256SUMS"
fi
grep " $NAME\$" SHA256SUMS | shasum -a 256 -c -
rm -rf "$OUT/helper"; mkdir -p "$OUT/helper"
tar -xzf "$NAME" -C "$OUT/helper"
P="$OUT/helper/python"
"$P/bin/python3" -m pip install --no-warn-script-location --disable-pip-version-check -q \
  -r "$REPO/tool/helper-requirements.lock"
# Things the analyser never uses.
SP="$P/lib/python3.11/site-packages"
rm -rf "$SP/torch/include" "$SP"/pip "$SP"/pip-* "$P/lib/python3.11/tkinter" "$P/lib/python3.11/idlelib" \
       "$P/lib/python3.11/turtledemo" "$P/lib/python3.11/ensurepip" "$P"/lib/tcl* "$P"/lib/tk* "$P/lib/itcl"* "$P/lib/thread"* "$P/include"
find "$P" -name "__pycache__" -type d -prune -exec rm -rf {} +
# Compiled once here, because a signed app can't write inside itself later.
"$P/bin/python3" -m compileall -q -j 0 "$P/lib/python3.11" >/dev/null || true

# Audio decoding: FFmpeg built with only what's needed to read songs (no
# video, nothing GPL), so it's LGPL. Its source goes in the app alongside it,
# as the LGPL asks.
FF=9.0.2
FF_SHA=8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e
cd "$OUT/download"
[ -f "ffmpeg-$FF.tar.xz" ] || curl -fsSL -o "ffmpeg-$FF.tar.xz" "https://ffmpeg.org/releases/ffmpeg-$FF.tar.xz"
echo "$FF_SHA  ffmpeg-$FF.tar.xz" | shasum -a 256 -c -
rm -rf "$OUT/ffmpeg-src"; mkdir -p "$OUT/ffmpeg-src"
tar -xJf "ffmpeg-$FF.tar.xz" -C "$OUT/ffmpeg-src"
cd "$OUT/ffmpeg-src/ffmpeg-$FF"
FF_CONFIG=(--prefix="$OUT/ffmpeg-out"
  --disable-everything --disable-autodetect --disable-network --disable-doc --disable-ffplay --disable-ffprobe
  --disable-debug --disable-avdevice --disable-swscale --enable-swresample --enable-avfilter
  --enable-static --disable-shared --enable-protocol=file --enable-protocol=pipe
  --enable-demuxer=mp3,mov,aac,flac,wav,aiff,w64,caf --enable-parser=mpegaudio,aac,aac_latm,flac
  --enable-decoder=mp3float,mp3,mp3adufloat,mp3on4float,aac,aac_fixed,aac_latm,alac,flac,pcm_s16le,pcm_s16be,pcm_s24le,pcm_s24be,pcm_s32le,pcm_s32be,pcm_f32le,pcm_f32be,pcm_f64le,pcm_f64be,pcm_u8,pcm_s8,pcm_alaw,pcm_mulaw,adpcm_ima_qt,adpcm_ms,adpcm_ima_wav
  --enable-encoder=pcm_f32le --enable-muxer=pcm_f32le,wav
  --enable-filter=aresample,aformat,anull,abuffer,abuffersink,atrim,pan
  --extra-cflags=-mmacosx-version-min=12.0 --extra-ldflags=-mmacosx-version-min=12.0)
./configure "${FF_CONFIG[@]}" >/dev/null
make -j8 >/dev/null 2>&1 && make install >/dev/null
"$OUT/ffmpeg-out/bin/ffmpeg" -hide_banner -L 2>/dev/null | grep -q "Lesser General Public License" \
  || { echo "FFmpeg isn't LGPL - stop"; exit 1; }
H="$OUT/helper"
mkdir -p "$H/bin" "$H/lib" "$H/licenses/ffmpeg" "$H/licenses/signalsmith-stretch" "$H/licenses/signalsmith-linear"
cp "$OUT/ffmpeg-out/bin/ffmpeg" "$H/bin/ffmpeg"
cp "$OUT/download/ffmpeg-$FF.tar.xz" COPYING.LGPLv2.1 "$H/licenses/ffmpeg/"
printf 'FFmpeg %s, built with:\n%s\n' "$FF" "${FF_CONFIG[*]}" > "$H/licenses/ffmpeg/BUILD.txt"

# Time-stretching: Signalsmith Stretch (MIT), from third_party/.
"$REPO/tool/stretch/build.sh" "$H/lib" >/dev/null
cp "$REPO/third_party/signalsmith-stretch/LICENSE.txt" "$H/licenses/signalsmith-stretch/"
cp "$REPO/third_party/signalsmith-linear/LICENSE.txt" "$H/licenses/signalsmith-linear/"
du -sh "$P" "$H"
