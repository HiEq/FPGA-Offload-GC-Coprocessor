#!/bin/sh
# ============================================================
# FOGCCC on-board test launcher
#
#   put this on the USERDATA (FAT32) partition, together with gc_test.py,
#   and run it from the board:
#
#       sh /mnt/userdata/run_gc.sh            # default 4096 8 2
#       sh /mnt/userdata/run_gc.sh 2048 5 3   # maxN=2048 trials=5 avg_refs=3
#
#   the log is written next to this script on the SAME partition, so it
#   survives reboots and can be read from Windows.
# ============================================================
DIR=$(cd "$(dirname "$0")" && pwd)
MAXN=${1:-4096}
TRIALS=${2:-8}
AVG=${3:-2}
mkdir -p "$DIR/logs" 2>/dev/null
LOG="$DIR/logs/gc_run_$(date +%Y%m%d_%H%M%S).log"

echo "=========================================================="
echo " FOGCCC on-board test"
echo "   script : $DIR/gc_test.py"
echo "   params : maxN=$MAXN  trials=$TRIALS  avg_refs=$AVG"
echo "   log    : $LOG"
echo "=========================================================="

if [ ! -f "$DIR/gc_test.py" ]; then
    echo "ERROR: gc_test.py not found next to this script ($DIR)"
    exit 1
fi

python3 "$DIR/gc_test.py" "$MAXN" "$TRIALS" "$AVG" 2>&1 | tee "$LOG"

echo ""
echo "=========================================================="
echo " done.  log saved on the card: $LOG"
echo "=========================================================="
