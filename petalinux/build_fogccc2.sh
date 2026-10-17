#!/bin/bash
# ============================================================
# FOGCCC2 — PetaLinux 重建 (在独立工程 fogccc2_linux 里用新 XSA 重跑)
#
# 前置:
#   - Vivado 已产出  <工程根>\vivado\fogccc_proj\system.xsa
#   - fogccc2_linux 是从 fogccc_linux 复制来的, 保留了全部手工配置:
#       kernel cmdline = console=ttyPS0,115200 earlyprintk
#       rootfs = initramfs, hostname = linux, empty-root-password
#       device-tree 里 reserved-memory pl_graph@1e000000
#
# 用法:  wsl -e bash <工程根>/petalinux/build_fogccc2.sh
# ============================================================
set -e
set -o pipefail     # 关键: 否则 petalinux-build 失败会被 tee 吞掉, 后面步骤会照着跑

PLNX_ROOT="$HOME/xilinx"
PROJ="$PLNX_ROOT/fogccc2_linux"
# 路径从脚本位置推导, 不写死用户名
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
XSA="$ROOT/vivado/fogccc_proj/system.xsa"
BIT="$ROOT/vivado/fogccc_proj/fogccc_z7100.runs/impl_1/system_wrapper.bit"
FSBL="$ROOT/artifacts/zynq_fsbl.elf"
OUT="$ROOT/artifacts"

echo "=== Step 0: 检查输入文件 ==="
ls -la "$XSA" "$BIT" "$FSBL"

echo "=== Step 1: 载入 PetaLinux 2026.1 环境 ==="
source "$PLNX_ROOT/petalinux/settings.sh"
echo "PETALINUX_VER=$PETALINUX_VER"

echo "=== Step 1.5: 工程不存在则从仓库骨架创建 ==="
if [ ! -d "$PROJ" ]; then
    SKEL="$ROOT/petalinux/project-spec"
    [ -d "$SKEL" ] || { echo "!!! 仓库里没有 petalinux/project-spec 骨架"; exit 1; }
    cd "$PLNX_ROOT"
    petalinux-create --type project --template zynq --name "$(basename "$PROJ")"
    cp -a "$SKEL/configs/."  "$PROJ/project-spec/configs/"
    cp -a "$SKEL/meta-user/." "$PROJ/project-spec/meta-user/"
    mkdir -p "$PROJ/project-spec/meta-user/recipes-modules"
    cp -a "$ROOT/driver/plnx/fogccc-irq" "$PROJ/project-spec/meta-user/recipes-modules/"
    echo "  工程已从仓库骨架创建 (含 config/rootfs_config/meta-user/模块 recipe)"
else
    echo "  工程已存在: $PROJ"
fi

cd "$PROJ"

echo "=== Step 2: 用新硬件描述刷新 (这一步才会更新比特流源) ==="
petalinux-config --get-hw-description="$XSA" --silentconfig

echo "=== Step 2.5: 校验手工配置是否被 get-hw-description 冲掉 ==="
fail=0
grep -q 'CONFIG_SUBSYSTEM_ROOTFS_INITRAMFS=y' project-spec/configs/config \
    || { echo "!!! 丢失: ROOTFS_INITRAMFS"; fail=1; }
grep -q 'earlyprintk' project-spec/configs/config \
    || { echo "!!! 丢失: kernel cmdline (earlyprintk)"; fail=1; }
grep -q 'CONFIG_imagefeature-empty-root-password=y' project-spec/configs/rootfs_config \
    || { echo "!!! 丢失: empty-root-password (上板会登不进去)"; fail=1; }
grep -q 'CONFIG_python3=y' project-spec/configs/rootfs_config \
    || { echo "!!! 丢失: python3 (板子上跑不了测试脚本)"; fail=1; }
grep -q 'pl_graph' project-spec/meta-user/recipes-bsp/device-tree/files/system-user.dtsi \
    || { echo "!!! 丢失: device-tree reserved-memory pl_graph"; fail=1; }
# 层路径必须能解析. 复制 PetaLinux 工程时 SDKBASEMETAPATH 会一起被复制过来,
# 指向旧工程; 旧工程一旦删掉, 构建就会崩在 gen-machineconf / HDF_URI 上.
SDK=$(sed -n 's/^SDKBASEMETAPATH = "\(.*\)"/\1/p' build/conf/bblayers.conf)
if [ -z "$SDK" ] || [ ! -d "$SDK" ]; then
    echo "!!! SDKBASEMETAPATH 指向的目录不存在: '$SDK'"
    echo "    两个办法:"
    echo "      a) 建软链接: ln -s fogccc2_linux \$HOME/xilinx/fogccc_linux   (零重编)"
    echo "      b) sed 改成 $PROJ/components/yocto, 然后全量重编 1-3 小时"
    echo "    注意 b) 会改 build/conf, 触发 gen-machineconf —— 本机安装里没有这个工具, 会失败"
    fail=1
fi

if [ "$fail" != "0" ]; then
    echo "!!! 手工配置被冲掉了 —— 停下, 从 fogccc_linux 重新复制一份再来"
    exit 1
fi
echo "手工配置完好"

echo "=== Step 3: 构建 ==="
# 复制来的工程带着旧路径的 build/tmp, Yocto 会拒绝 (TMPDIR has changed location).
# 删掉让 BitBake 重建; sstate 缓存仍在, 不会真从零编.
rm -rf build/tmp
date
petalinux-build 2>&1 | tee "$PLNX_ROOT/fogccc2_build.log"
date
echo "=== 构建产物时间戳 ==="
ls -la images/linux/image.ub images/linux/system.dtb images/linux/BOOT.BIN

echo "=== Step 4: 打包 BOOT.BIN (显式带新比特流) ==="
petalinux-package boot --fsbl "$FSBL" --fpga "$BIT" --u-boot --force

echo "=== Step 5: 拷贝启动文件到 FOGCCC2/artifacts ==="
cp -v images/linux/BOOT.BIN "$OUT/BOOT.BIN"
cp -v images/linux/image.ub "$OUT/image.ub"
cp -v images/linux/boot.scr "$OUT/boot.scr"
cp -v images/linux/system.dtb "$OUT/system.dtb"

echo "=== Step 6: 校验 DT 里的 reserved-memory / cmdline ==="
dtc -I dtb -O dts images/linux/system.dtb 2>/dev/null | grep -A3 "pl_graph" || \
    echo "(跳过: 没有 dtc)"
strings images/linux/image.ub | grep -m1 "earlyprintk" || true

echo ""
echo "=== DONE ==="
ls -la "$OUT/BOOT.BIN" "$OUT/image.ub"
