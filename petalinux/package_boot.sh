#!/bin/bash
# ============================================================
# FOGCCC BOOT.BIN 打包脚本 (bootgen + 自定义BIF)
# 适用于已编译好 PetaLinux 的情况
# ============================================================

set -e

IMAGES=/mnt/c/Users/wwwmt/Desktop/fogccc_build
PLNX=~/xilinx/fogccc_linux
VENDOR_FSBL='/mnt/c/Users/wwwmt/AppData/Local/Temp/zynq_sd_example/05_zynq_sd/vitis/design_1_wrapper/zynq_fsbl/executable.elf'
BITSTREAM='/mnt/c/Users/wwwmt/Desktop/fogccc/vivado/fogccc_proj/fogccc_z7100.runs/impl_1/system_wrapper.bit'

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
