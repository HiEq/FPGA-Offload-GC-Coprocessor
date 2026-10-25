#!/bin/sh
# run_sim.sh - Linux twin of run_sim.bat (same compile list, snapshot and criteria).
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
CACHE=${TMPDIR:-/tmp}/fogccc_run_sim
mkdir -p "$CACHE" || exit 1
cd "$CACHE" || exit 1

echo "=== xvlog ==="
"$XV/xvlog" -sv \
    "$SRC/rtl/gc_top.v" \
    "$SRC/rtl/gc_mark_engine.v" \
    "$SRC/rtl/gc_axi_read.v" \
    "$SRC/rtl/gc_bitmap.v" \
    "$SRC/rtl/gc_queue.v" \
    "$SRC/rtl/gc_freelist.v" \
    "$SRC/rtl/gc_dirty_fifo.v" \
    "$SRC/rtl/gc_regs.v" \
    "$SRC/sim/axi_proto_check.v" \
    "$SRC/sim/tb_gc_top.v" || exit 1

echo "=== xelab ==="
"$XV/xelab" tb_gc_top -s tb_sim --mt 8 || exit 1

echo "=== xsim ==="
"$XV/xsim" tb_sim -R > tb_sim.log 2>&1 || { cat tb_sim.log; exit 1; }
cat tb_sim.log

grep -q '\[TB\]\[FAIL\]' tb_sim.log && { echo "=== REPORTED FAILURES (see $CACHE/tb_sim.log) ===" >&2; exit 1; }
grep -q '\[TB\] ==================== PASS' tb_sim.log || { echo "=== NO PASS BANNER (see $CACHE/tb_sim.log) ===" >&2; exit 1; }
echo "=== RUN_SIM DONE ==="
echo "cache dir: $CACHE"
