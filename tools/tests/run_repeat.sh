#!/bin/sh
# ============================================================
# run_repeat.sh - repeated GC / cmark measurements
#
#   sh run_repeat.sh [N]        (default 10)
#
# Group 1: N runs, different seeds
# Group 2: N cmark runs
# Group 3: 5 runs, same seed
#
# Exit code is evidence: any non-zero child, or a missing summary line,
# turns the whole run red. REPEAT_DONE is only printed when everything passed.
# ============================================================
D=$(cd "$(dirname "$0")" && pwd)
N=${1:-10}
BASE=$((20251017))
fail=0

echo "################################################################"
echo "#  REPEAT TEST   N=$N   dir=$D"
echo "################################################################"

echo "=== GROUP1: gc_test, different seeds (vs Python BFS 参照, not CPython gc) ==="
i=1
while [ $i -le $N ]; do
    seed=$((BASE + i))
    out=$(python3 "$D/gc_test.py" 4096 1 2 --seed "$seed" 2>&1)
    rc=$?
    echo "$out" | grep -E '^  \[ *1/'
    if [ $rc -ne 0 ] || ! echo "$out" | grep -q 'PASSED (all invariants)'; then
        fail=$((fail + 1))
        echo "  FAIL group1 seed=$seed rc=$rc"
    fi
    i=$((i + 1))
done

echo "=== GROUP2: cmark, independent graphs (vs C) ==="
i=1
while [ $i -le $N ]; do
    out=$(sh "$D/run_cmark.sh" 4096 1 2 2>&1)
    rc=$?
    echo "$out" | grep -E 'totals:|per object:'
    if [ $rc -ne 0 ]; then
        fail=$((fail + 1))
        echo "  FAIL group2 run=$i rc=$rc"
    fi
    i=$((i + 1))
done

echo "=== GROUP3: same seed x5 (DDR jitter only) ==="
i=1
while [ $i -le 5 ]; do
    out=$(python3 "$D/gc_test.py" 4096 1 2 --seed 424242 2>&1)
    rc=$?
    echo "$out" | grep -E '^  \[ *1/'
    if [ $rc -ne 0 ] || ! echo "$out" | grep -q 'PASSED (all invariants)'; then
        fail=$((fail + 1))
        echo "  FAIL group3 run=$i rc=$rc"
    fi
    i=$((i + 1))
done

if [ $fail -ne 0 ]; then
    echo "=== REPEAT_FAILED ($fail) ==="
    exit 1
fi
echo "=== REPEAT_DONE ==="
exit 0
