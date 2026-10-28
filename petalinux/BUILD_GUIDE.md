# FOGCCC PetaLinux 构建指南

## 硬件平台
- **板卡**: OpenSoc OS-ZYNQ7100 Lite (XC7Z100)
- **处理器**: ARM Cortex-A9 (双核)
- **DDR3**: MT41K256M16 RE-125 (1GB)
- **串口**: UART0 (MIO 14-15), CH340 USB, COM口, 921600 波特率（8N1）

## 前置条件
- WSL2 Ubuntu 22.04
- PetaLinux 2026.1 安装在 `~/xilinx/petalinux`
- Vivado 2026.1 已编译 bitstream

## lf 二进制（不入库）

project-spec/meta-user/recipes-core/images/files/lf 是 5.6 MB 的静态 ARM 二进制，超过仓库单文件 1 MiB 上限，因此**不入库**。构建前从上游 lf r42 的 lf-linux-arm.tar.gz 解出 lf 放到该路径（lfrc 很小，已入库）。缺这个文件时 rootfs 后处理会直接失败并提示路径。

## 一条命令构建

仓库里已经包含 PetaLinux 工程的**全部手工配置**（`petalinux/project-spec/`）：

| 内容 | 说明 |
| --- | --- |
| `project-spec/configs/config` | kernel bootargs、initramfs、DT 设置 |
| `project-spec/configs/rootfs_config` | python3 / buildessential / 空 root 密码 |
| `project-spec/meta-user/` | layer.conf、u-boot 配置、device-tree 追加、`pl_graph` reserved-memory |
| `driver/plnx/fogccc-irq/` | 中断驱动模块 recipe，构建时自动拷入 |

```bash
# 1) 先在 Vivado 里出 bitstream 和 XSA
vivado -mode batch -source vivado/build.tcl

# 2) 一条命令（首次会自动创建工程并套用上面的配置）
wsl -e bash <repo>/petalinux/build_fogccc2.sh
```

脚本依次做：

1. 若 `~/xilinx/fogccc2_linux` 不存在 → `petalinux-create` 建工程，把
   `petalinux/project-spec/` 与 `driver/plnx/fogccc-irq/` 拷进去；
2. `petalinux-config --get-hw-description=<XSA> --silentconfig`；
3. 校验手工配置没被冲掉（initramfs / earlycon / 空密码 / python3 /
   `pl_graph` reserved-memory / 层路径能解析）；
4. `petalinux-build`（首次约 1–3 小时）；
5. `petalinux-package boot`，产物拷到 `artifacts/`。

> 无需手工进入 menuconfig；上述 config 文件即菜单选项的结果。

## 手动步骤（等同，便于排查）

```bash
source ~/xilinx/petalinux/settings.sh
cd ~/xilinx
petalinux-create --type project --template zynq --name fogccc2_linux
cd fogccc2_linux
cp -a <repo>/petalinux/project-spec/configs/.   project-spec/configs/
cp -a <repo>/petalinux/project-spec/meta-user/. project-spec/meta-user/
cp -a <repo>/driver/plnx/fogccc-irq            project-spec/meta-user/recipes-modules/
petalinux-config --get-hw-description=<XSA> --silentconfig
petalinux-build
```

关键菜单项，正常由 config 文件带入，此处仅供核对：

```
DT Settings → Kernel Bootargs:        console=ttyPS0,921600 earlycon
Image Packaging → Root filesystem:    initramfs
rootfs: python3 / packagegroup-core-buildessential / empty-root-password
```

## 打包 BOOT.BIN

```bash
# 使用厂商 FSBL，其 ps7_init 与此板卡匹配；不要用 PetaLinux 生成的
petalinux-package boot \
  --fsbl /path/to/vendor/zynq_fsbl/executable.elf \
  --fpga images/linux/system.bit \
  --u-boot --force
```

## 关键文件说明

| 文件 | 用途 |
|------|------|
| `petalinux/build_fogccc2.sh` | 主构建脚本，自动 bootstrap 并校验配置 |
| `petalinux/project-spec/` | 工程的 config / rootfs_config / meta-user 源码 |
| `driver/plnx/fogccc-irq/` | 中断驱动模块 recipe |
| `vivado/build.tcl` | Vivado 自动构建脚本 |
| `rtl/` | Verilog RTL 源码 |
| `csrc/` | C 驱动程序 |
| `python/` | Python 绑定 |

## 约束

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
# 串口: COM口, 921600, 8N1
# 登录: root，密码为空

# JTAG 调试:
D:\AMDDesignTools\2026.1\Vivado\bin\xsdb.bat -eval "connect; targets"
```

## 从零构建（不依赖已有的 PetaLinux 工程）

`build_fogccc2.sh` **自己会建工程**：`$HOME/xilinx/fogccc2_linux` 不存在时，它用
`petalinux-create -t project --template zynq` 创建，并把本仓 `petalinux/project-spec/` 的配置和
`driver/plnx/fogccc-irq` 拷进去。干净机器上只需要：

1. 装好 PetaLinux 2026.1（脚本自己 `source $HOME/xilinx/petalinux/settings.sh`）
2. 先跑 `vivado/build.tcl`，产出 `vivado/fogccc_proj/system.xsa` 和 `.../system_wrapper.bit`
3. 把**厂商 FSBL** 放到 `artifacts/zynq_fsbl.elf`（不入库、不随 Release 发布，原因见 `NOTICE`）
4. `wsl -e bash <repo>/petalinux/build_fogccc2.sh`

脚本开头会 `ls` 检查这三个输入，缺一个就在 `set -e` 下停下。

> **FSBL 用哪个**：Release 里的 `BOOT.BIN` 是用**厂商 FSBL** 打的。用 PetaLinux 自己生成的
> `images/linux/zynq_fsbl.elf` 也能启动，但产物哈希不同，**不能拿来核对 Release 的 md5**。
> 所以没有厂商 FSBL 时只能验证"能启动"，不能复现发布包的字节。

> **不要复制整棵旧工程**：`build/conf/bblayers.conf` 里的 `SDKBASEMETAPATH` 是绝对路径，复制后仍指向旧工程。
> 让脚本从零创建，或先删掉旧工程的 `build/` 目录，就不会踩这个坑。