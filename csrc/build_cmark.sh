#!/bin/bash
# Cross-build cmark with the PetaLinux SDK.
#
# Why not the gcc inside the PetaLinux build tree: that cross-canadian gcc has a
# broken relocated prefix (`-print-sysroot` returns /not/exist, and crtbeginS.o
# only resolves to a bare name), so linking fails. The standalone SDK ships a
# working compiler with its own --sysroot.
#
#   ./csrc/build_cmark.sh
#   SDK_ENV=/path/to/environment-setup-... ./csrc/build_cmark.sh
#
# Output: artifacts/userdata/cmark  (ARM, dynamic; the rootfs has glibc 2.39)
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SRC="$HERE/cmark.c"
OUT="$ROOT/artifacts/userdata/cmark"
SDK_ENV="${SDK_ENV:-$HOME/petalinux_sdk/environment-setup-cortexa9t2hf-neon-amd-linux-gnueabi}"

[ -f "$SRC" ]     || { echo "ERROR: $SRC not found"; exit 1; }
[ -f "$SDK_ENV" ] || { echo "ERROR: SDK environment not found: $SDK_ENV"; echo "       set SDK_ENV=<path to environment-setup-...>"; exit 1; }

# shellcheck disable=SC1090
. "$SDK_ENV"
[ -n "${CC:-}" ] || { echo "ERROR: \$CC is empty after sourcing the SDK env"; exit 1; }

echo "=== build cmark ==="
echo "CC  = $CC"
echo "src = $SRC"
echo "out = $OUT"

# Remove the previous binary first: a failed compile must not leave it in place
# and let the script print DONE (a stale binary pretending to be a fresh build).
rm -f "$OUT"
$CC -O2 -Wall -o "$OUT" "$SRC"
rc=$?
if [ "$rc" -ne 0 ] || [ ! -f "$OUT" ]; then
    echo "!!! 编译失败 (rc=$rc)"
    exit 1
fi

file "$OUT" 2>/dev/null || true
ls -la "$OUT"
echo "=== DONE — 板上运行: ./cmark 4096 8 2 ==="
