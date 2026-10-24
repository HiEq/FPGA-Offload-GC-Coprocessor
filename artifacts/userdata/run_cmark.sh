#!/bin/sh
# ============================================================
# run_cmark.sh — FOGCCC C 标记基准运行器
#
#   放在 USERDATA (FAT32) 分区, 和 cmark / cmark.c 放一起
#
# 用法 (板子上):
#   sh /mnt/userdata/run_cmark.sh              # 默认 4096 8 2
#   sh /mnt/userdata/run_cmark.sh 2048 5 3     # maxN=2048 trials=5 avg_refs=3
#
# 流程:
#   1. FPGA 引擎标记
#   2. C 直接读 DDR 标记
#   3. 图拷入堆内存后标记
#   结果需等于期望值 L, 否则报 MISMATCH
#
# 需要 root (访问 /dev/mem)
# ============================================================
DIR=$(cd "$(dirname "$0")" && pwd)
MAXN=${1:-4096}
TRIALS=${2:-8}
AVG=${3:-2}

echo "=========================================================="
echo " FOGCCC  C-mark baseline"
echo "   dir    : $DIR"
echo "   params : maxN=$MAXN  trials=$TRIALS  avg_refs=$AVG"
echo "=========================================================="

if [ ! -x "$DIR/cmark" ]; then
    # No on-board fallback on purpose: this rootfs has no gcc, so a silent
    # "compile here" branch could only ever fail or run a stale binary.
    echo "ERROR: $DIR/cmark is missing or not executable"
    echo "       build it on the host with csrc/build_c_bins.sh and copy it over"
    exit 1
fi

"$DIR/cmark" "$MAXN" "$TRIALS" "$AVG"
rc=$?
if [ "$rc" -ne 0 ]; then
    echo "ERROR: cmark exited $rc (mismatch or timeout)" >&2
fi
exit "$rc"
