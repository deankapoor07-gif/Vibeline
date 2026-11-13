#!/bin/bash
# Puts the analyser's Python (from tool/build_helper.sh) inside a built app
# and signs every program file in it, then the app itself.
#   tool/bundle_helper.sh "build/macos/Build/Products/Release/D-Jay Noodles.app" ["signing identity"]
# For selling, pass a "Developer ID Application: ..." identity: the hardened
# runtime and a secure timestamp are added, as notarisation requires.
set -euo pipefail
APP="$1"
ID="${2:-Apple Development: Dean Kapoor (8DGBFY489S)}"
SRC="$HOME/NoodlesBuild/helper"
[ -x "$SRC/python/bin/python3" ] && [ -x "$SRC/bin/ffmpeg" ] && [ -f "$SRC/lib/libnoodles_stretch.dylib" ] \
  || { echo "Run tool/build_helper.sh first"; exit 1; }
DEST="$APP/Contents/Resources/helper"
rm -rf "$DEST"; mkdir -p "$DEST"
ditto "$SRC" "$DEST"
OPTS=(--force --sign "$ID")
case "$ID" in "Developer ID"*) OPTS+=(--options runtime --timestamp);; esac
# Libraries first, then the programs that load them.
n=0
while IFS= read -r -d '' f; do
  if file -b "$f" | grep -q "Mach-O"; then codesign "${OPTS[@]}" "$f" 2>/dev/null; n=$((n+1)); fi
done < <(find "$DEST" -type f \( -name "*.so" -o -name "*.dylib" -o -perm -u+x \) ! -name "*.py" -print0)
echo "signed $n helper files"
codesign "${OPTS[@]}" --deep --preserve-metadata=entitlements,flags,runtime "$APP"
codesign --verify --deep --strict "$APP" && echo "app signature OK"
