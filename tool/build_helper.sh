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
du -sh "$P"
