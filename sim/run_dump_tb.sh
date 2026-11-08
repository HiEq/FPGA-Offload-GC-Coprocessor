#!/bin/sh
# run_dump_tb.sh - Linux twin of run_dump_tb.bat (bitmap DMA dump check).
set -u
if [ -n "${VIVADO_BIN:-}" ]; then
    XV=$VIVADO_BIN
elif command -v vivado >/dev/null 2>&1; then
    XV=$(dirname "$(command -v vivado)")
else
    echo "ERROR: Vivado not found. Set VIVADO_BIN to the folder containing xvlog." >&2
    exit 1
fi
SRC=$(cd "$(dirname "$0")/.." && pwd)
CACHE=${TMPDIR:-/tmp}/fogccc_dump_tb
mkdir -p "$CACHE" || exit 1
cd "$CACHE" || exit 1

echo "=== xvlog ==="
"$XV/xvlog" -sv \
    "$SRC/rtl/gc_dump.v" "$SRC/rtl/gc_bitmap.v" "$SRC/sim/tb_gc_dump.v" || exit 1

echo "=== xelab ==="
"$XV/xelab" tb_gc_dump -s tb_gc_dump --mt 8 > dump_xelab.log 2>&1 || {
    echo "XELAB FAILED"; cat dump_xelab.log; exit 1; }

echo "=== xsim ==="
"$XV/xsim" tb_gc_dump -R > dump.log 2>&1 || {
    echo "XSIM FAILED"; cat dump.log; exit 1; }
if grep -q 'DUMP_RESULT OK' dump.log; then
    echo "done tb_gc_dump"
else
    echo "DUMP TB FAILED"
    cat dump.log
    exit 1
fi
