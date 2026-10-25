#!/bin/sh
# run_regs_aww_tb.sh - Linux twin of run_regs_aww_tb.bat (same compile list, snapshot and criteria).
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
CACHE=${TMPDIR:-/tmp}/fogccc_run_regs_aww_tb
mkdir -p "$CACHE" || exit 1
cd "$CACHE" || exit 1

echo "=== xvlog ==="
"$XV/xvlog" -sv \
    "$SRC/rtl/gc_regs.v" \
    "$SRC/sim/tb_regs_aww.v" || exit 1

echo "=== xelab ==="
"$XV/xelab" tb_regs_aww -s regs_aww_tb --mt 8 || exit 1

echo "=== xsim ==="
"$XV/xsim" regs_aww_tb -R > regs_aww_tb.log 2>&1 || { cat regs_aww_tb.log; exit 1; }
cat regs_aww_tb.log

grep -q '\[AW-W\]\[FAIL\]' regs_aww_tb.log && { echo "=== REPORTED FAILURES (see $CACHE/regs_aww_tb.log) ===" >&2; exit 1; }
grep -q '\[AW-W\] ==================== PASS' regs_aww_tb.log || { echo "=== NO PASS BANNER (see $CACHE/regs_aww_tb.log) ===" >&2; exit 1; }
echo "=== RUN_REGS_AWW_TB DONE ==="
echo "cache dir: $CACHE"
