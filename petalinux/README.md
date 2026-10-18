# PetaLinux 构建关键文件 / 信息

配置均已在仓库中：`petalinux/project-spec/configs/`（bootargs、initramfs、rootfs）
与 `petalinux/project-spec/meta-user/`（layer、u-boot、device-tree）。
`build_fogccc2.sh` 首次运行会创建工程并套用这些配置。

下文说明各配置项的作用与必须修改的内容。完整步骤见 `BUILD_GUIDE.md`。

## 1. 起点: 正确的 XSA

```bash
petalinux-config --get-hw-description=<directory containing system.xsa>
```

XSA 必须来自**修好的 Vivado 工程**（`vivado/build.tcl`）。PS7 的关键点：

| 项 | 值 | 备注 |
|---|---|---|
| UART0 使能 | `CONFIG.PCW_UART0_PERIPHERAL_ENABLE {1}` | **不是** `PCW_EN_UART0`（那是个无效属性） |
| UART0 引脚 | `PCW_UART0_UART0_IO {MIO 14 .. 15}` | 板上 CH340 接 UART0 |
| SDIO0 使能 | `CONFIG.PCW_SD0_PERIPHERAL_ENABLE {1}` | **不是** `PCW_EN_SDIO0` |
| SDIO0 引脚 | `PCW_SD0_SD0_IO {MIO 40 .. 45}` | |
| AXI | `PCW_USE_M_AXI_GP0 {1}` / `PCW_USE_S_AXI_HP0 {1}` / HP0 宽度 64 | |
| gc_top 地址 | `0x43C00000` (64K) | |
| DDR | `MT41K256M16 RE-125`, 32bit, 533.333MHz | |

## 2. `project-spec/configs/config`

```
CONFIG_SUBSYSTEM_HOSTNAME="linux"
CONFIG_SUBSYSTEM_USER_CMDLINE="console=ttyPS0,115200 earlycon"
```

> ⚠️ **不要**在这里加 `mem=480M`！initramfs 解压要 ~244MB + 内核 Image 101MB，
> 把内存砍到 480MB 会导致 `Kernel panic - not syncing: write error`。
> 给 PL 预留内存请用下面的设备树 `reserved-memory`。

## 3. `project-spec/configs/rootfs_config`

```
CONFIG_imagefeature-empty-root-password=y
# CONFIG_imagefeature-serial-autologin-root is not set
# CONFIG_imagefeature-debug-tweaks is not set
```

- `empty-root-password`：串口登录 `root`，密码为空
- `serial-autologin-root`：不启用

> root 口令由 `empty-root-password` 提供；`CONFIG_ADD_EXTRA_USERS` 不设置口令。

## 4. `project-spec/meta-user/recipes-bsp/u-boot/files/`

**`bsp.cfg`**
```
CONFIG_SYS_CONFIG_NAME="platform-top"
CONFIG_BOOT_SCRIPT_OFFSET=0x9C0000
CONFIG_SYS_BOOTM_LEN=0x10000000
```

**`platform-top.h`** —— ZYNQ 段里：
```c
#define CFG_NR_DRAM_BANKS   1
#define CFG_SYS_SDRAM_BASE  0x00000000
#define CFG_SYS_SDRAM_SIZE  0x40000000
#define CONFIG_SYS_BOOTM_LEN 0x10000000
#define CFG_SYS_BOOTM_LEN    0x10000000
```

> `CONFIG_SYS_BOOTM_LEN` 必须放大：initramfs 被链接进内核后，image.ub 的 kernel
> 子镜像约 **101 MiB**，Xilinx 默认 `0x3c00000`(60MiB) 会导致
> `Image too large: increase CONFIG_SYS_BOOTM_LEN`。

## 5. `project-spec/meta-user/recipes-bsp/device-tree/files/system-user.dtsi`

```dts
/include/ "system-conf.dtsi"        /* ← 这一行绝对不能删！ */

/ {
    reserved-memory {
        #address-cells = <1>;
        #size-cells = <1>;
        ranges;
        pl_graph: pl_graph@1e000000 {
            reg = <0x1e000000 0x02000000>;   /* 32 MiB for the PL object graph */
        };
    };
};

/* 修复 U-Boot 串口时钟配置 */
&uart0 { clock-frequency = <100000000>; status = "okay"; };
&uart1 { status = "disabled"; };
```

- 第一行 `/include/ "system-conf.dtsi"` **把 PetaLinux 生成的配置（`chosen/bootargs`、
  `memory`、`aliases` …）带进来**。删掉它，内核 cmdline 会静默丢失 —— 生成的
  `system.dtb` 里 `chosen/bootargs` 就只剩 `earlycon`，Linux 没有串口控制台。
- `reserved-memory` 把 PL 用的 `0x1E000000` 从内核分配器里挖出来（AXI HP 与 PS 不
  缓存一致，这段内存绝不能被内核当普通内存用）。Linux 仍然拿到 ~1GB。

> 兜底：BOOT 分区放一个 `uEnv.txt`（`bootargs=console=ttyPS0,115200 earlycon`），
> `boot.scr` 会 `env import` 它，U-Boot 环境里的 `bootargs` 覆盖设备树，改内核
> cmdline 就不用重建镜像。

## 6. 构建与打包

```bash
petalinux-build
petalinux-package boot --fsbl images/linux/zynq_fsbl.elf \
                       --fpga images/linux/system.bit --u-boot --force
```

TF 卡上的三件套：`BOOT.BIN` + `image.ub` + **`boot.scr`**（缺 boot.scr 会停在 `Zynq>`）。

## `images/linux/system.bit` 的更新时机

该文件仅在 `petalinux-config --get-hw-description` 时从 XSA 解出；
更换 XSA 或重复 `petalinux-build` 不会更新它，BOOT.BIN 中仍是最初的位流。

换 XSA 后必须手动刷新：

```bash
unzip -o project-spec/hw-description/system.xsa system.bit -d /tmp/x
cp /tmp/x/system.bit project-spec/hw-description/system.bit
cp /tmp/x/system.bit images/linux/system.bit
petalinux-package boot --fsbl images/linux/zynq_fsbl.elf \
                       --fpga images/linux/system.bit --u-boot --force
```
