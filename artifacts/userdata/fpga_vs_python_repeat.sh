#!/bin/sh
# ============================================================
# fpga_vs_python_repeat.sh - repeated GC measurements
#
#   sh fpga_vs_python_repeat.sh [N]        (default 10)
#
# Group 1: N runs, different seeds
# Group 2: 5 runs, same seed
#
# The full transcript goes to logs/fpga_vs_python_repeat_<time>.log.
# Exit code is evidence: any non-zero child, or a missing summary line,
# turns the whole run red. REPEAT_DONE is only printed when everything passed.
# ============================================================
D=$(cd "$(dirname "$0")" && pwd)
N=${1:-10}
export FOGCCC_NO_LOG=1

# Re-run once with stdout/stderr captured, then print the log so the
# caller still sees it live and the exit code stays the inner one.
if [ -z "$REPEAT_LOGGED" ]; then
    mkdir -p "$D/logs" 2>/dev/null
    LOG="$D/logs/fpga_vs_python_repeat_$(date +%Y%m%d_%H%M%S).log"
    REPEAT_LOGGED=1 REPEAT_LOG="$LOG" \
        sh "$D/$(basename "$0")" "$@" > "$LOG" 2>&1
    rc=$?
    cat "$LOG"
    echo "   log    : $LOG"
    exit $rc
fi
BASE=$((20251017))
fail=0

echo "################################################################"
echo "#  log: $REPEAT_LOG"
echo "#  REPEAT TEST   N=$N   dir=$D"
echo "################################################################"

echo "=== GROUP1: fpga_vs_python, different seeds (vs Python BFS 参照) ==="
i=1
while [ $i -le $N ]; do
    seed=$((BASE + i))
    out=$(python3 "$D/fpga_vs_python.py" 4096 1 2 --seed "$seed" 2>&1)
    rc=$?
    echo "$out" | grep -E '^  \[ *1/'
    if [ $rc -ne 0 ] || ! echo "$out" | grep -q 'PASSED (all invariants)'; then
        fail=$((fail + 1))
        echo "  FAIL group1 seed=$seed rc=$rc"
    fi
    i=$((i + 1))
done

echo "=== GROUP2: same seed x5 (DDR jitter only) ==="
i=1
while [ $i -le 5 ]; do
    out=$(python3 "$D/fpga_vs_python.py" 4096 1 2 --seed 424242 2>&1)
    rc=$?
    echo "$out" | grep -E '^  \[ *1/'
    if [ $rc -ne 0 ] || ! echo "$out" | grep -q 'PASSED (all invariants)'; then
        fail=$((fail + 1))
        echo "  FAIL group2 run=$i rc=$rc"
    fi
    i=$((i + 1))
done

if [ $fail -ne 0 ]; then
    echo "=== REPEAT_FAILED ($fail) ==="
    exit 1
fi
echo "=== REPEAT_DONE ==="
exit 0
