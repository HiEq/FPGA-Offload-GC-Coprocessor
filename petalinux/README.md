# PetaLinux 构建关键文件 / 信息

配置均已在仓库中：petalinux/project-spec/configs/（bootargs、initramfs、rootfs）
与 petalinux/project-spec/meta-user/（layer、u-boot、device-tree）。
build_fogccc2.sh 首次运行会创建工程并套用这些配置。

下文说明各配置项的作用与必须修改的内容。完整步骤见 BUILD_GUIDE.md。

## 1. 起点: 正确的 XSA

```bash
petalinux-config --get-hw-description=<directory containing system.xsa>
```

XSA 来自 Vivado 工程（vivado/build.tcl）。PS7 的关键点（按照本项目使用的开发板 **opensoc xc7z100ffg900-2核心板+lite底板**，其他开发板可参照厂商随板发布的datasheet）：

| 项 | 值 | 备注 |
|---|---|---|
| UART0 使能 | CONFIG.PCW_UART0_PERIPHERAL_ENABLE {1} ||
| UART0 引脚 | PCW_UART0_UART0_IO {MIO 14 .. 15} | 板上 CH340 接 UART0 |
| SDIO0 使能 | CONFIG.PCW_SD0_PERIPHERAL_ENABLE {1} ||
| SDIO0 引脚 | PCW_SD0_SD0_IO {MIO 40 .. 45} | |
| AXI | PCW_USE_M_AXI_GP0 {1} / PCW_USE_S_AXI_HP0 {1} / HP0 宽度 64 | |
| gc_top 地址 | 0x43C00000 (64K) | |
| DDR | MT41K256M16 RE-125, 32bit, 533.333MHz | |

## 2. project-spec/configs/config

```
CONFIG_SUBSYSTEM_HOSTNAME="linux"
CONFIG_SUBSYSTEM_USER_CMDLINE="console=ttyPS0,921600 earlycon"
```


## 3. project-spec/configs/rootfs_config

```
CONFIG_imagefeature-empty-root-password=y
# CONFIG_imagefeature-serial-autologin-root is not set
# CONFIG_imagefeature-debug-tweaks is not set
```

- empty-root-password：串口登录 root，密码为空
- serial-autologin-root：不启用

root 口令由 empty-root-password 提供；CONFIG_ADD_EXTRA_USERS 不设置口令。

## 4. project-spec/meta-user/recipes-bsp/u-boot/files/

**bsp.cfg**
```
CONFIG_SYS_CONFIG_NAME="platform-top"
CONFIG_BOOT_SCRIPT_OFFSET=0x9C0000
CONFIG_SYS_BOOTM_LEN=0x10000000
```

**platform-top.h** —— ZYNQ 段里：
```c
#define CFG_NR_DRAM_BANKS   1
#define CFG_SYS_SDRAM_BASE  0x00000000
#define CFG_SYS_SDRAM_SIZE  0x40000000
#define CONFIG_SYS_BOOTM_LEN 0x10000000
#define CFG_SYS_BOOTM_LEN    0x10000000
```


## 5. project-spec/meta-user/recipes-bsp/device-tree/files/system-user.dtsi

```dts
/include/ "system-conf.dtsi"  

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

/* U-Boot 串口时钟配置 */
&uart0 { clock-frequency = <100000000>; status = "okay"; };
&uart1 { status = "disabled"; };
```

## 6. 构建与打包

```bash
petalinux-build
petalinux-package boot --fsbl images/linux/zynq_fsbl.elf \
                       --fpga images/linux/system.bit --u-boot --force
```

TF 卡上的三个文件：BOOT.BIN + image.ub + **boot.scr**

## images/linux/system.bit 的更新时机

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
