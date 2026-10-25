#!/bin/sh
# run_port_tb.sh - Linux twin of run_port_tb.bat (the three hand-over TBs).
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
CACHE=${TMPDIR:-/tmp}/fogccc_port_tb
mkdir -p "$CACHE" || exit 1
cd "$CACHE" || exit 1

echo "=== xvlog (all RTL once) ==="
"$XV/xvlog" -sv \
    "$SRC/rtl/gc_top.v" "$SRC/rtl/gc_mark_engine.v" "$SRC/rtl/gc_axi_read.v" \
    "$SRC/rtl/gc_bitmap.v" "$SRC/rtl/gc_queue.v" "$SRC/rtl/gc_freelist.v" \
    "$SRC/rtl/gc_dirty_fifo.v" "$SRC/rtl/gc_regs.v" "$SRC/sim/axi_proto_check.v" \
    "$SRC/sim/tb_flush_data.v" "$SRC/sim/tb_stale_ar_flush.v" "$SRC/sim/tb_start_while_busy.v" || exit 1

fail=0
for tb in tb_flush_data tb_stale_ar_flush tb_start_while_busy; do
    echo "=== $tb ==="
    "$XV/xelab" "$tb" -s "$tb" --mt 8 > "${tb}_xelab.log" 2>&1 || { echo "XELAB FAILED $tb"; fail=1; continue; }
    "$XV/xsim" "$tb" -R > "$tb.log" 2>&1 || { echo "XSIM FAILED $tb"; cat "$tb.log"; fail=1; continue; }
    if grep -q '\[FAIL\]' "$tb.log"; then
        echo "FAIL LINES in $tb"
        grep '\[FAIL\]' "$tb.log"
        fail=1
    elif grep -q 'PASS' "$tb.log"; then
        echo "done $tb"
    else
        echo "NO PASS BANNER $tb"
        fail=1
    fi
done
echo "=== PORT TB DONE ==="
[ "$fail" -eq 0 ] || exit 1
