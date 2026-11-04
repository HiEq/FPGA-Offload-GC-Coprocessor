#!/bin/bash
# Cross-build the C/DMA graph-build verification binaries.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SDK_ENV="${SDK_ENV:-$HOME/petalinux_sdk/environment-setup-cortexa9t2hf-neon-amd-linux-gnueabi}"
[ -f "$SDK_ENV" ] || { echo "ERROR: SDK_ENV not found: $SDK_ENV"; exit 1; }
# shellcheck disable=SC1090
. "$SDK_ENV"
OUT="$ROOT/artifacts/userdata/bin"
mkdir -p "$OUT"

$CC -O2 -Wall -Wextra -o "$OUT/verify_c_build" \
    "$ROOT/csrc/build_routes/verify_c_build.c" \
    "$ROOT/csrc/fpga_gc.c" -I"$ROOT/csrc"
$CC -O2 -Wall -Wextra -o "$OUT/verify_dma_build" \
    "$ROOT/csrc/build_routes/verify_dma_build.c" \
    "$ROOT/csrc/fpga_gc.c" -I"$ROOT/csrc"
$CC -O2 -Wall -Wextra -o "$OUT/dma_build_one" \
    "$ROOT/csrc/build_routes/dma_build_one.c" -I"$ROOT/csrc"

file "$OUT/verify_c_build" "$OUT/verify_dma_build" "$OUT/dma_build_one"
echo "=== C build-route binaries DONE ==="
