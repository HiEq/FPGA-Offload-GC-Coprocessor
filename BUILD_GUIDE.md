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
- **FCLK**: CLK0=100MHz (AXI-Lite), CLK1=200MHz (AXI HP)
- **DDR**: MT41K256M16 RE-125, 32-bit, 533MHz
- **AXI HP0**: 64-bit, 连接 GC 引擎读 DDR

### 5. PetaLinux 配置
```bash
# 内核启动参数
console=ttyPS0,115200 earlyprintk

# 根文件系统类型
initramfs

# U-Boot 配置 (bsp.cfg)
CONFIG_SYS_CONFIG_NAME="platform-top"
CONFIG_BOOT_SCRIPT_OFFSET=0x9C0000
CONFIG_OF_BOARD=y
# CONFIG_OF_SEPARATE is not set
CONFIG_SYS_FDT_BASE=0x03000000
```

### 6. TF 卡分区
```
分区1: FAT32, 512MB
  → BOOT.BIN + image.ub
```

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
cat images/linux/u-boot.bin images/linux/system.dtb > u-boot-dtb-fixed.bin
bootgen -image boot.bif -arch zynq -o BOOT.BIN -w on
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
