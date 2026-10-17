#!/bin/bash
# ============================================================
# FOGCCC PetaLinux 构建脚本
# 平台: Xilinx Zynq-7000 XC7Z100 (开源骚客 OS-ZYNQ7100 Lite)
# 
# 前置条件:
#   1. PetaLinux 2026.1 已安装
#   2. WSL2 Ubuntu 22.04 已配置
#   3. Vivado 2026.1 已编译 bitstream 并导出 system.xsa
# ============================================================

set -e

# 路径从脚本位置推导, 不写死用户名
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PLNX_ROOT=~/xilinx
PROJ_NAME=fogccc_linux
XSA_PATH=${PLNX_ROOT}/system.xsa
IMAGES="$ROOT/artifacts"

echo "=== Step 1: Load PetaLinux environment ==="
source ${PLNX_ROOT}/petalinux/settings.sh

echo "=== Step 2: Create project ==="
cd ${PLNX_ROOT}
rm -rf ${PROJ_NAME}
petalinux-create --type project --template zynq --name ${PROJ_NAME}
cd ${PROJ_NAME}

echo "=== Step 3: Import XSA ==="
petalinux-config --get-hw-description=${XSA_PATH}
# 手动配置:
#   DT Settings → Kernel Bootargs → console=ttyPS0,115200 earlyprintk
#   Image Packaging Configuration → Root filesystem type → initramfs

echo "=== Step 4: Configure rootfs ==="
# 添加 gcc/make/python3 支持
sed -i 's/^# CONFIG_packagegroup-core-buildessential is not set/CONFIG_packagegroup-core-buildessential=y/' project-spec/configs/rootfs_config
sed -i 's/^# CONFIG_packagegroup-core-sdk is not set/CONFIG_packagegroup-core-sdk=y/' project-spec/configs/rootfs_config
sed -i 's/^# CONFIG_binutils is not set/CONFIG_binutils=y/' project-spec/configs/rootfs_config
sed -i 's/^# CONFIG_make is not set/CONFIG_make=y/' project-spec/configs/rootfs_config
sed -i 's/^# CONFIG_python3 is not set/CONFIG_python3=y/' project-spec/configs/rootfs_config

echo "=== Step 5: Build ==="
petalinux-build 2>&1 | tee build.log

echo "=== Step 6: Package BOOT.BIN ==="
# 使用厂商 FSBL (正确的 ps7_init)
# 厂商 FSBL 在板卡资料包里, 请按实际位置修改
VENDOR_FSBL="${VENDOR_FSBL:-artifacts/zynq_fsbl.elf}"
BITSTREAM="$ROOT/vivado/fogccc_proj/fogccc_z7100.runs/impl_1/system_wrapper.bit"

petalinux-package boot --fsbl "$VENDOR_FSBL" --fpga "$BITSTREAM" --u-boot --force

echo "=== Step 7: Copy to Windows ==="
mkdir -p ${IMAGES}
cp images/linux/BOOT.BIN ${IMAGES}/
cp images/linux/image.ub ${IMAGES}/

echo "=== DONE ==="
echo "TF 卡放 BOOT.BIN + image.ub 即可启动"
