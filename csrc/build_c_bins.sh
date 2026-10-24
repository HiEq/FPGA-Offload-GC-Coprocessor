#!/bin/bash
# Cross-build the three card-side C binaries with the PetaLinux SDK:
#   artifacts/userdata/bin/test_main
#   artifacts/userdata/py/libfogccc.so
#
#   ./csrc/build_c_bins.sh
#   SDK_ENV=/path/to/environment-setup-... ./csrc/build_c_bins.sh
#
# Why not the gcc inside the PetaLinux build tree: that cross-canadian gcc has a
# broken relocated prefix (`-print-sysroot` returns /not/exist, and crtbeginS.o
# only resolves to a bare name), so linking fails. The standalone SDK ships a
# working compiler with its own --sysroot (see AGENT_NOTES_pitfalls.md F13).
# After a successful build run tools/make_manifest.ps1 to refresh
# artifacts/SHA256SUMS (it pins these three hashes).
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SDK_ENV="${SDK_ENV:-$HOME/petalinux_sdk/environment-setup-cortexa9t2hf-neon-amd-linux-gnueabi}"

[ -f "$SDK_ENV" ] || {
    echo "ERROR: SDK environment not found: $SDK_ENV"
    echo "       set SDK_ENV=<path to environment-setup-...>"
    exit 1
}

# shellcheck disable=SC1090
. "$SDK_ENV"
[ -n "${CC:-}" ] || { echo "ERROR: \$CC is empty after sourcing the SDK env"; exit 1; }

OUT_TM="$ROOT/artifacts/userdata/bin/test_main"
OUT_SO="$ROOT/artifacts/userdata/py/libfogccc.so"
mkdir -p "$(dirname "$OUT_TM")" "$(dirname "$OUT_SO")"
rm -f "$OUT_TM" "$OUT_SO"

echo "CC = $CC"
echo "=== test_main ==="
$CC -O2 -o "$OUT_TM" "$HERE/fpga_gc.c" "$HERE/test_main.c" || { echo "!!! test_main build failed"; exit 1; }

echo "=== libfogccc.so ==="
$CC -O2 -shared -fPIC -o "$OUT_SO" "$HERE/fpga_gc.c" || { echo "!!! libfogccc.so build failed"; exit 1; }


for f in "$OUT_TM" "$OUT_SO" "$OUT_CM"; do
    file "$f" 2>/dev/null || true
    ls -la "$f"
done
echo "=== DONE ==="