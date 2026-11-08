#!/bin/sh
# run_smp_tb.sh - Linux twin of run_smp_tb.bat (Step 2 blocks: bitmap banks + push arbiter).
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
CACHE=${TMPDIR:-/tmp}/fogccc_smp_tb
mkdir -p "$CACHE" || exit 1
cd "$CACHE" || exit 1

echo "=== xvlog ==="
"$XV/xvlog" -sv \
    "$SRC/rtl/gc_bitmapN.v" "$SRC/rtl/gc_push_arb.v" "$SRC/rtl/gc_lane.v" \
    "$SRC/rtl/gc_push_fifo.v" \
    "$SRC/sim/tb_gc_bitmap4.v" "$SRC/sim/tb_gc_bitmap2.v" \
    "$SRC/sim/tb_gc_push_arb.v" "$SRC/sim/tb_gc_lane.v" \
    "$SRC/sim/tb_gc_push_fifo.v" || exit 1

fail=0
for tb in tb_gc_bitmap4 tb_gc_bitmap2 tb_gc_push_arb tb_gc_lane tb_gc_push_fifo; do
    echo "=== $tb ==="
    "$XV/xelab" "$tb" -s "$tb" --mt 8 > "${tb}_xelab.log" 2>&1 || {
        echo "XELAB FAILED $tb"; fail=1; continue; }
    "$XV/xsim" "$tb" -R > "$tb.log" 2>&1 || {
        echo "XSIM FAILED $tb"; cat "$tb.log"; fail=1; continue; }
    if grep -q '_RESULT OK' "$tb.log"; then
        echo "done $tb"
    else
        echo "NO OK BANNER $tb"
        cat "$tb.log"
        fail=1
    fi
done
echo "=== SMP TB DONE ==="
[ "$fail" -eq 0 ] || exit 1

