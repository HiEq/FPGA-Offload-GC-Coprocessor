#!/bin/sh
# run_sim.sh - run Vivado xsim on tb_gc_top (Linux counterpart of run_sim.bat).
# Exit code is evidence: xsim returns 0 even when the TB prints failures, so the
# log is grepped for [TB][FAIL] / [AXI][FAIL] and the PASS banner must be present.
# Set VIVADO_BIN to the folder holding xvlog, or have vivado on PATH.
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
CACHE=${TMPDIR:-/tmp}/fogccc_sim
mkdir -p "$CACHE" || exit 1
cd "$CACHE" || exit 1

echo "=== xvlog ==="
"$XV/xvlog" \
    "$SRC/rtl/gc_top.v" \
    "$SRC/rtl/gc_mark_engine.v" \
    "$SRC/rtl/gc_axi_read.v" \
    "$SRC/rtl/gc_bitmap.v" \
    "$SRC/rtl/gc_queue.v" \
    "$SRC/rtl/gc_regs.v" \
    "$SRC/sim/axi_proto_check.v" \
    "$SRC/sim/tb_gc_top.v" || exit 1

echo "=== xelab ==="
"$XV/xelab" tb_gc_top -s tb_sim --debug typical --mt 20 || exit 1

echo "=== xsim ==="
"$XV/xsim" tb_sim -R > xsim_tb.log 2>&1 || { cat xsim_tb.log; exit 1; }
cat xsim_tb.log

grep -q -e '\[TB\]\[FAIL\]' -e '\[AXI\]\[FAIL\]' xsim_tb.log && {
    echo "=== SIM REPORTED FAILURES (see $CACHE/xsim_tb.log) ===" >&2
    exit 1
}
grep -q '\[TB\] ==================== PASS' xsim_tb.log || {
    echo "=== SIM DID NOT REACH ITS PASS BANNER (see $CACHE/xsim_tb.log) ===" >&2
    exit 1
}

echo "=== SIM DONE ==="
echo "cache dir: $CACHE"
