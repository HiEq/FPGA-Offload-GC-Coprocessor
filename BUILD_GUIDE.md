# FOGCCC 构建指南

## 硬件平台
- **板卡**: 开源骚客 OS-ZYNQ7100 Lite (XC7Z100-FFG900)
- **串口**: CH340 → UART0 (MIO 14/15), COM5, 115200 baud
- **DDR**: MT41K256M16 RE-125, 32-bit, 533MHz, 1GB

## 启动链
```
BootROM → FSBL → U-Boot → Linux Kernel → RootFS
```

## 关键发现与解决方案

### 1. PS7 初始化 (ps7_init)
**问题**: PetaLinux 自动生成的 ps7_init 与板卡硬件不匹配，导致 DDR 初始化失败、FSBL 卡死。

**解决**: 使用厂商参考工程的 ps7_init 文件：
```
MIO14 (0xF8000738) = 0x16E1  (UART0 RX, LVCMOS3.3V, Pullup)
MIO15 (0xF800073C) = 0x16E0  (UART0 TX, LVCMOS3.3V, Pullup)
MIO40-45           = 0x1280  (SDIO0, LVCMOS1.8V)
```

**替换位置**: `project-spec/hw-description/ps7_init.c/h`

### 2. U-Boot 设备树加载
**问题**: `CONFIG_OF_SEPARATE` 模式下，U-Boot 在 `_end` 符号地址查找设备树。但 `u-boot.bin` 大小与 `_end` 不对齐，BSS 清零会覆盖设备树。

**关键数值**:
- `_end` 符号地址: `0x04106C30`
- `u-boot.bin` 大小: 1,076,272 字节 = `0x106C30`
- `system.dtb` 大小: 18,142 字节

**解决**: 直接拼接 `u-boot.bin + system.dtb`，设备树精确在 `_end` 位置：
```bash
cat u-boot.bin system.dtb > u-boot-dtb-fixed.bin
```

### 3. BOOT.BIN 打包
**使用厂商 FSBL**（包含正确的 ps7_init）：
```bash
bootgen -image boot.bif -arch zynq -o BOOT.BIN -w on
```

**boot.bif 内容**:
```
the_ROM_image:
{
    [bootloader] <厂商FSBL路径>/executable.elf
    <bitstream>/system_wrapper.bit
    [load = 0x04000000] <u-boot-dtb-fixed.bin>
}
```

### 4. Vivado 工程配置
- **Part**: xc7z100ffg900-2
- **PS7**: UART0 (MIO 14-15), SDIO0 (MIO 40-45), M_AXI_GP0, S_AXI_HP0
- **FCLK**: CLK0=100MHz —— AXI-Lite **和 AXI HP 都用它**（单一时钟域，无 CDC 同步器）；
  CLK1 未使用（旧版 HP 走 200MHz，已合并到 CLK0，因为读主控是流式 FIFO、无法简单跨域）
- **DDR**: MT41K256M16 RE-125, 32-bit, 533MHz
- **AXI HP0**: 64-bit, 连接 GC 引擎读 DDR

### 5. PetaLinux 配置
```bash
# 内核启动参数
console=ttyPS0,115200 earlycon

# 根文件系统类型
initramfs

# U-Boot 配置 (project-spec/meta-user/recipes-bsp/u-boot/files/bsp.cfg)
CONFIG_SYS_CONFIG_NAME="platform-top"
CONFIG_BOOT_SCRIPT_OFFSET=0x9C0000
# 注意: 不要再设 CONFIG_OF_BOARD / CONFIG_SYS_FDT_BASE / CONFIG_OF_EMBED。
# 设备树由 FSBL 从 BOOT.BIN 的第 4 分区加载到 0x00100000
# (见 bootgen.bif 里的 [load=0x100000] system.dtb), U-Boot 默认流程即可拿到。
#
# PetaLinux initramfs 的 image.ub 里内核子镜像高达 ~101MiB
# (initramfs 被链接进内核 Image), 而 Xilinx 默认
# CONFIG_SYS_BOOTM_LEN=0x3c00000(60MiB) 装不下, bootm 会报
#   "Image too large: increase CONFIG_SYS_BOOTM_LEN"
# 必须放大到 256MiB:
CONFIG_SYS_BOOTM_LEN=0x10000000
# 同时在 platform-top.h 的 CONFIG_ARCH_ZYNQ 段里定义了
# CONFIG_SYS_BOOTM_LEN / CFG_SYS_BOOTM_LEN 两份作为兜底。
```

### 6. TF 卡分区
```
分区1: FAT32, 512MB
  → BOOT.BIN + image.ub + boot.scr     (3 个文件缺一不可!)
```
> ⚠️ **关键**: 必须包含 `boot.scr`（PetaLinux 生成的 U-Boot 启动脚本）。
> U-Boot 的 distro boot 靠它执行 `fatload mmc 0 0x10000000 image.ub; bootm 0x10000000`。
> 只放 `BOOT.BIN` + `image.ub` 会一直停在 `Zynq>` 提示符。
> 文件位置: `images/linux/boot.scr`（由 `u-boot-xlnx-scr` recipe 生成）。

