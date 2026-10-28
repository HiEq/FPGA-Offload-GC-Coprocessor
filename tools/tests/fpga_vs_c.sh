#!/bin/sh
# fpga_vs_c.sh - FPGA vs C 计数对比，输出同时写入 logs/fpga_vs_c_<时间>.log
D=$(cd "$(dirname "$0")" && pwd)
L="$D/logs"
mkdir -p "$L" 2>/dev/null
LOG="$L/fpga_vs_c_$(date +%Y%m%d_%H%M%S).log"
if [ ! -x "$D/bin/test_main" ]; then
    echo "missing $D/bin/test_main" >&2
    exit 2
fi
"$D/bin/test_main" > "$LOG" 2>&1
rc=$?
cat "$LOG"
echo " log    : $LOG"
exit $rc
