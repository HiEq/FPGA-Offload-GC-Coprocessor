#!/bin/bash
# ============================================================
# build_cmark.sh — 交叉编译 cmark.c 到 Zynq (Cortex-A9, armv7-a/neon 硬浮点)
# 用法:  wsl -e bash <工程根>/csrc/build_cmark.sh
# ============================================================
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/csrc/cmark.c"
OUT="$ROOT/artifacts/userdata/cmark"

echo "=== 1. 找存活的 recipe-sysroot 对 ==="
S=""
for proj in fogccc_linux fogccc2_linux; do
    for d in $(find $HOME/xilinx/$proj/build/tmp/work -maxdepth 5 -type d -name 'recipe-sysroot' 2>/dev/null); do
        [ -f "$d/usr/include/stdio.h" ] || continue
        n="${d%recipe-sysroot}recipe-sysroot-native"
        [ -x "$n/usr/bin/arm-amd-linux-gnueabi/arm-amd-linux-gnueabi-gcc" ] || continue
        S=$d; break 2
    done
done
[ -n "$S" ] || { echo "ERROR: 找不到可用的 recipe-sysroot 对"; exit 1; }
N="${S%recipe-sysroot}recipe-sysroot-native"
GCC="$N/usr/bin/arm-amd-linux-gnueabi/arm-amd-linux-gnueabi-gcc"
echo "TARGET sysroot = $S"
echo "NATIVE sysroot = $N"
echo "GCC            = $($GCC --version | head -1)"
echo "as             = $(ls $N/usr/bin/arm-amd-linux-gnueabi/arm-amd-linux-gnueabi-as)"

echo "=== 2. 编译 (静态, 硬浮点) ==="
set +e
CFLAGS="-O2 -static -Wall -march=armv7-a -mtune=cortex-a9 -mfpu=neon -mfloat-abi=hard"
echo "CFLAGS = $CFLAGS"
COMPILER_PATH="$N/usr/bin/arm-amd-linux-gnueabi" \
    "$GCC" $CFLAGS --sysroot="$S" -o "$OUT" "$SRC" 2>&1 | head -25
set -e

echo "=== 3. 结果 ==="
if [ -f "$OUT" ]; then
    STRIP="$N/usr/bin/arm-amd-linux-gnueabi/arm-amd-linux-gnueabi-strip"
    if [ -x "$STRIP" ]; then
        "$STRIP" "$OUT" && echo "  已 strip 调试信息"
    fi
    file "$OUT" 2>/dev/null || true
    ls -la "$OUT"
    # 源码只保留在 csrc/cmark.c：板上没有 gcc，不再往卡目录里放副本
    echo "=== DONE — 板上运行:  ./cmark 4096 8 2 ==="
else
    echo "!!! 失败"
    exit 1
fi
