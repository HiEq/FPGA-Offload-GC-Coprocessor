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
    if [ -f "$DIR/cmark.c" ] && command -v gcc >/dev/null 2>&1; then
        echo "cmark 不存在, 就地编译 (板上有 gcc) ..."
        gcc -O2 -static -o "$DIR/cmark" "$DIR/cmark.c" || {
            echo "ERROR: 板上编译失败"; exit 1; }
        chmod +x "$DIR/cmark"
    else
        echo "ERROR: 找不到 $DIR/cmark (也没有 cmark.c 或 gcc)"
        exit 1
    fi
fi

"$DIR/cmark" "$MAXN" "$TRIALS" "$AVG"
