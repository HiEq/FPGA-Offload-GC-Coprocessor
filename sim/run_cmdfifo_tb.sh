#!/bin/sh
# run_cmdfifo_tb.sh - Linux twin of run_cmdfifo_tb.bat (same compile list, snapshot and criteria).
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
CACHE=${TMPDIR:-/tmp}/fogccc_run_cmdfifo_tb
mkdir -p "$CACHE" || exit 1
cd "$CACHE" || exit 1

echo "=== xvlog ==="
"$XV/xvlog" -sv \
    "$SRC/rtl/gc_axi_read.v" \
    "$SRC/sim/tb_cmdfifo_flush.v" || exit 1

echo "=== xelab ==="
"$XV/xelab" tb_cmdfifo_flush -s cmdfifo_tb --mt 8 || exit 1

echo "=== xsim ==="
"$XV/xsim" cmdfifo_tb -R > cmdfifo_tb.log 2>&1 || { cat cmdfifo_tb.log; exit 1; }
cat cmdfifo_tb.log

grep -q '\[CMDFIFO\]\[FAIL\]' cmdfifo_tb.log && { echo "=== REPORTED FAILURES (see $CACHE/cmdfifo_tb.log) ===" >&2; exit 1; }
grep -q '\[CMDFIFO\] ==================== PASS' cmdfifo_tb.log || { echo "=== NO PASS BANNER (see $CACHE/cmdfifo_tb.log) ===" >&2; exit 1; }
echo "=== RUN_CMDFIFO_TB DONE ==="
echo "cache dir: $CACHE"
