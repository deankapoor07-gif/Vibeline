#!/bin/bash
# Builds libnoodles_stretch.dylib (Signalsmith Stretch, MIT) for the helper.
# Usage: tool/stretch/build.sh <out_dir>
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
tp="$here/../../third_party"
out="${1:-$here/build}"
mkdir -p "$out"
clang++ -std=c++17 -O3 -fPIC -shared -arch arm64 -mmacosx-version-min=12.0 \
  -DSIGNALSMITH_USE_ACCELERATE -I "$tp" \
  -framework Accelerate \
  -o "$out/libnoodles_stretch.dylib" "$here/noodles_stretch.cpp"
echo "$out/libnoodles_stretch.dylib"
