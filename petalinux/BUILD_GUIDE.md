# FOGCCC PetaLinux 构建指南

## 硬件平台
- **板卡**: 开源骚客 OS-ZYNQ7100 Lite (XC7Z100)
- **处理器**: ARM Cortex-A9 (双核)
- **DDR3**: MT41K256M16 RE-125 (1GB)
- **串口**: UART0 (MIO 14-15), CH340 USB, COM口, 115200波特率

## 前置条件
- WSL2 Ubuntu 22.04
- PetaLinux 2026.1 安装在 `~/xilinx/petalinux`
- Vivado 2026.1 已编译 bitstream

## 快速构建

### 1. 创建 PetaLinux 项目
```bash
source ~/xilinx/petalinux/settings.sh
cd ~/xilinx
petalinux-create --type project --template zynq --name fogccc_linux
cd fogccc_linux
petalinux-config --get-hw-description=/home/hieq/xilinx/system.xsa
```

### 2. 配置 (petalinux-config)
```
DT Settings → Kernel Bootargs:
  console=ttyPS0,115200 earlyprintk

Image Packaging Configuration → Root filesystem type:
  initramfs
```

### 3. 配置根文件系统 (petalinux-config -c rootfs)
启用以下包:
- `packagegroup-core-buildessential` (包含 gcc, g++, make)
- `python3`
- `binutils`

### 4. 编译
```bash
petalinux-build 2>&1 | tee build.log
```

### 5. 打包 BOOT.BIN
```bash
# 使用厂商FSBL (正确的 ps7_init)
petalinux-package boot \
  --fsbl /path/to/vendor/zynq_fsbl/executable.elf \
  --fpga images/linux/system.bit \
  --u-boot --force
```

### 6. 制作 TF 卡
- **分区1 (FAT32, 512MB)**: BOOT.BIN + image.ub
- **不需要其他分区** (rootfs 使用 initramfs)

## 关键文件说明

| 文件 | 用途 |
|------|------|
| `petalinux/build_petalinux.sh` | 完整构建脚本 |
| `petalinux/package_boot.sh` | BOOT.BIN 打包脚本 |
| `vivado/build.tcl` | Vivado 自动构建脚本 |
| `rtl/` | Verilog RTL 源码 |
| `csrc/` | C 驱动程序 |
| `python/` | Python 绑定 |

## 重要注意事项

### FSBL 的 ps7_init
必须使用厂商的 `ps7_init.c/h`（DDR/MIO/UART 配置）。
PetaLinux 自动生成的 ps7_init **不匹配此板卡**。

### U-Boot 设备树
U-Boot 使用 `CONFIG_OF_SEPARATE`，设备树需拼接到 `u-boot.bin` 末尾。
`_end` 符号地址 = `0x04106C30`，设备树必须在此位置。

### BIF 分区顺序
```
[bootloader] fsbl.elf     ← 第1个
system.bit                 ← 第2个 (bitstream)
u-boot-dtb-fixed.bin       ← 第3个 (U-Boot + 设备树)
```

## 烧写 TF 卡
```bash
# Windows: 使用 DiskGenius 或 Rufus
# 分区1: FAT32, 512MB
# 拷入: BOOT.BIN + image.ub

# Linux:
sudo mkfs.vfat -F 32 -n BOOT /dev/sdX1
sudo mount /dev/sdX1 /mnt/boot
sudo cp BOOT.BIN image.ub /mnt/boot/
sudo umount /mnt/boot
```

## 调试
```bash
# 串口: COM口, 115200, 8N1
# 登录: root (密码空或 root)

# JTAG 调试:
D:\AMDDesignTools\2026.1\Vivado\bin\xsdb.bat debug_boot.tcl
```
