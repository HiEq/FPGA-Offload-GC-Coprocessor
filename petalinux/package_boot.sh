#!/bin/bash
# ============================================================
# FOGCCC BOOT.BIN 打包脚本 (bootgen + 自定义BIF)
# 适用于已编译好 PetaLinux 的情况
# ============================================================

set -e

# 路径从脚本位置推导, 不写死用户名
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGES="$ROOT/artifacts"
PLNX=~/xilinx/fogccc_linux
# 厂商 FSBL 在板卡资料包里, 请按实际位置修改
VENDOR_FSBL="${VENDOR_FSBL:-artifacts/zynq_fsbl.elf}"
BITSTREAM="$ROOT/vivado/fogccc_proj/fogccc_z7100.runs/impl_1/system_wrapper.bit"

echo "=== Strip U-Boot ==="
arm-linux-gnueabihf-strip --strip-debug ${PLNX}/images/linux/u-boot.elf -o ${PLNX}/images/linux/u-boot-stripped.elf

echo "=== Create fixed u-boot-dtb.bin ==="
# 修复 _end 偏移: u-boot.bin + BSS填充 + system.dtb
UBOOT_BIN_SIZE=$(stat -c%s ${PLNX}/images/linux/u-boot.bin)
END_OFFSET=0x106C30
BSS_PAD=$((END_OFFSET - UBOOT_BIN_SIZE))
echo "u-boot.bin size: ${UBOOT_BIN_SIZE}, BSS padding: ${BSS_PAD}"

cp ${PLNX}/images/linux/u-boot.bin ${IMAGES}/u-boot-padded.bin
dd if=/dev/zero bs=1 count=${BSS_PAD} >> ${IMAGES}/u-boot-padded.bin 2>/dev/null
cat ${IMAGES}/u-boot-padded.bin ${PLNX}/images/linux/system.dtb > ${IMAGES}/u-boot-dtb-fixed.bin

echo "=== Create BIF ==="
cat > ${IMAGES}/boot.bif << BIFEOF
the_ROM_image:
{
    [bootloader] ${VENDOR_FSBL}
    ${BITSTREAM}
    [load = 0x04000000, start_cpu = 0x04000000] ${IMAGES}/u-boot-dtb-fixed.bin
}
BIFEOF

echo "=== Generate BOOT.BIN ==="
bootgen -image ${IMAGES}/boot.bif -arch zynq -o ${IMAGES}/BOOT.BIN -w on

echo "=== Copy image.ub ==="
cp ${PLNX}/images/linux/image.ub ${IMAGES}/

echo "=== DONE ==="
echo "TF 卡放 BOOT.BIN + image.ub 即可启动"