## 构建命令

### Vivado
```bash
source build.tcl
# 生成: fogccc_proj/system.xsa, system_wrapper.bit
```

### PetaLinux
```bash
petalinux-create --type project --template zynq --name fogccc_linux
petalinux-config --get-hw-description=/path/to/system.xsa
petalinux-build
```

### 打包 BOOT.BIN
```bash
# 推荐: 用 petalinux-package (自动生成 4 分区 + 写入 images/linux/bootgen.bif)
petalinux-package boot --fsbl images/linux/zynq_fsbl.elf \
                       --fpga images/linux/system.bit --u-boot --force

# 生成的 bootgen.bif 分区布局:
#   [bootloader] zynq_fsbl.elf
#   system.bit
#   u-boot.elf
#   [load=0x100000] system.dtb     <- 设备树被 FSBL 载入 0x00100000
```

## 调试方法

### XSDB 调试脚本
```tcl
connect
targets
target -set -filter {name =~ "ARM Cortex-A9 MPCore #0"}
stop
# 读 PC, DDR, U-Boot, 设备树, UART 状态
```

### PowerShell 串口监听
```powershell
$port = New-Object System.IO.Ports.SerialPort COM5,115200,None,8,One
$port.Open()
while ($true) {
    $data = $port.ReadExisting()
    if ($data) { Write-Host $data -NoNewline }
    Start-Sleep -Milliseconds 50
}
```

## 常见问题
| 现象 | 原因 | 解决 |
|------|------|------|
| 串口无输出 | ps7_init DDR 配置错误 | 用厂商 ps7_init |
| FSBL 卡死 | U-Boot 加载失败 | 检查 BIF 分区格式 |
| U-Boot hang() | 设备树位置不对 | 拼接到 `_end` 精确位置 |
| DDR 报错 | PS7 DDR 参数不匹配 | 对齐厂商 MT41K256M16 配置 |

## 深度调试总结: 启动链上的坑 (2026-10 实战)

按"从下到上"排列, 任一环错整条链就断:

1. **PS7 外设使能属性名写错** (build.tcl)
   `PCW_EN_UART0` / `PCW_EN_SDIO0` 不是有效的使能属性. 正确写法:
   `PCW_UART0_PERIPHERAL_ENABLE` / `PCW_SD0_PERIPHERAL_ENABLE`.
   写错的后果: XSA 里 UART0/SDIO0 实际未使能 -> ps7_init.c 中
   `UART0_CPU_1XCLKACT=0`, `UART REGISTERS` 段为空, 没有 MIO14/15 配置
   -> FSBL 无串口; U-Boot 写 TX FIFO 卡死.

2. **gc_top 地址映射**: `get_bd_addr_segs` 必须用 PS7 地址空间下的段
   (`/ps7_0/Data/SEG_gc_top_0_reg0`), 用 interconnect 引脚查不到.

3. **TF 卡必须有 boot.scr** (images/linux/boot.scr)
   只放 BOOT.BIN + image.ub 会停在 `Zynq>`. boot.scr 里的 mmc0 分支负责
   `fatload mmc 0 0x10000000 image.ub; bootm 0x10000000`.

4. **U-Boot CONFIG_SYS_BOOTM_LEN**: initramfs 被链接进内核后, image.ub
   的 kernel 子镜像约 101MiB, Xilinx 默认 0x3c00000 (60MiB) 不够 ->
   `Image too large`. 改 bsp.cfg + platform-top.h 提到 0x10000000.

5. **!! images/linux/system.bit 是一次性解压的 !!**
   它只在 `petalinux-config --get-hw-description` 时从 XSA 解出来.
   之后换 XSA / 反复 petalinux-build **都不会更新它** ->
   BOOT.BIN 里装的一直是旧位流 (所有 RTL 改动全部白做!).
   修法:
   ```bash
   unzip -o project-spec/hw-description/system.xsa system.bit -d /tmp/x
   cp /tmp/x/system.bit project-spec/hw-description/system.bit
   cp /tmp/x/system.bit images/linux/system.bit
   petalinux-package boot --fsbl images/linux/zynq_fsbl.elf \
                          --fpga images/linux/system.bit --u-boot --force
   ```

6. **RTL: AXI HP 是 64 位宽, 32 位读必须做 8 字节对齐 + 半字选择**
   ```verilog
   ARADDR <= {addr[31:3], 3'b000 };   // 8 字节对齐
   hi_sel <= addr[2];                 // 奇/偶半字
   rdata  <= hi_sel ? RDATA[63:32] : RDATA[31:0];
   ```
   否则读 对象头+4 (ref_count) 会拿到 头+0 (obj_id) -> 遍历立刻结束.

7. **对象图布局: 引用数组必须排在所有对象头之后**
   头区 = n*16 字节; `REF_BASE` 硬编码 0x1000 在 n>256 时会覆盖对象头.

### 登录
`/etc/shadow` 里 root 是 `*` (锁定). 用 `petalinux` 用户 + 空密码登录
(首次强制改密), 然后 `sudo -i`.