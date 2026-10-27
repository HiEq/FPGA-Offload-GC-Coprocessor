#!/bin/sh
# ============================================================
# FOGCCC on-board test launcher
#
#   put this on the USERDATA (FAT32) partition, together with fpga_vs_python.py,
#   and run it from the board:
#
#       sh /mnt/userdata/run_gc.sh            # default 4096 8 2
#       sh /mnt/userdata/run_gc.sh 2048 5 3   # maxN=2048 trials=5 avg_refs=3
#
#   the log is written to logs/ next to this script.
# ============================================================
DIR=$(cd "$(dirname "$0")" && pwd)
MAXN=${1:-4096}
TRIALS=${2:-8}
AVG=${3:-2}
mkdir -p "$DIR/logs" 2>/dev/null
LOG="$DIR/logs/gc_run_$(date +%Y%m%d_%H%M%S).log"

echo "=========================================================="
echo " FOGCCC on-board test"
echo "   script : $DIR/fpga_vs_python.py"
echo "   params : maxN=$MAXN  trials=$TRIALS  avg_refs=$AVG"
echo "   log    : $LOG"
echo "=========================================================="

if [ ! -f "$DIR/fpga_vs_python.py" ]; then
    echo "ERROR: fpga_vs_python.py not found next to this script ($DIR)"
    exit 1
fi

# pipefail: otherwise the pipeline's status is tee's (always 0) and a failing
# fpga_vs_python.py still looks green to the caller.
set -o pipefail
python3 "$DIR/fpga_vs_python.py" "$MAXN" "$TRIALS" "$AVG" 2>&1 | tee "$LOG"
rc=$?
set +o pipefail

echo ""
echo "=========================================================="
echo " done.  log saved on the card: $LOG"
echo " exit code: $rc"
echo "=========================================================="
exit "$rc"
